# Tests de chaos — SAGA POC (Étape 4)

## Vue d'ensemble

Le script [`chaos-tests.sh`](chaos-tests.sh) exécute **4 scénarios de chaos** sur **3 phases** du POC,
soit jusqu'à **12 tests indépendants**. L'objectif est de vérifier la résilience transactionnelle
de chaque variante du pattern SAGA face à des conditions adverses.

| Phase | Variante | Ports | Technologie de messaging |
|---|---|---|---|
| **1a** | Chorégraphie sans Outbox | 5101–5103 | RabbitMQ + MassTransit (état en mémoire) |
| **1b** | Chorégraphie + Outbox | 5111–5113 | RabbitMQ + MassTransit + SQLite (Transactional Outbox) |
| **2** | Orchestration | 5200–5203 | Temporal (workflow engine) |

---

## Prérequis

- Docker Desktop en cours d'exécution
- `bash`, `curl` disponibles dans le PATH
- Services démarrés via `docker compose up -d` dans chaque dossier de phase

```bash
# Démarrer chaque phase souhaitée
cd Saga-Choreography        && docker compose up -d
cd Saga-Choreography-Outbox && docker compose up -d
cd Saga-Orchestration       && docker compose up -d
```

---

## Utilisation

```bash
./chaos-tests.sh                   # Toutes les phases (défaut)
./chaos-tests.sh 1a                # Phase 1a uniquement
./chaos-tests.sh 1b                # Phase 1b uniquement
./chaos-tests.sh 2                 # Phase 2 uniquement
./chaos-tests.sh choreography      # Alias pour 1a
./chaos-tests.sh outbox            # Alias pour 1b
./chaos-tests.sh orchestration     # Alias pour 2
```

---

## Outils utilisés

| Outil | Rôle dans les tests |
|---|---|
| **`curl`** | Soumettre des commandes HTTP (`POST /orders`) et interroger les statuts (`GET /orders/{id}`) |
| **`docker compose stop/start`** | Arrêter et redémarrer un service pour simuler une panne (C1) |
| **`docker compose pause/unpause`** | Geler un processus sans le tuer pour simuler un freeze réseau ou un GC pause (C2) |
| **RabbitMQ Management API** (`http://localhost:15672`) | Compter les messages dans les queues `_error` (dead-letter) pour le scénario C4 |
| **Temporal UI** (`http://localhost:8088`) | Inspecter les workflows échoués après le scénario C4 en orchestration |

---

## Description des 4 scénarios

### C1 — Service down pendant une saga en cours

**Injection de défaillance** : `docker compose stop <service>` après la création de la commande.

Le service arrêté est celui qui consomme l'événement suivant dans la chaîne :
- **1a / 1b** : `stock-service` (consomme `OrderCreated`)
- **2** : `payment-service` (cible de l'activité T3)

**Étapes** :
1. Créer une commande (`qty=5`, chemin nominal)
2. Arrêter le service cible
3. Vérifier que la commande reste en `PENDING`
4. Redémarrer le service
5. Attendre la résolution finale (max 40 s)

**Comportement attendu** :

| Phase | Résultat attendu | Explication |
|---|---|---|
| 1a | `CONFIRMED` après redémarrage | RabbitMQ conserve le message dans la queue pendant l'indisponibilité du consumer |
| 1b | `CONFIRMED` après redémarrage | Idem 1a — de plus, l'état SQLite survit si c'est `order-service` qui redémarre |
| 2 | `CANCELLED` | Temporal détecte l'échec de l'activité (connection refused) et exécute les compensations (C2 + C1) |

---

### C2 — Timeout inter-service (docker pause / StartToCloseTimeout)

**Injection de défaillance** : `docker compose pause <service>` — le processus est suspendu sans être tué.

Le service gelé est celui dont on veut simuler un freeze ou un timeout :
- **1a / 1b** : `payment-service` (gèle après la publication de `StockReserved`)
- **2** : `stock-service` (gèle pendant l'activité T2 `ReserveStock`)

**Étapes** :
1. Créer une commande et lancer la saga
2. Geler le service cible avec `docker pause` (après un délai calibré)
3. Vérifier que la saga est bloquée (`PENDING` ou pas encore résolue)
4. Reprendre le service avec `docker unpause`
5. Attendre la résolution

**Comportement attendu** :

| Phase | Résultat attendu | Explication |
|---|---|---|
| 1a | `CONFIRMED` après unpause | Le message `StockReserved` attend en queue ; payment-service le consomme dès sa reprise |
| 1b | `CONFIRMED` après unpause | Identique à 1a |
| 2 | `CANCELLED` après 35 s | `StartToCloseTimeout=30s` expire → Temporal annule l'activité T2 et exécute C1 (`CancelOrder`) |

---

### C3 — Message dupliqué / dual-write / concurrence

Ce scénario est le **principal différenciateur** entre la phase 1a et la phase 1b.

#### Phase 1a et 1b — double requête simultanée

**Injection** : deux appels `POST /orders` avec le même contenu envoyés consécutivement.

**Étapes** :
1. Soumettre deux commandes identiques (même `productId`, même `quantity`)
2. Vérifier que les deux réponses contiennent des `id` distincts
3. Attendre que les deux sagas convergent indépendamment

**Comportement attendu** : deux IDs UUID différents, deux sagas parallèles sans interférence — MassTransit ne déduplique pas nativement.

#### Phase 1b — protection dual-write (`?simulateCrash=true`)

**Injection** : `POST /orders?simulateCrash=true` — le service simule un crash **après** l'écriture atomique (Order + OutboxMessage dans la même transaction SQLite), **avant** la publication sur RabbitMQ.

**Étapes** :
1. Envoyer la commande avec le flag `simulateCrash=true`
2. L'`OutboxPollerService` détecte le message non traité (délai max 2 s) et publie l'événement
3. Attendre la résolution de la saga (max 30 s)
4. En parallèle, effectuer le même test en 1a pour la comparaison

**Comportement attendu** :

| Phase | Résultat attendu | Explication |
|---|---|---|
| 1a | `PENDING` indéfiniment | L'événement n'est jamais publié car le crash survient avant `Publish()` |
| 1b | `CONFIRMED` (ou `CANCELLED`) | L'OutboxPoller reprend la livraison grâce à l'écriture atomique |

#### Phase 2 — workflows concurrents

**Injection** : deux `POST /saga/orders` lancés en parallèle (`&`).

**Comportement attendu** : Temporal attribue un `workflowId` UUID distinct à chaque requête — isolation totale, pas de collision.

---

### C4 — Compensation / résilience au redémarrage

Ce scénario teste ce qui se passe quand la **compensation elle-même échoue**, et c'est aussi un différenciateur majeur entre les phases.

#### Phase 1a — dead-letter (état mémoire perdu)

**Injection** :
1. Créer une commande `qty=200` (stock insuffisant → compensation déterministe)
2. Arrêter `order-service` immédiatement après la création
3. `stock-service` publie `StockReservationFailed` dans RabbitMQ
4. Redémarrer `order-service` (état mémoire effacé)

**Étapes de vérification** :
- Le nouveau processus `order-service` est vide et ne connaît pas la commande
- MassTransit tente de consommer `StockReservationFailed`, échoue (`KeyNotFoundException`), retente N fois
- Après épuisement des tentatives (~15 s), le message est acheminé vers la queue `_error`
- La commande reste introuvable dans le nouvel état (`not-found`)

**Comportement attendu** : dead-letter détecté via l'API RabbitMQ Management (`15672/api/queues`).

#### Phase 1b — compensation réussie (état SQLite préservé)

**Injection** : même séquence qu'en 1a, mais sur `Saga-Choreography-Outbox`.

**Comportement attendu** :
- Après redémarrage, `order-service` relit SQLite → la commande existe encore
- `StockReservationFailed` est consommé normalement → commande `CANCELLED`
- **Aucune dead-letter** générée

#### Phase 2 — workflow FAILED (MaximumAttempts=1)

**Injection** :
1. Lancer une saga `qty=200` (T2 `ReserveStock` échoue → Temporal déclenche la compensation C1 `CancelOrder`)
2. Arrêter `order-service` 400 ms après le lancement (T1 terminé, compensation pas encore exécutée)

**Comportement attendu** :
- L'activité `CancelOrder` (C1) échoue (`connection refused`)
- `MaximumAttempts=1` → pas de retry → le workflow se termine en **FAILED** dans Temporal UI
- La saga ne retourne pas `CANCELLED` proprement

**Vérification de reprise** : après redémarrage d'`order-service`, une nouvelle saga `qty=5` doit retourner `CONFIRMED`.

---

## Architecture de vérification

```
POST /orders  ──►  extract UUID  ──►  polling GET /orders/{id}  ──►  CONFIRMED | CANCELLED
                                      (toutes les 2 s, max configurable)
```

Pour la phase 2 (orchestration), la réponse du `POST /saga/orders` est synchrone :
Temporal bloque jusqu'à la fin du workflow. Pas de polling nécessaire.

La détection des dead-letters utilise l'API REST RabbitMQ :

```
GET http://localhost:15672/api/queues  →  filtrer les queues "*_error" avec messages > 0
```

---

## Tableau de synthèse des résultats attendus

| Scénario | Phase 1a | Phase 1b | Phase 2 |
|---|---|---|---|
| **C1** Service down | CONFIRMED (broker absorbe) | CONFIRMED (idem + SQLite) | CANCELLED (compensation Temporal) |
| **C2** Timeout/pause | CONFIRMED (reprise queue) | CONFIRMED (reprise queue) | CANCELLED (StartToCloseTimeout) |
| **C3** Dual-write / concurrent | PENDING indéfiniment ⚠️ | CONFIRMED (OutboxPoller) ✓ | IDs distincts, sagas isolées ✓ |
| **C4** Compensation échouée | Dead-letter RabbitMQ ⚠️ | CANCELLED (SQLite) ✓ | Workflow FAILED (MaxAttempts=1) ⚠️ |
