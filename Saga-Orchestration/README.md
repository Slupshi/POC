# POC SAGA Orchestrée — Phase 2

## Prérequis

- Docker

## Architecture

```
                         ┌──────────────────────┐
                         │   SagaOrchestrator    │
                         │   (Temporal Worker)   │
                         │                       │
  POST /saga/orders ───▶ │   OrderSagaWorkflow   │
                         └──────┬───┬───┬────────┘
                                │   │   │
                    ┌───────────┘   │   └───────────┐
                    ▼               ▼               ▼
             ┌────────────┐ ┌────────────┐ ┌──────────────┐
             │OrderService│ │StockService│ │PaymentService│
             │  :5201     │ │  :5202     │ │  :5203       │
             └────────────┘ └────────────┘ └──────────────┘
```

Le **SagaOrchestrator** centralise toute la logique de coordination :
- Il exécute le workflow Temporal `OrderSagaWorkflow`
- Le workflow appelle séquentiellement les 3 services via HTTP (activities Temporal)
- En cas d'échec, les compensations sont exécutées automatiquement dans l'ordre inverse

## Lancement

### Démarrer tous les services

```bash
docker compose up -d
```

| Service | URL |
|---------|-----|
| SagaOrchestrator | http://localhost:5200 |
| OrderService | http://localhost:5201 |
| StockService | http://localhost:5202 |
| PaymentService | http://localhost:5203 |
| Temporal gRPC | localhost:7233 |
| Temporal UI | http://localhost:8088 |

## Scénarios de test

### Happy path (quantité ≤ 100)

```bash
curl -X POST http://localhost:5200/saga/orders \
  -H "Content-Type: application/json" \
  -d "{\"productId\": \"PROD-001\", \"quantity\": 5}"
```

Flux attendu :
```
T1: CreateOrder (PENDING)
T2: ReserveStock → OK
T3: ProcessPayment → OK
    ConfirmOrder → CONFIRMED
```

### Échec stock (quantité > 100)

```bash
curl -X POST http://localhost:5200/saga/orders \
  -H "Content-Type: application/json" \
  -d "{\"productId\": \"PROD-001\", \"quantity\": 200}"
```

Flux attendu :
```
T1: CreateOrder (PENDING)
T2: ReserveStock → ÉCHEC
C1: CancelOrder → CANCELLED
```

### Échec paiement (aléatoire, 1 chance sur 3)

Relancer plusieurs fois le happy path. En cas d'échec de paiement :

```
T1: CreateOrder (PENDING)
T2: ReserveStock → OK
T3: ProcessPayment → ÉCHEC
C2: ReleaseStock
C1: CancelOrder → CANCELLED
```

### Vérifier l'état des commandes

```bash
curl http://localhost:5201/orders
```

### Observer les workflows dans Temporal UI

Ouvrir http://localhost:8088 pour visualiser :
- L'historique des workflows exécutés
- Le détail de chaque étape (activities)
- Les échecs et compensations

## Différences clés avec la Phase 1 (Chorégraphie)

| Aspect | Chorégraphie (Phase 1) | Orchestration (Phase 2) |
|--------|----------------------|------------------------|
| **Coordination** | Décentralisée (événements) | Centralisée (workflow) |
| **Broker** | RabbitMQ + MassTransit | Temporal Server |
| **Flux** | Implicite (chaîne d'événements) | Explicite (code séquentiel) |
| **Compensations** | Déclenchées par événements | Blocs try/catch dans le workflow |
| **Observabilité** | Logs + dashboard RabbitMQ | Temporal UI (historique complet) |
| **Debug** | Suivre les événements entre services | Lire le code du workflow |
