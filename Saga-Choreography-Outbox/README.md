# Phase 1b — SAGA Chorégraphiée + Transactional Outbox

> **Objectif :** démontrer que l'Outbox élimine le *dual-write problem* identifié en Phase 1a.

## Différence clé vs Phase 1a

| | Phase 1a (`Saga-Choreography/`) | Phase 1b (ce dossier) |
|---|---|---|
| **Stockage** | In-memory (`ConcurrentDictionary`) | SQLite via EF Core |
| **Publication événement** | `publish.Publish()` direct depuis le handler HTTP | `OutboxMessage` écrit en BDD, livré par le poller |
| **Atomicité** | ✗ Deux opérations séparées (store + AMQP) | ✓ Une seule transaction (Order + OutboxMessage) |
| **Crash après sauvegarde** | Événement perdu → saga bloquée en PENDING | Poller reprend → saga continue |

## Lancement

```bash
docker compose up --build
```

Services disponibles :
- **OrderService** : http://localhost:5111
- **StockService** : http://localhost:5112
- **PaymentService** : http://localhost:5113
- **RabbitMQ Management** : http://localhost:15672 (guest/guest)

## Scénarios de test

### Happy path
```bash
curl -X POST http://localhost:5111/orders \
  -H "Content-Type: application/json" \
  -d '{"productId":"PROD-1","quantity":5}'
```

### Failure path (stock insuffisant — qté > 100)
```bash
curl -X POST http://localhost:5111/orders \
  -H "Content-Type: application/json" \
  -d '{"productId":"PROD-1","quantity":150}'
```

### Simulation crash (Outbox résilient)
```bash
# Simule un crash après le commit de la transaction.
# L'ordre restera PENDING quelques secondes, puis le OutboxPollerService
# livrera l'événement OrderCreated → la saga progressera normalement.
curl -X POST "http://localhost:5111/orders?simulateCrash=true" \
  -H "Content-Type: application/json" \
  -d '{"productId":"PROD-1","quantity":5}'

# Comparer avec Phase 1a : le même appel laisse la commande bloquée PENDING indéfiniment.
```

### Vérifier l'état d'une commande
```bash
curl http://localhost:5111/orders
```

## Architecture Outbox

```
POST /orders
    │
    ├─── BEGIN TRANSACTION
    │       ├─ INSERT Orders (status=PENDING)
    │       └─ INSERT OutboxMessages (OrderCreated serialisé)
    └─── COMMIT ──────────────────────────────── atomique
                                                     │
                                          [OutboxPollerService]
                                          toutes les 2 secondes
                                                     │
                                          SELECT * FROM OutboxMessages
                                          WHERE ProcessedAt IS NULL
                                                     │
                                          IBus.Publish(OrderCreated)
                                                     │
                                          UPDATE OutboxMessages
                                          SET ProcessedAt = NOW()
```

## Reproduire le dual-write problem (comparaison)

```bash
# Phase 1a — commande bloquée
curl -X POST "http://localhost:5101/orders?simulateCrash=true" \
  -H "Content-Type: application/json" \
  -d '{"productId":"PROD-1","quantity":5}'
# → La commande reste PENDING indéfiniment

# Phase 1b — saga continue grâce à l'Outbox
curl -X POST "http://localhost:5111/orders?simulateCrash=true" \
  -H "Content-Type: application/json" \
  -d '{"productId":"PROD-1","quantity":5}'
# → Après ~2s, le poller livre l'événement, la commande passe CONFIRMED
```
