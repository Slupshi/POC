# Tests de performance — SAGA POC

> Ce document explique le **protocole de test** employé dans `perf-tests.sh` et décrit comment lire le **tableau de résultats** affiché en fin d'exécution.

---

## 1. Objectif

Mesurer le **temps de traitement bout-en-bout** d'une saga — c'est-à-dire l'intervalle entre l'envoi de la commande et l'obtention d'un statut terminal — pour chacune des trois implémentations du POC, dans un scénario de succès et un scénario d'échec.

---

## 2. Implémentations couvertes

| Phase | Description | Port Order |
|-------|-------------|------------|
| **1a** | SAGA Chorégraphiée — RabbitMQ / MassTransit (état en mémoire) | `5101` |
| **1b** | SAGA Chorégraphiée + Transactional Outbox (SQLite) | `5111` |
| **2**  | SAGA Orchestrée — Temporal (.NET SDK) | `5200` |

---

## 3. Protocole de test

### 3.1 Scénarios

Deux scénarios sont exécutés pour chaque phase :

| Scénario | Quantité commandée | Comportement attendu | Statut terminal |
|----------|--------------------|----------------------|-----------------|
| **success** | `qty = 5` | Stock et paiement disponibles → saga nominale | `CONFIRMED` |
| **failure** | `qty = 200` | Stock insuffisant → déclenchement de la compensation | `CANCELLED` |

### 3.2 Mesure du temps

La mesure diffère selon le style d'implémentation :

- **Phase 1a et 1b (chorégraphie)** — le flux est asynchrone :
  1. `POST /orders` est envoyé avec la charge utile JSON.
  2. Le chronomètre démarre à l'envoi du POST.
  3. L'état de la commande est interrogé toutes les **500 ms** via `GET /orders/{id}`.
  4. Le chronomètre s'arrête dès qu'un statut terminal (`CONFIRMED` ou `CANCELLED`) est reçu.
  5. Si aucun statut terminal n'est atteint dans le **délai maximum de 60 secondes**, le run est comptabilisé comme erreur (timeout).

- **Phase 2 (orchestration Temporal)** — le flux est synchrone du point de vue du client :
  1. `POST /saga/orders` est envoyé.
  2. Le SagaOrchestrator attend la fin du workflow Temporal avant de répondre.
  3. La durée mesurée est simplement la **durée totale de la requête HTTP**, qui inclut l'exécution complète de toutes les activities Temporal.

### 3.3 Paramètres d'exécution

| Paramètre | Valeur par défaut | Contrôle |
|-----------|------------------|----------|
| Nombre de runs par scénario | **5** | `--runs N` |
| Timeout polling (1a/1b) | **60 s** | Variable `POLL_TIMEOUT` |
| Pause entre deux runs | **1 s** | Codé en dur (éviter les interférences) |
| Timeout requête HTTP (1a/1b) | **10 s** | `curl --max-time 10` |
| Timeout requête HTTP (2) | **90 s** | `curl --max-time 90` |

### 3.4 Probe préalable

Avant de lancer les mesures, le script effectue un **POST de diagnostic** (probe) sur chaque phase active. Si le service ne répond pas ou ne retourne pas d'UUID dans sa réponse, la phase est ignorée et un message d'aide est affiché.

---

## 4. Tableau de résultats

À la fin de l'exécution, le script affiche un tableau récapitulatif :

```
Phase          Scénario       N    min(ms)  avg(ms)  p50(ms)  p95(ms)  max(ms)  erreurs  statuts observés
────────────────────────────────────────────────────────────────────────────────────────────────────────────
1a             success        5      210      245      230      310      350        0     5 CONFIRMED
1a             failure        5      180      220      210      290      320        0     5 CANCELLED
...
```

### Signification de chaque colonne

| Colonne | Description |
|---------|-------------|
| **Phase** | Implémentation testée : `1a`, `1b` ou `2` |
| **Scénario** | `success` (qty=5, CONFIRMED attendu) ou `failure` (qty=200, CANCELLED attendu) |
| **N** | Nombre de runs ayant produit un résultat valide (hors timeouts et erreurs) |
| **min (ms)** | Durée minimale observée sur l'ensemble des runs |
| **avg (ms)** | Moyenne arithmétique des durées |
| **p50 (ms)** | Médiane — valeur centrale une fois les durées triées ; résistant aux pics isolés |
| **p95 (ms)** | 95e percentile — durée maximale observée dans 95 % des cas ; représente le « pire cas courant » (1 run sur 20 est plus lent) |
| **max (ms)** | Durée maximale absolue observée |
| **erreurs** | Nombre de runs ignorés : timeout dépassé ou absence d'UUID dans la réponse |
| **statuts observés** | Distribution des statuts terminaux reçus (ex. `5 CONFIRMED`, `3 CONFIRMED 2 CANCELLED`) |

### Interprétation

- **avg vs p50** : si `avg >> p50`, des pics ponctuels tirent la moyenne vers le haut. Préférer `p50` pour une appréciation de la latence typique.
- **p95** : indicateur de stabilité. Un `p95` très supérieur à `avg` signale une variabilité élevée (ex. premier cold-start Temporal, GC, contention réseau Docker).
- **erreurs > 0** : signe que le service n'a pas répondu dans le délai imparti. Augmenter `--runs` ou vérifier la santé des conteneurs si ce nombre est non nul.
- **statuts observés** : doit correspondre au scénario (tous `CONFIRMED` en success, tous `CANCELLED` en failure). Un mélange indique une instabilité fonctionnelle indépendante de la performance.

---

## 5. Prérequis et lancement

```bash
# Démarrer les environnements souhaités
cd Saga-Choreography        && docker compose up -d   # phase 1a
cd Saga-Choreography-Outbox && docker compose up -d   # phase 1b
cd Saga-Orchestration       && docker compose up -d   # phase 2

# Lancer tous les tests (5 runs par défaut)
./perf-tests.sh

# Lancer uniquement une phase avec 10 runs
./perf-tests.sh 1a --runs 10
./perf-tests.sh 2  --runs 10
```

> **Note Temporal** : au premier démarrage, le cluster Temporal met environ 30 secondes à passer en état *healthy*. Attendre que `docker compose ps` indique tous les services `healthy` avant de lancer les tests.

---

## 6. Limites et points d'attention

- Les mesures incluent la **latence réseau Docker** (bridge réseau local) et le sur-coût du polling HTTP pour les phases 1a/1b. Elles ne reflètent pas des conditions de production.
- La **gigue de scheduling** de Docker et les effets de **cold JIT** (.NET) peuvent gonfler les premières itérations. Augmenter `--runs` réduit cet effet statistiquement.
- Pour la phase 2, Temporal exécute les activities **séquentiellement dans le workflow** par conception : la latence reflète la somme des temps de chaque activity, ce qui explique des valeurs plus élevées que la chorégraphie en scénario de succès.
- Ces tests mesurent la **latence fonctionnelle de bout en bout**, non le débit (*throughput*). Pour évaluer la concurrence, d'autres outils (k6, Locust) seraient plus adaptés.
