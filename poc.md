# POC — Transactions Inter-Services (Pattern SAGA)

> **Référence :** [ADR-005 — Requêtes transactionnelles Inter-Services](../../../ADR/Api/ADR-005-transaction-inter-service.md)

## Objectif

Valider expérimentalement les deux variantes du pattern SAGA (chorégraphie et orchestration) sur un scénario métier concret, afin de déterminer laquelle est la plus adaptée à notre contexte.

---

## 1. Scénario métier commun

Un cas partagé entre les deux phases permet une comparaison objective : **Création de commande**.

```
T1: OrderService   → Créer la commande (statut PENDING)
T2: StockService   → Réserver le stock
T3: PaymentService → Déclencher le paiement

Compensations :
C2: StockService   → Libérer le stock
C1: OrderService   → Annuler la commande
```

Les deux chemins à valider :

- **Happy path** : T1 → T2 → T3 → commande confirmée
- **Failure path** : T1 → T2 → T3 ✗ (paiement refusé) → C2 → C1 → commande annulée

---

## 2. Organisation en deux phases

| Phase | Variante | Outil proposé | Objectif |
|-------|----------|---------------|----------|
| **Phase 1** | SAGA Chorégraphiée | **RabbitMQ** (via MassTransit) | Valider l'approche event-driven, mesurer la complexité de debug |
| **Phase 2** | SAGA Orchestrée | **Temporal** (.NET SDK) | Valider l'orchestration centralisée, comparer la lisibilité et la résilience |

> **MassTransit** s'intègre nativement avec .NET et supporte les sagas chorégraphiées avec state machine.  
> **Temporal** dispose d'un SDK .NET mature et d'un dashboard de monitoring inclus.

---

## 3. Arborescence du POC

```
POC/Api/transactions/
├── Saga-Choreography/                # Phase 1
│   ├── src/
│   │   ├── OrderService/
│   │   ├── StockService/
│   │   ├── PaymentService/
│   │   └── Contracts/                # Events partagés (NuGet interne)
│   ├── docker-compose.yml            # RabbitMQ + services + BDD
│   └── README.md                     # Instructions de lancement + scénarios
│
├── Saga-Orchestration/               # Phase 2
│   ├── src/
│   │   ├── OrderService/
│   │   ├── StockService/
│   │   ├── PaymentService/
│   │   └── SagaOrchestrator/         # Workflows Temporal
│   ├── docker-compose.yml            # Temporal Server + services + BDD
│   └── README.md
│
├── EVALUATION.md                     # Grille de comparaison finale
└── poc.md                            # Ce fichier
```

---

## 4. Critères d'évaluation

| Critère | Comment le mesurer |
|---------|--------------------|
| **Complexité de mise en place** | Temps de dev, lignes de code, courbe d'apprentissage |
| **Lisibilité du flux** | Facilité à tracer une saga de bout en bout |
| **Gestion des erreurs** | Compensation automatique, retry, dead-letter |
| **Idempotence** | Rejouer un message : le système reste-t-il cohérent ? |
| **Observabilité** | Logs, tracing distribué, dashboard |
| **Résilience** | Comportement si un service tombe pendant une saga |
| **Overhead opérationnel** | Infra à maintenir (broker, Temporal server…) |

---

## 5. Déroulement recommandé

### Étape 1 — Setup commun

- 3 microservices minimalistes en **.NET**
- Chacun avec sa propre BDD (SQLite ou PostgreSQL)
- Communication synchrone via **gRPC** (cohérent avec ADR-004)
- Conteneurisation via **Docker Compose**

### Étape 2 — Phase 1 : Chorégraphie

- Ajouter **RabbitMQ** comme broker de messages
- Intégrer **MassTransit** avec state machine dans chaque service
- Implémenter le flux d'événements et les compensations
- Tester le happy path et le failure path

### Étape 3 — Phase 2 : Orchestration

- Déployer **Temporal Server** (via Docker)
- Créer un `SagaOrchestrator` avec workflows Temporal (.NET SDK)
- Implémenter le même scénario métier via orchestration
- Tester le happy path et le failure path

### Étape 4 — Tests de chaos

Sur les deux variantes, simuler :

- **Service down** pendant une saga en cours
- **Timeout** sur un appel inter-service
- **Message dupliqué** (rejouer un événement)
- **Compensation qui échoue** (vérifier le retry / dead-letter)

### Étape 5 — Évaluation comparative

- Remplir la grille de critères dans `EVALUATION.md`
- Rédiger une recommandation factuelle
- Mettre à jour le statut de l'ADR-005 avec la décision
