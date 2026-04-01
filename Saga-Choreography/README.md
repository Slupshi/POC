# POC SAGA Chorégraphiée — Phase 1

## Prérequis

- Docker

## Lancement

### Démarrer tous les services

```bash
docker compose up -d
```

| Service | URL |
|---------|-----|
| OrderService | http://localhost:5101 |
| StockService | http://localhost:5102 |
| PaymentService | http://localhost:5103 |
| RabbitMQ Dashboard | http://localhost:15672 (guest / guest) |

## Scénarios de test

### Happy path (quantité ≤ 100)

```bash
curl -X POST http://localhost:5101/orders -H "Content-Type: application/json" -d "{\"productId\": \"PROD-001\", \"quantity\": 5}"
```

Flux attendu : `OrderCreated → StockReserved → PaymentCompleted → Commande CONFIRMED`

### Échec stock (quantité > 100)

```bash
curl -X POST http://localhost:5101/orders -H "Content-Type: application/json" -d "{\"productId\": \"PROD-001\", \"quantity\": 200}"
```

Flux attendu : `OrderCreated → StockReservationFailed → Commande CANCELLED`

### Échec paiement (aléatoire, 1 chance sur 3)

Relancer plusieurs fois le happy path. En cas d'échec de paiement :

Flux attendu : `OrderCreated → StockReserved → PaymentFailed → OrderCancelled → Stock libéré`

### Vérifier l'état des commandes

```bash
curl http://localhost:5101/orders
```

## Architecture du flux

```
OrderService                StockService              PaymentService
     |                           |                          |
     |--- OrderCreated --------->|                          |
     |                           |--- StockReserved ------->|
     |                           |                          |
     |<-- PaymentCompleted ------|<-- PaymentCompleted -----|  (succès)
     |    → CONFIRMED            |                          |
     |                           |                          |
     |<-- PaymentFailed ---------|<-- PaymentFailed --------|  (échec)
     |    → CANCELLED            |                          |
     |--- OrderCancelled ------->|                          |
     |                           |    (libère le stock)     |
```
