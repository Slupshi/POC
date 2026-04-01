# Grille d'évaluation — SAGA Chorégraphie vs Orchestration

> **Contexte :** POC réalisé sur un scénario *Création de commande* impliquant trois services (OrderService, StockService, PaymentService).  
> **Phase 1** — SAGA Chorégraphiée : RabbitMQ + MassTransit  
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

| Sous-critère | Chorégraphie | Orchestration |
|---|---|---|
| Lignes de code métier | ⚠️ Dispersées dans 3 services + Contracts | ✅ Centralisées dans le workflow |
| Courbe d'apprentissage | ⚠️ MassTransit + state machine | ⚠️ Temporal SDK + concepts workflow |
| Configuration initiale | ⚠️ RabbitMQ, exchanges, bindings | ❌ Temporal Server + Worker + UI |
| Ajout d'une nouvelle étape | ❌ Modifier N services + ajouter des events | ✅ Ajouter une activity dans le workflow |
| **Verdict** | ⚠️ | ✅ |

---

### 2. Lisibilité du flux

| Sous-critère | Chorégraphie | Orchestration |
|---|---|---|
| Flux visible en un seul endroit | ❌ Événements répartis entre services | ✅ Code séquentiel dans `OrderSagaWorkflow` |
| Compréhension du chemin de compensation | ❌ Reconstruction mentale nécessaire | ✅ Bloc try/catch explicite |
| Onboarding d'un nouveau développeur | ❌ Doit connaître tous les consumers | ✅ Un seul fichier workflow à lire |
| Documentation vivante | ❌ Implicite (chaîne d'événements) | ✅ Le code est la documentation |
| **Verdict** | ❌ | ✅ |

---

### 3. Gestion des erreurs et compensations

| Sous-critère | Chorégraphie | Orchestration |
|---|---|---|
| Déclenchement des compensations | ⚠️ Via événements `*Failed` (couplage implicite) | ✅ `try/catch` dans le workflow |
| Retry automatique | ✅ MassTransit retry policies | ✅ Retry natif Temporal par activity |
| Dead-letter / messages orphelins | ⚠️ Queues `_error` à surveiller manuellement | ✅ Workflow en état FAILED dans Temporal UI |
| Compensation partielle (C4 chaos test) | ❌ Événements perdus si consumer down | ✅ Temporal reprend où il s'est arrêté |
| **Verdict** | ⚠️ | ✅ |

---

### 4. Idempotence

| Sous-critère | Chorégraphie | Orchestration |
|---|---|---|
| Réjeu d'un message (C3 chaos test) | ⚠️ À gérer manuellement dans chaque consumer | ✅ Temporal garantit l'exécution une seule fois par activity |
| Concurrence de sagas simultanées | ⚠️ Risque de race condition entre consumers | ✅ Isolation par workflow ID |
| Cohérence après redémarrage | ⚠️ Dépend de la persistence MassTransit | ✅ Journal Temporal persistant |
| **Verdict** | ⚠️ | ✅ |

---

### 5. Observabilité

| Sous-critère | Chorégraphie | Orchestration |
|---|---|---|
| Dashboard intégré | ⚠️ RabbitMQ UI (queues/messages uniquement) | ✅ Temporal UI (historique complet d'exécution) |
| Traçabilité d'une saga de bout en bout | ❌ Corrélation manuelle par `correlationId` dans les logs | ✅ Timeline par workflow ID dans Temporal UI |
| Visibilité des compensations exécutées | ❌ Logs à corréler manuellement | ✅ Activities affichées avec statut individuel |
| Alerting / monitoring prod | ⚠️ À câbler soi-même (Datadog, Grafana…) | ⚠️ À câbler soi-même (métriques Temporal exportables) |
| **Verdict** | ❌ | ✅ |

---

### 6. Résilience (tests de chaos)

| Scénario | Chorégraphie | Orchestration |
|---|---|---|
| **C1** — Service down en cours de saga | ❌ Message perdu ou bloqué en queue | ✅ Workflow en attente, reprise automatique |
| **C2** — Timeout inter-service | ⚠️ Timeout MassTransit configurable, pas de reprise d'état | ✅ Activity timeout + retry Temporal |
| **C3** — Message / requête dupliqué | ⚠️ Idempotence à implémenter manuellement | ✅ Déduplication native par workflow ID |
| **C4** — Compensation qui échoue | ❌ Dead-letter, perte de cohérence possible | ✅ Workflow FAILED, visible et rejouable |
| **Verdict** | ❌ | ✅ |

---

### 7. Couplage entre services

| Sous-critère | Chorégraphie | Orchestration |
|---|---|---|
| Dépendance directe entre services | ✅ Aucune (communication via events) | ⚠️ Orchestrateur connaît tous les services |
| Partage de contrats (events/API) | ⚠️ Projet `Contracts` partagé | ✅ Interfaces HTTP locales à l'orchestrateur |
| Impact d'un changement de contrat | ❌ Tous les consumers doivent évoluer | ⚠️ Seul l'orchestrateur évolue |
| **Verdict** | ⚠️ | ✅ |

---

### 8. Overhead opérationnel

| Sous-critère | Chorégraphie | Orchestration |
|---|---|---|
| Infra additionnelle | ⚠️ RabbitMQ (1 conteneur) | ❌ Temporal Server + PostgreSQL (2 conteneurs) |
| Complexité de déploiement | ✅ Simple (docker-compose standard) | ⚠️ Temporal cluster en prod (HA) |
| Hébergement cloud disponible | ✅ RabbitMQ managé (CloudAMQP, AmazonMQ…) | ✅ Temporal Cloud disponible |
| Maintenance à long terme | ✅ MassTransit bien établi | ⚠️ Temporal encore en maturation sur .NET |
| **Verdict** | ✅ | ⚠️ |

---

### 9. Scalabilité

| Sous-critère | Chorégraphie | Orchestration |
|---|---|---|
| Scalabilité horizontale des services | ✅ Natif (consumers en concurrence) | ✅ Workers Temporal scalables |
| Passage à un grand nombre de sagas | ✅ Load naturellement réparti sur le broker | ⚠️ Dépend de la capacité du cluster Temporal |
| **Verdict** | ✅ | ⚠️ |

---

## Synthèse globale

| Critère | Poids | Chorégraphie | Orchestration |
|---|:---:|:---:|:---:|
| Complexité de mise en place | 15 % | ⚠️ 2/4 | ✅ 3/4 |
| Lisibilité du flux | 20 % | ❌ 1/4 | ✅ 4/4 |
| Gestion des erreurs | 20 % | ⚠️ 2/4 | ✅ 4/4 |
| Idempotence | 10 % | ⚠️ 2/4 | ✅ 4/4 |
| Observabilité | 15 % | ❌ 1/4 | ✅ 4/4 |
| Résilience (chaos tests) | 10 % | ❌ 1/4 | ✅ 4/4 |
| Couplage entre services | 5 % | ⚠️ 2/4 | ✅ 3/4 |
| Overhead opérationnel | 5 % | ✅ 4/4 | ⚠️ 2/4 |
| **Score pondéré** | **100 %** | **1,65 / 4** | **3,75 / 4** |

---

## Recommandation

### Adopter : **SAGA Orchestrée avec Temporal**

Les tests de chaos et la pratique du POC confirment que l'orchestration répond mieux aux exigences identifiées dans l'ADR-005 :

1. **Traçabilité bout-en-bout** : Temporal UI offre une visibilité immédiate sur chaque étape et chaque compensation, sans corrélation manuelle de logs.
2. **Résilience prouvée** : les 4 scénarios de chaos (C1–C4) passent sans intervention manuelle ; la chorégraphie échoue sur C1 et C4.
3. **Maintenabilité** : le flux de saga est entièrement décrit dans `OrderSagaWorkflow.cs` ; un développeur peut comprendre, modifier et tester le flux sans parcourir N services.
4. **Idempotence garantie** : la déduplication par `workflowId` élimine les cas de rejoue non désirés.

### Réserves à adresser avant adoption

| Réserve | Action recommandée |
|---|---|
| Overhead infra Temporal en production | Évaluer **Temporal Cloud** pour réduire la charge opérationnelle |
| Coût du single point of coordination | Dimensionner le cluster Temporal (HA) dès le départ |
| Maturité du SDK .NET Temporal | Surveiller les releases ; contribuer aux issues si besoin |

### Cas où la chorégraphie reste pertinente

La chorégraphie peut être conservée pour des flux **simples, non critiques**, sans compensation ni exigence forte de traçabilité (ex. : notifications, enrichissement de données en cascade).

---
