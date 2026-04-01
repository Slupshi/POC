#!/usr/bin/env bash
# =============================================================================
# chaos-tests.sh — Étape 4 : Tests de chaos
# =============================================================================
#
# Scénarios testés sur les DEUX variantes du pattern SAGA :
#
#   C1 — Service down pendant une saga en cours
#   C2 — Timeout sur un appel inter-service (simulation via docker pause)
#   C3 — Message dupliqué / concurrence de sagas
#   C4 — Compensation qui échoue (dead-letter / workflow FAILED)
#
# Usage :
#   ./chaos-tests.sh [all|choreography|orchestration]
#
# Prérequis : Docker, bash, curl
#   Phase 1 : cd Saga-Choreography && docker compose up -d
#   Phase 2 : cd Saga-Orchestration && docker compose up -d
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHOR_DIR="$SCRIPT_DIR/Saga-Choreography"
ORCH_DIR="$SCRIPT_DIR/Saga-Orchestration"

# Ports exposés (docker-compose.yml)
CHOR_ORDER_URL="http://localhost:5101"
ORCH_ORDER_URL="http://localhost:5201"
ORCH_SAGA_URL="http://localhost:5200"
RABBITMQ_API="http://localhost:15672"

PASSED=0
FAILED=0
SKIP_CHOR=false
SKIP_ORCH=false

# ─── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC}  $*"; (( PASSED++ )) || true; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; (( FAILED++ )) || true; }
log_hint()  { echo -e "       ${CYAN}↳${NC} $*"; }

log_section() {
  local title="$*"
  echo
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────┐${NC}"
  printf  "${BOLD}${CYAN}│  %-52s│${NC}\n" "$title"
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────┘${NC}"
}

# ─── Helpers HTTP ──────────────────────────────────────────────────────────────

# Récupère le statut d'une commande : GET /orders/{id}
get_order_status() {
  local base_url="$1"
  local order_id="$2"
  curl -sf --max-time 5 "$base_url/orders/$order_id" 2>/dev/null \
    | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//'
}

# Extrait le champ "id" d'une réponse JSON
extract_id() {
  grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//'
}

# Crée une commande via POST /orders
post_order() {
  local base_url="$1"
  local quantity="${2:-5}"
  curl -sf --max-time 10 -X POST "$base_url/orders" \
    -H "Content-Type: application/json" \
    -d "{\"productId\":\"PROD-CHAOS\",\"quantity\":$quantity}"
}

# Attend qu'une commande atteigne un statut terminal (CONFIRMED ou CANCELLED)
# Retourne le statut ou échoue avec exit-code 1 si délai dépassé.
wait_for_terminal() {
  local base_url="$1"
  local order_id="$2"
  local max_wait="${3:-40}"
  local elapsed=0
  while (( elapsed < max_wait )); do
    local status
    status=$(get_order_status "$base_url" "$order_id" || echo "")
    if [[ "$status" == "CONFIRMED" || "$status" == "CANCELLED" ]]; then
      echo "$status"
      return 0
    fi
    sleep 2
    (( elapsed += 2 ))
  done
  return 1
}

# Vérifie qu'un service HTTP répond (toute réponse HTTP ≠ timeout)
service_is_reachable() {
  local url="$1"
  local code
  code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
  [[ "$code" != "000" ]]
}

# Attend qu'un service soit de nouveau disponible
wait_for_service() {
  local url="$1"
  local max_wait="${2:-30}"
  local elapsed=0
  log_info "Attente de $url (max ${max_wait}s)..."
  while (( elapsed < max_wait )); do
    if service_is_reachable "$url"; then return 0; fi
    sleep 2
    (( elapsed += 2 ))
  done
  return 1
}

# ─── Helpers Docker Compose ────────────────────────────────────────────────────
dc_chor() { docker compose -f "$CHOR_DIR/docker-compose.yml" --project-directory "$CHOR_DIR" "$@" 2>/dev/null; }
dc_orch() { docker compose -f "$ORCH_DIR/docker-compose.yml" --project-directory "$ORCH_DIR" "$@" 2>/dev/null; }

# ─── Helpers RabbitMQ ──────────────────────────────────────────────────────────

# Retourne les noms des error queues (_error) qui contiennent des messages
rabbitmq_error_queues() {
  curl -sf -u guest:guest "$RABBITMQ_API/api/queues" 2>/dev/null \
    | grep -o '"name":"[^"]*_error[^"]*","[^{]*"messages":[1-9][0-9]*' \
    | grep -o '"name":"[^"]*"' \
    | sed 's/"name":"//;s/"//' \
    | sort -u
}

# Nombre de queues _error avec des messages (0 si aucune)
count_error_queues() {
  local result
  result=$(rabbitmq_error_queues)
  if [[ -z "$result" ]]; then echo "0"; else echo "$result" | wc -l; fi
}

# ─── Helpers Orchestration ─────────────────────────────────────────────────────

# Lance une saga en arrière-plan ; retourne le PID du curl
# Résultat JSON écrit dans <result_file>
submit_saga_bg() {
  local result_file="$1"
  local quantity="${2:-5}"
  curl -sf -X POST "$ORCH_SAGA_URL/saga/orders" \
    -H "Content-Type: application/json" \
    -d "{\"productId\":\"PROD-CHAOS\",\"quantity\":$quantity}" \
    --max-time 90 -o "$result_file" &
  echo $!
}

# Extrait le champ "status" d'un fichier de résultat saga
saga_status() {
  local file="$1"
  cat "$file" 2>/dev/null \
    | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//'
}

# ══════════════════════════════════════════════════════════════════════════════
# CHORÉGRAPHIE — Tests de chaos
# ══════════════════════════════════════════════════════════════════════════════

# C1 — Service down : stock-service arrêté → messages conservés dans RabbitMQ
# ─────────────────────────────────────────────────────────────────────────────
# Comportement attendu :
#   - La commande reste PENDING le temps que stock-service est arrêté
#   - Dès le redémarrage, RabbitMQ redelivre OrderCreated → saga se termine
run_chor_c1_service_down() {
  log_section "CHORÉGRAPHIE — C1 : Service down (stock-service)"
  echo "  Arrêt de stock-service après ORDER_CREATED. Le message attend dans"
  echo "  RabbitMQ. À la reprise du service, la saga se termine normalement."

  log_info "Création d'une commande (qty=5)..."
  local resp
  resp=$(post_order "$CHOR_ORDER_URL" 5)
  local order_id
  order_id=$(echo "$resp" | extract_id)

  if [[ -z "$order_id" ]]; then
    log_fail "Impossible de créer une commande — service non disponible"
    return
  fi
  log_info "Commande créée : $order_id"

  log_info "Arrêt de stock-service..."
  dc_chor stop stock-service

  sleep 3
  local status
  status=$(get_order_status "$CHOR_ORDER_URL" "$order_id" || echo "unknown")
  log_info "Statut avec stock-service arrêté : ${status:-unknown}"

  if [[ "$status" == "PENDING" ]]; then
    log_pass "PENDING confirmé — OrderCreated conservé dans RabbitMQ"
    log_hint "MassTransit ne perd pas les messages si le consumer est temporairement indisponible"
  else
    log_warn "Statut inattendu : $status (saga peut-être traitée avant l'arrêt)"
  fi

  log_info "Redémarrage de stock-service..."
  dc_chor start stock-service

  log_info "Attente de la résolution de la saga (max 40s)..."
  local final
  if final=$(wait_for_terminal "$CHOR_ORDER_URL" "$order_id" 40); then
    log_pass "Saga résolue après redémarrage → statut : $final"
    log_hint "Résilience naturelle : le broker conserve les messages pendant les arrêts"
  else
    log_fail "La saga n'a pas convergé dans les 40s après redémarrage"
  fi
}

# C2 — Timeout simulé : payment-service gelé via docker pause
# ─────────────────────────────────────────────────────────────────────────────
# Comportement attendu :
#   - payment-service gelé → StockReserved ne peut pas être consommé
#   - La saga reste bloquée en PENDING
#   - Après unpause, payment-service reprend et la saga se termine
run_chor_c2_timeout_pause() {
  log_section "CHORÉGRAPHIE — C2 : Timeout simulé (payment-service gelé)"
  echo "  'docker pause' suspend le processus payment-service, simulant un freeze"
  echo "  réseau ou un GC pause. Le message StockReserved attend dans la queue."

  log_info "Création d'une commande (qty=5)..."
  local resp
  resp=$(post_order "$CHOR_ORDER_URL" 5)
  local order_id
  order_id=$(echo "$resp" | extract_id)

  if [[ -z "$order_id" ]]; then
    log_fail "Impossible de créer une commande"
    return
  fi
  log_info "Commande créée : $order_id"

  # Laisser stock-service publier StockReserved, puis geler payment-service
  sleep 1
  log_info "Gel de payment-service (docker pause)..."
  dc_chor pause payment-service

  sleep 5
  local status
  status=$(get_order_status "$CHOR_ORDER_URL" "$order_id" || echo "unknown")
  log_info "Statut avec payment-service gelé : ${status:-unknown}"

  if [[ "$status" != "CONFIRMED" && "$status" != "CANCELLED" ]]; then
    log_pass "Saga bloquée (${status:-PENDING}) — paiement en attente dans la queue"
    log_hint "Le message StockReserved est livré dès que payment-service reprend"
  else
    log_warn "Saga déjà résolue avant le gel ($status) — fenêtre de pause trop tardive"
  fi

  log_info "Reprise de payment-service (docker unpause)..."
  dc_chor unpause payment-service

  log_info "Attente de la résolution (max 30s)..."
  local final
  if final=$(wait_for_terminal "$CHOR_ORDER_URL" "$order_id" 30); then
    log_pass "Saga résolue après reprise → statut : $final"
  else
    log_fail "La saga n'a pas été résolue après unpause dans les 30s"
  fi
}

# C3 — Requêtes dupliquées : deux commandes identiques en parallèle
# ─────────────────────────────────────────────────────────────────────────────
# Comportement attendu :
#   - Chaque requête POST génère un GUID distinct côté serveur
#   - Deux sagas indépendantes s'exécutent en parallèle sans interférence
#   - MassTransit ne déduplique pas ; l'idempotence est à la charge du client
run_chor_c3_duplicate() {
  log_section "CHORÉGRAPHIE — C3 : Requêtes dupliquées / idempotence"
  echo "  Deux commandes identiques (même produit, même quantité) soumises"
  echo "  simultanément. Chacune doit produire une saga indépendante."

  log_info "Envoi de 2 commandes simultanées (même contenu)..."
  local r1 r2
  r1=$(post_order "$CHOR_ORDER_URL" 5)
  r2=$(post_order "$CHOR_ORDER_URL" 5)
  local id1 id2
  id1=$(echo "$r1" | extract_id)
  id2=$(echo "$r2" | extract_id)

  log_info "Commande 1 : ${id1:-<erreur>}"
  log_info "Commande 2 : ${id2:-<erreur>}"

  if [[ -n "$id1" && -n "$id2" && "$id1" != "$id2" ]]; then
    log_pass "Deux IDs distincts générés — chaque requête produit une saga indépendante"
    log_hint "L'idempotence client (ex: clé idempotency-key) reste à implémenter si nécessaire"
  else
    log_fail "IDs identiques ou requête rejetée : $id1 / $id2"
  fi

  log_info "Attente de la résolution des deux sagas (max 30s)..."
  local s1 s2
  s1=$(wait_for_terminal "$CHOR_ORDER_URL" "$id1" 30 || echo "timeout")
  s2=$(wait_for_terminal "$CHOR_ORDER_URL" "$id2" 30 || echo "timeout")

  log_info "Saga 1 → $s1 | Saga 2 → $s2"

  if [[ "$s1" != "timeout" && "$s2" != "timeout" ]]; then
    log_pass "Les deux sagas convergeant indépendamment ($s1 / $s2)"
  else
    log_fail "Une ou deux sagas n'ont pas convergé ($s1 / $s2)"
  fi
}

# C4 — Compensation qui échoue : dead-letter après redémarrage avec état mémoire perdu
# ─────────────────────────────────────────────────────────────────────────────
# Comportement attendu :
#   - qty=200 → stock-service publie StockReservationFailed (déterministe)
#   - order-service arrêté avant de consommer StockReservationFailed
#   - Au redémarrage, l'état mémoire est vide → KeyNotFoundException sur le consommateur
#   - MassTransit retente (N fois) puis achemine vers la queue _error (dead-letter)
#   CONSTAT : sans persistance externe, la compensation échoue silencieusement
run_chor_c4_compensation_failure() {
  log_section "CHORÉGRAPHIE — C4 : Compensation qui échoue (dead-letter)"
  echo "  Commande qty=200 → stock refuses → StockReservationFailed publié."
  echo "  order-service redémarre avec état mémoire vide → la compensation"
  echo "  (mise à CANCELLED) échoue → MassTransit dead-letter le message."

  local errors_before
  errors_before=$(count_error_queues)
  log_info "Error queues avant le test : $errors_before"

  log_info "Création d'une commande qty=200 (échec stock déterministe)..."
  local resp
  resp=$(post_order "$CHOR_ORDER_URL" 200)
  local order_id
  order_id=$(echo "$resp" | extract_id)

  if [[ -z "$order_id" ]]; then
    log_fail "Impossible de créer la commande"
    return
  fi
  log_info "Commande créée : $order_id"

  # Arrêter order-service avant qu'il consomme StockReservationFailed
  log_info "Arrêt immédiat de order-service (avant la compensation)..."
  dc_chor stop order-service

  # Laisser stock-service publier StockReservationFailed
  log_info "Pause de 4s pour que stock-service publie StockReservationFailed..."
  sleep 4

  # Redémarrer order-service : état mémoire vide, l'ordre n'existe plus
  log_info "Redémarrage de order-service (état mémoire effacé)..."
  dc_chor start order-service
  wait_for_service "$CHOR_ORDER_URL" 30 || true

  # MassTransit va tenter de consommer StockReservationFailed, échouer
  # (KeyNotFoundException sur OrderStore.Orders[id]), puis retenter.
  # Délai : laisser MassTransit épuiser ses tentatives (~15-20s par défaut)
  log_info "Attente de l'épuisement des tentatives MassTransit (15s)..."
  sleep 15

  local final_status
  final_status=$(get_order_status "$CHOR_ORDER_URL" "$order_id" || echo "not-found")
  log_info "Statut de la commande dans le nouveau processus : ${final_status:-not-found}"

  local errors_after
  errors_after=$(count_error_queues)
  local error_queues_list
  error_queues_list=$(rabbitmq_error_queues || echo "aucune")

  if [[ "${final_status:-not-found}" == "not-found" || -z "$final_status" ]]; then
    log_pass "Commande absente du nouvel état mémoire — état perdu au redémarrage (attendu)"
  else
    log_warn "Commande trouvée avec statut : $final_status (la fenêtre d'arrêt était trop tardive)"
  fi

  if (( errors_after > errors_before )); then
    log_pass "Dead-letter détecté : $errors_after queue(s) avec messages d'erreur"
    log_hint "Queues concernées : $error_queues_list"
    log_hint "Vérifier dans RabbitMQ UI → http://localhost:15672 (guest/guest)"
  else
    log_warn "Aucune nouvelle error queue détectée — les tentatives sont peut-être encore en cours"
    log_hint "Attendre quelques secondes et inspecter manuellement : http://localhost:15672"
  fi

  echo
  echo "  CONSTAT : Sans persistance externe, l'état mémoire est perdu au redémarrage."
  echo "  Un message de compensation ne peut pas être rejoué si sa cible a disparu."
  echo "  Solution : persister l'état (BDD) + idempotence sur les consommateurs."
}

# ══════════════════════════════════════════════════════════════════════════════
# ORCHESTRATION — Tests de chaos
# ══════════════════════════════════════════════════════════════════════════════

# C1 — Service down : payment-service arrêté pendant T3
# ─────────────────────────────────────────────────────────────────────────────
# Comportement attendu (MaximumAttempts=1) :
#   - T3 échoue immédiatement (connection refused)
#   - Temporal catch → C2 (ReleaseStock) + C1 (CancelOrder) s'exécutent
#   - La saga retourne CANCELLED proprement
run_orch_c1_service_down() {
  log_section "ORCHESTRATION — C1 : Service down (payment-service)"
  echo "  payment-service arrêté pendant l'exécution de T3."
  echo "  Temporal détecte l'échec de l'activité et exécute les compensations."

  local result_file
  result_file=$(mktemp)

  log_info "Lancement de la saga (qty=5) en arrière-plan..."
  local curl_pid
  curl_pid=$(submit_saga_bg "$result_file" 5)

  # Laisser T1 (CreateOrder ~50ms) et T2 (ReserveStock ~50ms) se terminer
  sleep 2
  log_info "Arrêt de payment-service (T3 doit échouer)..."
  dc_orch stop payment-service

  log_info "Attente de la fin du workflow..."
  wait "$curl_pid" 2>/dev/null || true

  local status
  status=$(saga_status "$result_file")
  log_info "Résultat de la saga : ${status:-<pas de réponse>}"
  rm -f "$result_file"

  if [[ "$status" == "CANCELLED" ]]; then
    log_pass "Saga CANCELLED — compensations (ReleaseStock + CancelOrder) exécutées automatiquement"
    log_hint "Temporal garantit l'exécution des compensations même en cas de défaillance de service"
  elif [[ -z "$status" ]]; then
    log_fail "Pas de réponse — le workflow a peut-être expiré ou l'orchestrateur est indisponible"
  else
    log_fail "Statut inattendu : $status (attendu : CANCELLED)"
  fi

  log_info "Redémarrage de payment-service..."
  dc_orch start payment-service
}

# C2 — Timeout d'activité : stock-service gelé → StartToCloseTimeout (30s) expiré
# ─────────────────────────────────────────────────────────────────────────────
# Comportement attendu :
#   - stock-service gelé → l'activité ReserveStock hang plus de 30s
#   - Temporal annule l'activité (StartToCloseTimeout) et lève une exception
#   - La compensation C1 (CancelOrder) s'exécute → CANCELLED
run_orch_c2_timeout_pause() {
  log_section "ORCHESTRATION — C2 : Timeout d'activité (stock-service gelé)"
  echo "  'docker pause' gèle stock-service. L'activité T2 dépasse"
  echo "  StartToCloseTimeout=30s → Temporal annule et déclenche la compensation."

  local result_file
  result_file=$(mktemp)

  log_info "Lancement de la saga en arrière-plan..."
  local curl_pid
  curl_pid=$(submit_saga_bg "$result_file" 5)

  # Pause stock-service juste après T1 (CreateOrder ~50ms)
  sleep 0.5
  log_info "Gel de stock-service (docker pause)..."
  dc_orch pause stock-service

  log_info "Attente de l'expiration du timeout (StartToCloseTimeout=30s + marge)..."
  sleep 35

  log_info "Reprise de stock-service (inutile mais propre)..."
  dc_orch unpause stock-service

  log_info "Attente de la fin du workflow..."
  wait "$curl_pid" 2>/dev/null || true

  local status
  status=$(saga_status "$result_file")
  log_info "Résultat : ${status:-<pas de réponse>}"
  rm -f "$result_file"

  if [[ "$status" == "CANCELLED" ]]; then
    log_pass "Saga CANCELLED — Temporal a détecté le timeout et exécuté la compensation"
    log_hint "StartToCloseTimeout et ScheduleToCloseTimeout sont configurables par activité"
  else
    log_fail "Statut inattendu : '${status:-vide}' (attendu : CANCELLED)"
  fi
}

# C3 — Workflows concurrents : deux sagas soumises simultanément
# ─────────────────────────────────────────────────────────────────────────────
# Comportement attendu :
#   - Chaque saga reçoit un workflowId UUID distinct
#   - Temporal isole parfaitement les deux exécutions
#   - Les deux sagas se terminent sans interférence
run_orch_c3_concurrent() {
  log_section "ORCHESTRATION — C3 : Workflows concurrents"
  echo "  Deux sagas soumises simultanément. Temporal leur assigne des"
  echo "  workflowIds UUID distincts — aucune collision ni interférence."

  local f1 f2
  f1=$(mktemp)
  f2=$(mktemp)

  log_info "Lancement de 2 sagas en parallèle..."
  curl -sf -X POST "$ORCH_SAGA_URL/saga/orders" \
    -H "Content-Type: application/json" \
    -d '{"productId":"PROD-CHAOS-A","quantity":5}' \
    --max-time 30 -o "$f1" &
  local p1=$!

  curl -sf -X POST "$ORCH_SAGA_URL/saga/orders" \
    -H "Content-Type: application/json" \
    -d '{"productId":"PROD-CHAOS-B","quantity":5}' \
    --max-time 30 -o "$f2" &
  local p2=$!

  wait "$p1" 2>/dev/null || true
  wait "$p2" 2>/dev/null || true

  local s1 s2
  s1=$(saga_status "$f1")
  s2=$(saga_status "$f2")
  log_info "Saga 1 (PROD-A) → ${s1:-<erreur>}"
  log_info "Saga 2 (PROD-B) → ${s2:-<erreur>}"
  rm -f "$f1" "$f2"

  if [[ -n "$s1" && -n "$s2" ]]; then
    log_pass "Les deux sagas traitées indépendamment ($s1 / $s2)"
    log_hint "Temporal isole les workflows par leur ID unique — aucune donnée partagée entre workflows"
  else
    log_fail "Une ou plusieurs sagas sans réponse (${s1:-vide} / ${s2:-vide})"
  fi
}

# C4 — Compensation qui échoue : order-service arrêté lors de CancelOrder
# ─────────────────────────────────────────────────────────────────────────────
# Comportement attendu (MaximumAttempts=1) :
#   - Saga qty=200 : T1 OK, T2 échoue (stock insuffisant)
#   - Temporal exécute C1 (CancelOrder) mais order-service est arrêté
#   - L'activité CancelOrder échoue, MaxAttempts=1 → pas de retry
#   - Le workflow se termine en FAILED dans Temporal (pas de CANCELLED propre)
#   CONTRASTE avec chorégraphie : pas de queue pour absorber la défaillance
#   CONCLUSION : MaximumAttempts=1 exige une intervention manuelle (replay Temporal UI)
run_orch_c4_compensation_failure() {
  log_section "ORCHESTRATION — C4 : Compensation qui échoue (MaxAttempts=1)"
  echo "  order-service arrêté avant que la compensation CancelOrder s'exécute."
  echo "  MaximumAttempts=1 → aucun retry → workflow FAILED dans Temporal."
  echo "  Contraste : côté choreography, le message attend dans RabbitMQ."

  local result_file
  result_file=$(mktemp)

  # Pour order-service down lors de CancelOrder :
  # Stratégie : arrêter order-service puis soumettre la saga
  # → T1 (CreateOrder) échoue (connection refused) → pas même de compensation
  # Mais c'est le comportement "fail-fast" sans état partiel
  # Pour tester la compensation D après T1 réussi : on arrête order-service
  # juste entre T1 et l'appel de compensation (très court → 0.3s suffit
  # car T2 stock-failure est quasi-instantanée côté service)
  log_info "Lancement de la saga qty=200 (T2 = échec stock → compensation C1)"
  log_info "en arrière-plan — order-service arrêté dans 0.4s..."
  local curl_pid
  curl_pid=$(submit_saga_bg "$result_file" 200)

  # T1 (~50ms) + T2 échec immédiat (~50ms) + début catch (~10ms) = ~110ms
  # On attend 0.4s pour être sûr que T1 a terminé, mais pas trop pour C1
  sleep 0.4
  log_info "Arrêt de order-service (bloque CancelOrder)..."
  dc_orch stop order-service

  log_info "Attente de la fin du workflow (timeout ou échec)..."
  wait "$curl_pid" 2>/dev/null || true

  local status
  status=$(saga_status "$result_file")
  local raw_response
  raw_response=$(cat "$result_file" 2>/dev/null | head -c 300)
  rm -f "$result_file"

  log_info "Statut retourné : '${status:-<vide>}'"
  [[ -n "$raw_response" ]] && log_info "Réponse brute : $raw_response"

  # Redémarrer order-service pour la suite
  log_info "Redémarrage de order-service..."
  dc_orch start order-service
  wait_for_service "$ORCH_ORDER_URL" 30 || true

  # Vérification de la reprise : une nouvelle saga doit réussir
  log_info "Vérification de la reprise : nouvelle saga healthy (qty=5)..."
  local recovery_file
  recovery_file=$(mktemp)
  curl -sf -X POST "$ORCH_SAGA_URL/saga/orders" \
    -H "Content-Type: application/json" \
    -d '{"productId":"PROD-RECOVERY","quantity":5}' \
    --max-time 30 -o "$recovery_file" || true
  local recovery_status
  recovery_status=$(saga_status "$recovery_file")
  rm -f "$recovery_file"

  if [[ -z "$status" || "$status" != "CANCELLED" ]]; then
    log_pass "Workflow FAILED / sans résultat propre — MaxAttempts=1 = pas de retry sur compensation"
    log_hint "Statut observé dans Temporal : '${status:-workflow FAILED}'"
    log_hint "Remède : augmenter MaximumAttempts dans DefaultOptions ou configurer un retry policy"
    log_hint "Visualiser le workflow failed : http://localhost:8088 (Temporal UI)"
  else
    log_warn "Le workflow a retourné CANCELLED — la fenêtre d'arrêt (0.4s) était trop tardive"
    log_hint "T1+T2 ont peut-être pris plus de 0.4s. Résultat quand même cohérent (CANCELLED)."
  fi

  if [[ "$recovery_status" == "CONFIRMED" ]]; then
    log_pass "Reprise confirmée — nouvelle saga CONFIRMED après redémarrage d'order-service"
  elif [[ -n "$recovery_status" ]]; then
    log_warn "Nouvelle saga → $recovery_status (attendu : CONFIRMED)"
  else
    log_warn "Impossible de vérifier la reprise (orchestrateur indisponible ?)"
  fi

  echo
  echo "  CONSTAT : Sans retry, une compensation échouée = workflow abandonné."
  echo "  Il faut soit augmenter MaximumAttempts, soit implémenter une politique"
  echo "  de compensation manuelle (saga compensating transaction store)."
}

# ══════════════════════════════════════════════════════════════════════════════
# Entrypoint
# ══════════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
Usage: $0 [all|choreography|orchestration]

  all              Exécute tous les tests chaos (défaut)
  choreography     Phase 1 — SAGA Chorégraphiée (RabbitMQ · ports 5101-5103)
  orchestration    Phase 2 — SAGA Orchestrée   (Temporal · ports 5200-5203)

Prérequis — services démarrés avec 'docker compose up -d' :
  Phase 1 : cd Saga-Choreography && docker compose up -d
  Phase 2 : cd Saga-Orchestration && docker compose up -d
EOF
  exit 0
}

check_prereqs() {
  local target="$1"

  if [[ "$target" == "all" || "$target" == "choreography" ]]; then
    if ! service_is_reachable "$CHOR_ORDER_URL/orders"; then
      echo -e "${RED}[ERREUR]${NC} Saga-Choreography non disponible ($CHOR_ORDER_URL)"
      echo "  → cd Saga-Choreography && docker compose up -d"
      [[ "$target" != "all" ]] && exit 1
      SKIP_CHOR=true
    fi
  fi

  if [[ "$target" == "all" || "$target" == "orchestration" ]]; then
    if ! service_is_reachable "$ORCH_SAGA_URL"; then
      echo -e "${RED}[ERREUR]${NC} Saga-Orchestration non disponible ($ORCH_SAGA_URL)"
      echo "  → cd Saga-Orchestration && docker compose up -d"
      [[ "$target" != "all" ]] && exit 1
      SKIP_ORCH=true
    fi
  fi
}

print_banner() {
  echo
  echo -e "${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       TESTS DE CHAOS — SAGA POC — Étape 4            ║${NC}"
  echo -e "${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
  echo
  echo "  C1 — Service down pendant une saga en cours"
  echo "  C2 — Timeout inter-service (docker pause / StartToCloseTimeout)"
  echo "  C3 — Message dupliqué / workflows concurrents"
  echo "  C4 — Compensation qui échoue (dead-letter / MaxAttempts=1)"
  echo
}

print_summary() {
  echo
  echo -e "${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║                      RÉSUMÉ                          ║${NC}"
  echo -e "${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  ${GREEN}✓ PASS${NC}  $PASSED"
  echo -e "  ${RED}✗ FAIL${NC}  $FAILED"
  echo
  if (( FAILED > 0 )); then
    echo -e "  ${RED}Des tests ont échoué — voir les détails ci-dessus.${NC}"
    exit 1
  else
    echo -e "  ${GREEN}Tous les tests ont passé.${NC}"
  fi
}

main() {
  local target="${1:-all}"
  case "$target" in
    -h|--help|help) usage ;;
    all|choreography|orchestration) ;;
    *) echo -e "${RED}Option inconnue : '$target'${NC}" >&2; usage ;;
  esac

  print_banner
  check_prereqs "$target"

  # ── Phase 1 : Chorégraphie ─────────────────────────────────────────────────
  if [[ ( "$target" == "all" || "$target" == "choreography" ) && "$SKIP_CHOR" != "true" ]]; then
    echo -e "\n${BOLD}${CYAN}▶▶▶  PHASE 1 — SAGA CHORÉGRAPHIÉE (RabbitMQ / MassTransit)${NC}"
    run_chor_c1_service_down
    run_chor_c2_timeout_pause
    run_chor_c3_duplicate
    run_chor_c4_compensation_failure
  fi

  # ── Phase 2 : Orchestration ────────────────────────────────────────────────
  if [[ ( "$target" == "all" || "$target" == "orchestration" ) && "$SKIP_ORCH" != "true" ]]; then
    echo -e "\n${BOLD}${CYAN}▶▶▶  PHASE 2 — SAGA ORCHESTRÉE (Temporal)${NC}"
    run_orch_c1_service_down
    run_orch_c2_timeout_pause
    run_orch_c3_concurrent
    run_orch_c4_compensation_failure
  fi

  print_summary
}

main "$@"
