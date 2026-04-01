# Grille d'évaluation — SAGA Chorégraphie vs Orchestration

> **Contexte :** POC réalisé sur un scénario *Création de commande* impliquant trois services (OrderService, StockService, PaymentService).  
> **Phase 1a** — SAGA Chorégraphiée : RabbitMQ + MassTransit (état en mémoire)  
> **Phase 1b** — SAGA Chorégraphiée + Transactional Outbox : état SQLite, publication garantie  
> **Phase 2** — SAGA Orchestrée : Temporal (.NET SDK)

---

## Légende

| Symbole | Signification |
|---------|---------------|
| ✅ | Point fort / avantage net |
| ⚠️ | Acceptable avec réserves |
| ❌ | Point faible / inconvénient |

---

## Grille comparative

### 1. Complexité de mise en place

| Sous-critère | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|---|---|---|
| Lignes de code métier | ⚠️ Dispersées dans 3 services + Contracts | ❌ Idem + Outbox entity, EF migrations, OutboxPollerService | ✅ Centralisées dans le workflow |
| Courbe d'apprentissage | ⚠️ MassTransit + state machine | ❌ MassTransit + EF Core + Outbox pattern | ⚠️ Temporal SDK + concepts workflow |
| Configuration initiale | ⚠️ RabbitMQ, exchanges, bindings | ❌ RabbitMQ + SQLite + EF migrations + OutboxPollerService | ❌ Temporal Server + Worker + UI |
| Ajout d'une nouvelle étape | ❌ Modifier N services + ajouter des events | ❌ Même problème + OutboxMessages à synchroniser | ✅ Ajouter une activity dans le workflow |
| **Verdict** | ⚠️ | ❌ | ✅ |

---

### 2. Lisibilité du flux

| Sous-critère | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|---|---|---|
| Flux visible en un seul endroit | ❌ Événements répartis entre services | ❌ Idem + indirection via outbox table | ✅ Code séquentiel dans `OrderSagaWorkflow` |
| Compréhension du chemin de compensation | ❌ Reconstruction mentale nécessaire | ❌ Même problème | ✅ Bloc try/catch explicite |
| Onboarding d'un nouveau développeur | ❌ Doit connaître tous les consumers | ❌ Idem + OutboxPollerService à comprendre | ✅ Un seul fichier workflow à lire |
| Documentation vivante | ❌ Implicite (chaîne d'événements) | ❌ Implicite + mécanique outbox cachée | ✅ Le code est la documentation |
| **Verdict** | ❌ | ❌ | ✅ |

---

### 3. Gestion des erreurs et compensations

| Sous-critère | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|---|---|---|
| Déclenchement des compensations | ⚠️ Via événements `*Failed` (couplage implicite) | ✅ Publication atomique garantie (Order + OutboxMessage en une transaction) | ✅ `try/catch` dans le workflow |
| Retry automatique | ✅ MassTransit retry policies | ✅ MassTransit retry + Outbox poller (at-least-once) | ✅ Retry natif Temporal par activity |
| Dead-letter / messages orphelins | ⚠️ Queues `_error` à surveiller manuellement | ⚠️ Outbox couvre la publication initiale ; queues `_error` toujours possibles en aval | ✅ Workflow en état FAILED dans Temporal UI |
| Compensation partielle (C4 chaos test) | ❌ État mémoire perdu si order-service redémarre | ✅ SQLite préserve l'état → compensation CANCELLED réussie (C4 chaos test ✅) | ✅ Temporal reprend où il s'est arrêté |
| **Verdict** | ⚠️ | ✅ | ✅ |

---

### 4. Idempotence

| Sous-critère | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|---|---|---|
| Réjeu d'un message (C3 chaos test) | ⚠️ À gérer manuellement dans chaque consumer | ⚠️ At-least-once delivery via outbox → idempotence consumer toujours requise | ✅ Temporal garantit l'exécution une seule fois par activity |
| Concurrence de sagas simultanées | ⚠️ Risque de race condition entre consumers | ⚠️ Même risque ; contention possible sur l'outbox table si plusieurs instances | ✅ Isolation par workflow ID |
| Cohérence après redémarrage | ⚠️ État mémoire perdu au redémarrage | ✅ SQLite garantit la persistance de l'état entre redémarrages | ✅ Journal Temporal persistant |
| **Verdict** | ⚠️ | ⚠️ | ✅ |

---

### 5. Observabilité

| Sous-critère | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|---|---|---|
| Dashboard intégré | ⚠️ RabbitMQ UI (queues/messages uniquement) | ⚠️ RabbitMQ UI + état outbox interrogeable en SQLite | ✅ Temporal UI (historique complet d'exécution) |
| Traçabilité d'une saga de bout en bout | ❌ Corrélation manuelle par `correlationId` dans les logs | ❌ Même problème ; l'outbox n'améliore pas la traçabilité end-to-end | ✅ Timeline par workflow ID dans Temporal UI |
| Visibilité des compensations exécutées | ❌ Logs à corréler manuellement | ❌ Même problème | ✅ Activities affichées avec statut individuel |
| Alerting / monitoring prod | ⚠️ À câbler soi-même (Datadog, Grafana…) | ⚠️ Idem + monitoring de la table outbox à prévoir | ⚠️ À câbler soi-même (métriques Temporal exportables) |
| **Verdict** | ❌ | ❌ | ✅ |

---

### 6. Résilience (tests de chaos)

| Scénario | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|---|---|---|
| **C1** — Service down en cours de saga | ⚠️ RabbitMQ conserve les messages ; état mémoire perdu si order-service redémarre | ✅ Même résilience broker + état SQLite survit au redémarrage d'order-service | ✅ Workflow en attente, reprise automatique |
| **C2** — Timeout inter-service | ⚠️ Timeout MassTransit configurable, pas de reprise d'état | ⚠️ Même comportement ; l'outbox ne change pas la latence inter-services | ✅ Activity timeout + retry Temporal |
| **C3** — Crash / dual-write problem | ❌ Crash après sauvegarde → événement non publié → saga bloquée en PENDING indéfiniment | ✅ OutboxPoller livre l'événement après le crash → saga converge | ✅ Déduplication native par workflow ID |
| **C4** — Compensation qui échoue | ❌ État mémoire perdu au redémarrage → dead-letter, perte de cohérence | ✅ SQLite préserve l'état → compensation CANCELLED propre, pas de dead-letter | ✅ Workflow FAILED, visible et rejouable |
| **Verdict** | ❌ | ✅ | ✅ |

---

### 7. Couplage entre services

| Sous-critère | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|---|---|---|
| Dépendance directe entre services | ✅ Aucune (communication via events) | ✅ Aucune (communication via events + outbox) | ⚠️ Orchestrateur connaît tous les services |
| Partage de contrats (events/API) | ⚠️ Projet `Contracts` partagé | ⚠️ Même projet `Contracts` partagé | ✅ Interfaces HTTP locales à l'orchestrateur |
| Impact d'un changement de contrat | ❌ Tous les consumers doivent évoluer | ❌ Même problème | ⚠️ Seul l'orchestrateur évolue |
| **Verdict** | ⚠️ | ⚠️ | ✅ |

---

### 8. Overhead opérationnel

| Sous-critère | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|---|---|---|
| Infra additionnelle | ⚠️ RabbitMQ (1 conteneur) | ❌ RabbitMQ + SQLite avec volume persistant | ❌ Temporal Server + PostgreSQL (2 conteneurs) |
| Complexité de déploiement | ✅ Simple (docker-compose standard) | ⚠️ docker-compose avec volume BDD + migrations EF au démarrage | ⚠️ Temporal cluster en prod (HA) |
| Hébergement cloud disponible | ✅ RabbitMQ manaé (CloudAMQP, AmazonMQ…) | ✅ RabbitMQ manaé + BDD manageg | ✅ Temporal Cloud disponible |
| Maintenance à long terme | ✅ MassTransit bien établi | ⚠️ MassTransit + schéma BDD outbox à maintenir | ⚠️ Temporal encore en maturation sur .NET |
| **Verdict** | ✅ | ⚠️ | ⚠️ |

---

### 9. Scalabilité

| Sous-critère | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|---|---|---|
| Scalabilité horizontale des services | ✅ Natif (consumers en concurrence) | ⚠️ Plusieurs instances → contention possible sur l'outbox table | ✅ Workers Temporal scalables |
| Passage à un grand nombre de sagas | ✅ Load naturellement réparti sur le broker | ⚠️ Contrôler les performances du poller SQLite à l'échelle | ⚠️ Dépend de la capacité du cluster Temporal |
| **Verdict** | ✅ | ⚠️ | ⚠️ |

---

## Synthèse globale

| Critère | Poids | 1a — Chorégraphie | 1b — Outbox | Orchestration |
|---|:---:|:---:|:---:|:---:|
| Complexité de mise en place | 15 % | ⚠️ 2/4 | ❌ 1/4 | ✅ 3/4 |
| Lisibilité du flux | 20 % | ❌ 1/4 | ❌ 1/4 | ✅ 4/4 |
| Gestion des erreurs | 20 % | ⚠️ 2/4 | ✅ 3/4 | ✅ 4/4 |
| Idempotence | 10 % | ⚠️ 2/4 | ⚠️ 2/4 | ✅ 4/4 |
| Observabilité | 15 % | ❌ 1/4 | ❌ 1/4 | ✅ 4/4 |
| Résilience (chaos tests) | 10 % | ❌ 1/4 | ✅ 3/4 | ✅ 4/4 |
| Couplage entre services | 5 % | ⚠️ 2/4 | ⚠️ 2/4 | ✅ 3/4 |
| Overhead opérationnel | 5 % | ✅ 4/4 | ⚠️ 2/4 | ⚠️ 2/4 |
| **Score pondéré** | **100 %** | **1,65 / 4** | **1,80 / 4** | **3,75 / 4** |

---

## Recommandation

### Adopter : **SAGA Orchestrée avec Temporal**

Les tests de chaos et la pratique du POC confirment que l'orchestration répond mieux aux exigences identifiées dans l'ADR-005 :

1. **Traçabilité bout-en-bout** : Temporal UI offre une visibilité immédiate sur chaque étape et chaque compensation, sans corrélation manuelle de logs.
2. **Résilience prouvée** : les 4 scénarios de chaos (C1–C4) passent sans intervention manuelle ; la chorégraphie 1a échoue sur C3 et C4, la 1b améliore C1/C3/C4 mais reste moins lisible et plus complexe.
3. **Maintenabilité** : le flux de saga est entièrement décrit dans `OrderSagaWorkflow.cs` ; un développeur peut comprendre, modifier et tester le flux sans parcourir N services.
4. **Idempotence garantie** : la déduplication par `workflowId` élimine les cas de rejoue non désirés.

### Note sur la Phase 1b (Outbox)

La Phase 1b démontre que l'Outbox pattern résout le *dual-write problem* (C3) et la perte d'état au redémarrage (C4), avec un score de **1,80 / 4** vs 1,65 pour la 1a. Cependant, elle **ne résout pas** les faiblesses structurelles de la chorégraphie : lisibilité du flux, observabilité, complexité de mise en place. Elle constitue une étape intermédiaire pour les équipes souhaitant migrer progressivement.

### Réserves à adresser avant adoption

| Réserve | Action recommandée |
|---|---|
| Overhead infra Temporal en production | Évaluer **Temporal Cloud** pour réduire la charge opérationnelle |
| Coût du single point of coordination | Dimensionner le cluster Temporal (HA) dès le départ |
| Maturité du SDK .NET Temporal | Surveiller les releases ; contribuer aux issues si besoin |

### Cas où la chorégraphie reste pertinente

La chorégraphie peut être conservée pour des flux **simples, non critiques**, sans compensation ni exigence forte de traçabilité (ex. : notifications, enrichissement de données en cascade).

---
