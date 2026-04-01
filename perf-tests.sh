#!/usr/bin/env bash
# =============================================================================
# perf-tests.sh — Mesure du temps de réponse bout-en-bout
#                 1a / 1b / 2 × succès / échec
# =============================================================================
#
# Pour chaque implémentation et chaque scénario (CONFIRMED / CANCELLED),
# exécute N fois la création d'une commande et mesure le temps écoulé entre
# le POST et la réception d'un statut terminal.
#
#   1a — SAGA Chorégraphiée (RabbitMQ / MassTransit état mémoire)  → port 5101
#   1b — SAGA Chorégraphiée + Outbox (SQLite)                      → port 5111
#   2  — SAGA Orchestrée (Temporal)                                → port 5200
#
# Usage :
#   ./perf-tests.sh [all|1a|1b|2] [--runs N]
#
# Prérequis : Docker, bash, curl
#   Phase 1a : cd Saga-Choreography        && docker compose up -d
#   Phase 1b : cd Saga-Choreography-Outbox && docker compose up -d
#   Phase 2  : cd Saga-Orchestration       && docker compose up -d
# =============================================================================
set -uo pipefail

# ─── Ports ────────────────────────────────────────────────────────────────────
CHOR_ORDER_URL="http://localhost:5101"
OUTBOX_ORDER_URL="http://localhost:5111"
ORCH_SAGA_URL="http://localhost:5200"

# ─── Paramètres par défaut ────────────────────────────────────────────────────
RUNS=5                           # Nombre d'itérations par scénario
POLL_TIMEOUT=60                  # Délai max (secondes) pour attendre un statut terminal
RESULTS_FILE="perf-results.txt"  # Fichier de sortie (écrasé à chaque exécution)

SKIP_1A=false
SKIP_1B=false
SKIP_2=false

# ─── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }

log_section() {
  echo
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────┐${NC}"
  printf  "${BOLD}${CYAN}│  %-52s│${NC}\n" "$*"
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────┘${NC}"
}

# ─── Helpers HTTP ─────────────────────────────────────────────────────────────

get_order_status() {
  local base_url="$1"
  local order_id="$2"
  curl -sf --max-time 5 "$base_url/orders/$order_id" 2>/dev/null \
    | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//'
}

extract_id() {
  # Extrait le premier UUID présent dans la réponse (indépendant du nom du champ, insensible à la casse)
  grep -ioE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1
}

post_order() {
  local base_url="$1"
  local quantity="${2:-5}"
  curl -s --max-time 10 -X POST "$base_url/orders" \
    -H "Content-Type: application/json" \
    -d "{\"productId\":\"PROD-PERF\",\"quantity\":$quantity}"
}

service_is_reachable() {
  local url="$1"
  local code
  code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
  [[ "$code" != "000" ]]
}

# Attend un statut terminal ; retourne le statut + code 0, ou code 1 si timeout
# max_wait est en secondes ; poll toutes les 500 ms
wait_for_terminal() {
  local base_url="$1"
  local order_id="$2"
  local max_wait="${3:-$POLL_TIMEOUT}"
  local deadline=$(( $(now_ms) + max_wait * 1000 ))
  while (( $(now_ms) < deadline )); do
    local status
    status=$(get_order_status "$base_url" "$order_id" || echo "")
    if [[ "$status" == "CONFIRMED" || "$status" == "CANCELLED" ]]; then
      echo "$status"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# ─── Chronomètre (millisecondes) ──────────────────────────────────────────────
now_ms() { date +%s%3N; }

# ─── Probe pré-lancement ──────────────────────────────────────────────────────
# Effectue un POST de diagnostic pour vérifier que l'endpoint répond
# correctement (body non vide + UUID extractible) avant de lancer les benchs.
# Retourne 0 si OK, 1 si KO (et imprime la cause).
probe_chor() {
  local label="$1"
  local base_url="$2"
  log_info "[$label] Probe POST $base_url/orders ..."
  local raw
  raw=$(curl -s --max-time 10 -X POST "$base_url/orders" \
    -H "Content-Type: application/json" \
    -d '{"productId":"PROBE","quantity":1}' 2>/dev/null || echo "")
  if [[ -z "$raw" ]]; then
    log_fail "[$label] Probe KO — aucune réponse (connexion refusée / service non démarré)"
    log_warn "  → cd Saga-Choreography$([ "$label" = "1b" ] && echo "-Outbox") && docker compose up -d"
    return 1
  fi
  local probe_id
  probe_id=$(echo "$raw" | extract_id)
  if [[ -z "$probe_id" ]]; then
    log_fail "[$label] Probe KO — réponse reçue mais aucun UUID trouvé"
    log_warn "  → raw: $raw"
    return 1
  fi
  log_pass "[$label] Probe OK — ID=$probe_id (raw: $raw)"
  return 0
}

probe_orch() {
  log_info "[2] Probe GET $ORCH_SAGA_URL/saga/orders (HEAD) ..."
  local code
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
    -X POST "$ORCH_SAGA_URL/saga/orders" \
    -H "Content-Type: application/json" \
    -d '{"productId":"PROBE","quantity":1}' 2>/dev/null || echo "000")
  # On accepte n'importe quel code HTTP valide (même 400/500) — l'essentiel
  # est que le service répond. 000 = connexion impossible.
  if [[ "$code" == "000" ]]; then
    log_fail "[2] Probe KO — connexion refusée (Temporal ou SagaOrchestrator non démarré)"
    log_warn "  → cd Saga-Orchestration && docker compose up -d"
    log_warn "  Note: Temporal met ~30 s à devenir healthy au premier démarrage"
    return 1
  fi
  log_pass "[2] Probe OK — SagaOrchestrator répond (HTTP $code)"
  return 0
}

# ─── Statistiques ─────────────────────────────────────────────────────────────
# Usage : calc_stats val1 val2 ... valN
# Affiche : count  min  avg  median  p95  max  (en ms)
calc_stats() {
  local values=("$@")
  local n=${#values[@]}
  if (( n == 0 )); then echo "0 - - - - -"; return; fi

  # Tri croissant par substitution de processus
  local sorted
  sorted=($(printf '%s\n' "${values[@]}" | sort -n))

  local min="${sorted[0]}"
  local max="${sorted[$((n-1))]}"

  local sum=0
  for v in "${values[@]}"; do (( sum += v )) || true; done
  local avg=$(( sum / n ))

  local p50_idx=$(( (n - 1) / 2 ))
  local p95_idx=$(( (n * 95 + 99) / 100 - 1 ))
  (( p95_idx >= n )) && p95_idx=$(( n - 1 ))

  local p50="${sorted[$p50_idx]}"
  local p95="${sorted[$p95_idx]}"

  echo "$n $min $avg $p50 $p95 $max"
}

# ─── Résultats globaux ────────────────────────────────────────────────────────
# Tableau associatif : clé = "phase:scenario" → tableau de durées (ms)
declare -A RESULTS_TIMES     # "1a:success" → "200 210 215 ..."
declare -A RESULTS_STATUSES  # "1a:success" → statuts observés
declare -A RESULTS_ERRORS    # "1a:success" → nombre d'échecs (timeout ou id manquant)

store_result() {
  local key="$1"
  local duration_ms="$2"
  local terminal_status="$3"

  RESULTS_TIMES["$key"]+="$duration_ms "
  RESULTS_STATUSES["$key"]+="$terminal_status "
}

# ─── Mesures chorégraphie (1a et 1b) ──────────────────────────────────────────

# Exécute un run de la phase chorégraphiée, mesure le temps bout-en-bout.
# $1 : label (1a|1b)
# $2 : base URL
# $3 : quantité (5 → succès attendu, 200 → échec attendu)
# $4 : scénario (success|failure)
run_chor_once() {
  local label="$1"
  local base_url="$2"
  local qty="$3"
  local scenario="$4"

  local t_start
  t_start=$(now_ms)

  local resp
  resp=$(post_order "$base_url" "$qty" 2>/dev/null || echo "")
  local order_id
  order_id=$(echo "$resp" | extract_id)

  if [[ -z "$order_id" ]]; then
    log_warn "[$label/$scenario] Run ignoré — pas d'ID dans la réponse (raw: ${resp:-<vide>})"
    (( RESULTS_ERRORS["$label:$scenario"]++ )) || true
    return
  fi

  local terminal_status
  if ! terminal_status=$(wait_for_terminal "$base_url" "$order_id" "$POLL_TIMEOUT"); then
    local last_status
    last_status=$(get_order_status "$base_url" "$order_id" || echo "timeout")
    log_warn "[$label/$scenario] Timeout — statut bloqué : ${last_status:-inconnu}"
    (( RESULTS_ERRORS["$label:$scenario"]++ )) || true
    return
  fi

  local t_end
  t_end=$(now_ms)
  local elapsed=$(( t_end - t_start ))

  store_result "$label:$scenario" "$elapsed" "$terminal_status"
  log_info "[$label/$scenario] Run OK → $terminal_status en ${elapsed} ms"
}

# Lance RUNS itérations pour un scénario chorégraphié
bench_chor() {
  local label="$1"
  local base_url="$2"
  local qty="$3"
  local scenario="$4"

  RESULTS_ERRORS["$label:$scenario"]=0

  for (( i=1; i<=RUNS; i++ )); do
    log_info "[$label/$scenario] Run $i/$RUNS..."
    run_chor_once "$label" "$base_url" "$qty" "$scenario"
    # Pause pour éviter les interférences entre runs
    sleep 1
  done
}

# ─── Mesures orchestration (2) ────────────────────────────────────────────────
# POST /saga/orders est synchrone : la réponse contient directement le statut final.

run_orch_once() {
  local scenario="$1"
  local qty="$2"

  local t_start
  t_start=$(now_ms)

  local resp
  resp=$(curl -s --max-time 90 -X POST "$ORCH_SAGA_URL/saga/orders" \
    -H "Content-Type: application/json" \
    -d "{\"productId\":\"PROD-PERF\",\"quantity\":$qty}" 2>/dev/null || echo "")

  local t_end
  t_end=$(now_ms)
  local elapsed=$(( t_end - t_start ))

  local terminal_status
  terminal_status=$(echo "$resp" | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//')

  if [[ -z "$terminal_status" ]]; then
    log_warn "[2/$scenario] Run ignoré — pas de statut dans la réponse (raw: ${resp:-<vide>})"
    (( RESULTS_ERRORS["2:$scenario"]++ )) || true
    return
  fi

  store_result "2:$scenario" "$elapsed" "$terminal_status"
  log_info "[2/$scenario] Run OK → $terminal_status en ${elapsed} ms"
}

bench_orch() {
  local scenario="$1"
  local qty="$2"

  RESULTS_ERRORS["2:$scenario"]=0

  for (( i=1; i<=RUNS; i++ )); do
    log_info "[2/$scenario] Run $i/$RUNS..."
    run_orch_once "$scenario" "$qty"
    sleep 1
  done
}

# ─── Vérification des prérequis ───────────────────────────────────────────────

check_prereqs() {
  local target="$1"

  if [[ "$target" == "all" || "$target" == "1a" ]]; then
    if ! service_is_reachable "$CHOR_ORDER_URL/orders"; then
      log_warn "Phase 1a non disponible ($CHOR_ORDER_URL) — skippée"
      log_warn "  → cd Saga-Choreography && docker compose up -d"
      SKIP_1A=true
    fi
  fi

  if [[ "$target" == "all" || "$target" == "1b" ]]; then
    if ! service_is_reachable "$OUTBOX_ORDER_URL/orders"; then
      log_warn "Phase 1b non disponible ($OUTBOX_ORDER_URL) — skippée"
      log_warn "  → cd Saga-Choreography-Outbox && docker compose up -d"
      SKIP_1B=true
    fi
  fi

  if [[ "$target" == "all" || "$target" == "2" ]]; then
    if ! service_is_reachable "$ORCH_SAGA_URL/saga/orders"; then
      log_warn "Phase 2 non disponible ($ORCH_SAGA_URL) — skippée"
      log_warn "  → cd Saga-Orchestration && docker compose up -d"
      SKIP_2=true
    fi
  fi

  if [[ "$SKIP_1A" == "true" && "$SKIP_1B" == "true" && "$SKIP_2" == "true" ]]; then
    echo -e "${RED}[ERREUR]${NC} Aucune phase disponible. Démarrez au moins un environnement."
    exit 1
  fi
}

# ─── Tableau de résultats ─────────────────────────────────────────────────────

print_summary() {
  echo
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║              RÉSULTATS DE PERFORMANCE — temps en millisecondes           ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
  echo

  # En-tête
  printf "${BOLD}%-14s  %-10s  %5s  %7s  %7s  %7s  %7s  %7s  %6s  %-20s${NC}\n" \
    "Phase" "Scénario" "N" "min(ms)" "avg(ms)" "p50(ms)" "p95(ms)" "max(ms)" "erreurs" "statuts observés"
  printf '─%.0s' {1..108}; echo

  local -a KEYS=()
  [[ "$SKIP_1A" != "true" ]] && KEYS+=("1a:success" "1a:failure")
  [[ "$SKIP_1B" != "true" ]] && KEYS+=("1b:success" "1b:failure")
  [[ "$SKIP_2"  != "true" ]] && KEYS+=("2:success"  "2:failure")

  for key in "${KEYS[@]}"; do
    local phase="${key%%:*}"
    local scenario="${key##*:}"

    local raw="${RESULTS_TIMES[$key]:-}"
    local errors="${RESULTS_ERRORS[$key]:-0}"
    local statuses="${RESULTS_STATUSES[$key]:-}"

    if [[ -z "$raw" ]]; then
      printf "%-14s  %-10s  %5s  %7s  %7s  %7s  %7s  %7s  %6s  %-20s\n" \
        "$phase" "$scenario" "0" "—" "—" "—" "—" "—" "$errors" "(aucun résultat)"
      continue
    fi

    # Convertit la chaîne "200 215 ..." en tableau
    local -a vals=()
    read -r -a vals <<< "$raw"

    local stats
    stats=$(calc_stats "${vals[@]}")
    local n min avg p50 p95 max
    read -r n min avg p50 p95 max <<< "$stats"

    # Statuts uniques observés
    local unique_statuses
    unique_statuses=$(echo "$statuses" | tr ' ' '\n' | sort | uniq -c | tr '\n' ' ')

    # Couleur selon le scénario
    local color="$NC"
    [[ "$scenario" == "success" ]] && color="$GREEN"
    [[ "$scenario" == "failure" ]] && color="$RED"

    printf "${color}%-14s  %-10s  %5s  %7s  %7s  %7s  %7s  %7s  %6s  %-20s${NC}\n" \
      "$phase" "$scenario" "$n" "$min" "$avg" "$p50" "$p95" "$max" "$errors" "$unique_statuses"
  done

  echo
  echo -e "  Légende : ${GREEN}success${NC} = commande qty=5  (→ CONFIRMED attendu)"
  echo -e "            ${RED}failure${NC} = commande qty=200 (→ CANCELLED attendu, stock insuffisant)"
  echo
  echo -e "  ${CYAN}Durée mesurée${NC} :"
  [[ "$SKIP_1A" != "true" ]] && echo    "    1a — de POST /orders jusqu'à statut terminal (polling toutes les 500ms)"
  [[ "$SKIP_1B" != "true" ]] && echo    "    1b — de POST /orders jusqu'à statut terminal (polling toutes les 500ms)"
  [[ "$SKIP_2"  != "true" ]] && echo    "    2  — durée totale du POST /saga/orders synchrone (Temporal attend le workflow)"
  echo
  echo -e "  ${CYAN}Paramètres${NC} : $RUNS run(s) par scénario · timeout poll = ${POLL_TIMEOUT}s"
}

# ─── Fichier de résultats (sans ANSI) ────────────────────────────────────────

write_results_file() {
  {
    echo "RÉSULTATS DE PERFORMANCE — SAGA POC"
    echo "Généré le : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Runs par scénario : $RUNS  |  Timeout poll : ${POLL_TIMEOUT}s"
    echo
    printf '%-14s  %-10s  %5s  %7s  %7s  %7s  %7s  %7s  %6s  %-20s\n' \
      "Phase" "Scénario" "N" "min(ms)" "avg(ms)" "p50(ms)" "p95(ms)" "max(ms)" "erreurs" "statuts observés"
    printf '─%.0s' {1..108}; echo

    local -a KEYS=()
    [[ "$SKIP_1A" != "true" ]] && KEYS+=("1a:success" "1a:failure")
    [[ "$SKIP_1B" != "true" ]] && KEYS+=("1b:success" "1b:failure")
    [[ "$SKIP_2"  != "true" ]] && KEYS+=("2:success"  "2:failure")

    for key in "${KEYS[@]}"; do
      local phase="${key%%:*}"
      local scenario="${key##*:}"
      local raw="${RESULTS_TIMES[$key]:-}"
      local errors="${RESULTS_ERRORS[$key]:-0}"
      local statuses="${RESULTS_STATUSES[$key]:-}"

      if [[ -z "$raw" ]]; then
        printf "%-14s  %-10s  %5s  %7s  %7s  %7s  %7s  %7s  %6s  %-20s\n" \
          "$phase" "$scenario" "0" "—" "—" "—" "—" "—" "$errors" "(aucun résultat)"
        continue
      fi

      local -a vals=()
      read -r -a vals <<< "$raw"
      local stats
      stats=$(calc_stats "${vals[@]}")
      local n min avg p50 p95 max
      read -r n min avg p50 p95 max <<< "$stats"
      local unique_statuses
      unique_statuses=$(echo "$statuses" | tr ' ' '\n' | sort | uniq -c | tr '\n' ' ')

      printf "%-14s  %-10s  %5s  %7s  %7s  %7s  %7s  %7s  %6s  %-20s\n" \
        "$phase" "$scenario" "$n" "$min" "$avg" "$p50" "$p95" "$max" "$errors" "$unique_statuses"
    done

    echo
    echo "Légende : success = qty=5  (CONFIRMED attendu)"
    echo "          failure = qty=200 (CANCELLED attendu, stock insuffisant)"
    echo
    echo "Durée mesurée :"
    [[ "$SKIP_1A" != "true" ]] && echo "  1a — de POST /orders jusqu'à statut terminal (polling toutes les 500ms)"
    [[ "$SKIP_1B" != "true" ]] && echo "  1b — de POST /orders jusqu'à statut terminal (polling toutes les 500ms)"
    [[ "$SKIP_2"  != "true" ]] && echo "  2  — durée totale du POST /saga/orders synchrone (Temporal attend le workflow)"
  } > "$RESULTS_FILE"

  echo -e "${GREEN}[INFO]${NC}  Résultats écrits dans : ${BOLD}$RESULTS_FILE${NC}"
}

# ─── Bannière ─────────────────────────────────────────────────────────────────

print_banner() {
  echo
  echo -e "${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       TESTS DE PERFORMANCE — SAGA POC                 ║${NC}"
  echo -e "${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
  echo
  echo "  Mesure le temps bout-en-bout de la saga :"
  echo "    succès  : qty=5   → chaque étape réussit → CONFIRMED"
  echo "    échec   : qty=200 → stock refuse → compensation → CANCELLED"
  echo
  echo "  Phases couvertes :"
  [[ "$SKIP_1A" != "true" ]] && echo "    1a — Chorégraphie sans Outbox  (ports 5101+)"
  [[ "$SKIP_1B" != "true" ]] && echo "    1b — Chorégraphie + Outbox     (ports 5111+)"
  [[ "$SKIP_2"  != "true" ]] && echo "    2  — Orchestration (Temporal)  (ports 5200+)"
  echo
  echo "  Runs par scénario : $RUNS"
  echo
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 [all|1a|1b|2] [--runs N]

  all   Toutes les phases (défaut)
  1a    SAGA Chorégraphiée sans Outbox  (http://localhost:5101)
  1b    SAGA Chorégraphiée + Outbox     (http://localhost:5111)
  2     SAGA Orchestrée (Temporal)      (http://localhost:5200)

Options:
  --runs N       Nombre d'itérations par scénario (défaut: $RUNS)
  --output FILE  Fichier de résultats (défaut: $RESULTS_FILE)
  -h, --help     Affiche ce message

Prérequis :
  Phase 1a : cd Saga-Choreography        && docker compose up -d
  Phase 1b : cd Saga-Choreography-Outbox && docker compose up -d
  Phase 2  : cd Saga-Orchestration       && docker compose up -d
EOF
  exit 0
}

# ─── Entry point ──────────────────────────────────────────────────────────────

main() {
  local target="all"

  # Parsing des arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help) usage ;;
      --runs)
        shift
        if [[ -z "${1:-}" || ! "$1" =~ ^[0-9]+$ ]]; then
          echo -e "${RED}[ERREUR]${NC} --runs attend un entier positif" >&2; exit 1
        fi
        RUNS="$1"
        ;;
      --output)
        shift
        if [[ -z "${1:-}" ]]; then
          echo -e "${RED}[ERREUR]${NC} --output attend un nom de fichier" >&2; exit 1
        fi
        RESULTS_FILE="$1"
        ;;
      all|1a|1b|2) target="$1" ;;
      *) echo -e "${RED}Option inconnue : '$1'${NC}" >&2; usage ;;
    esac
    shift
  done

  # Si target est spécifique, skip les autres
  [[ "$target" != "all" && "$target" != "1a" ]] && SKIP_1A=true
  [[ "$target" != "all" && "$target" != "1b" ]] && SKIP_1B=true
  [[ "$target" != "all" && "$target" != "2"  ]] && SKIP_2=true

  check_prereqs "$target"
  print_banner

  # ── Phase 1a ────────────────────────────────────────────────────────────────
  if [[ "$SKIP_1A" != "true" ]]; then
    log_section "PHASE 1a — Chorégraphie sans Outbox"
    if ! probe_chor "1a" "$CHOR_ORDER_URL"; then
      log_warn "Phase 1a skippée (probe KO)"
    else
      log_section "1a — Scénario SUCCÈS (qty=5 → CONFIRMED attendu)"
      bench_chor "1a" "$CHOR_ORDER_URL" 5 "success"

      log_section "1a — Scénario ÉCHEC (qty=200 → CANCELLED attendu)"
      bench_chor "1a" "$CHOR_ORDER_URL" 200 "failure"
    fi
  fi

  # ── Phase 1b ────────────────────────────────────────────────────────────────
  if [[ "$SKIP_1B" != "true" ]]; then
    log_section "PHASE 1b — Chorégraphie + Outbox"
    if ! probe_chor "1b" "$OUTBOX_ORDER_URL"; then
      log_warn "Phase 1b skippée (probe KO)"
    else
      log_section "1b — Scénario SUCCÈS (qty=5 → CONFIRMED attendu)"
      bench_chor "1b" "$OUTBOX_ORDER_URL" 5 "success"

      log_section "1b — Scénario ÉCHEC (qty=200 → CANCELLED attendu)"
      bench_chor "1b" "$OUTBOX_ORDER_URL" 200 "failure"
    fi
  fi

  # ── Phase 2 ─────────────────────────────────────────────────────────────────
  if [[ "$SKIP_2" != "true" ]]; then
    log_section "PHASE 2 — Orchestration Temporal"
    if ! probe_orch; then
      log_warn "Phase 2 skippée (probe KO)"
    else
      log_section "2 — Scénario SUCCÈS (qty=5 → CONFIRMED attendu)"
      bench_orch "success" 5

      log_section "2 — Scénario ÉCHEC (qty=200 → CANCELLED attendu)"
      bench_orch "failure" 200
    fi
  fi

  print_summary
  write_results_file
}

main "$@"
