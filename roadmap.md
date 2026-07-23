# NexusEdgeEA - Roadmap

## Vision du projet

NexusEdgeEA est un Expert Advisor MT5 spécialisé principalement sur XAUUSD.

L'objectif est de construire un système autonome capable de :

- analyser le contexte du marché ;
- détecter les opportunités avec une approche SMC / Price Action ;
- gérer intelligemment le risque ;
- protéger les profits ;
- apprendre des données de trading réel.


---

# Historique des sprints


# Sprint 0 - Foundation Core ✅

Statut : Terminé

Objectif :

Construire une architecture modulaire et robuste.

Modules principaux :

- Market Context
- Market Structure
- Filters
- Signal Manager
- Validator
- Risk Manager
- Trade Manager
- Profit Protection Engine
- Position Manager
- Trade Lifecycle Tracker
- Diagnostics


Résultat :

Pipeline complet opérationnel :

Analyse marché
        ↓
Signal
        ↓
Validation
        ↓
Exécution
        ↓
Gestion position
        ↓
Protection profit
        ↓
Analyse statistique


---

# Sprint 1 - Intelligent Profit Protection & Trade Supervision 🔄

Statut : En cours

Ancien nom :
Sprint 2

Objectif :

Transformer la gestion des positions ouvertes.

Le système actuel prend une décision principalement au début d'une bougie H1.

Le problème :

Le marché évolue pendant la durée du trade.

Une décision correcte à l'entrée peut devenir incorrecte plusieurs heures après.


## Objectifs Sprint 1


### 1. Trade Supervision Engine

Créer une couche de surveillance permanente des positions ouvertes.

Le moteur doit analyser :

- structure actuelle ;
- volatilité ;
- ATR ;
- momentum ;
- nouveaux swings ;
- invalidation du scénario.


---

### 2. Recalcul dynamique du contexte

Le contexte ne doit plus être uniquement évalué à l'entrée.

Le système doit pouvoir détecter :

- continuation de tendance ;
- retracement normal ;
- changement de structure ;
- perte de validité du setup.


---

### 3. Stop Loss dynamique intelligent

Le Stop Loss doit évoluer selon le comportement du marché.

Objectif :

Ne pas sortir trop tôt d'un mouvement fort.

Prendre en compte :

- BOS ;
- CHOCH ;
- swing highs/lows ;
- volatilité ;
- structure.


---

### 4. Amélioration Profit Protection Engine

Les mécanismes existants :

- BreakEven
- Trailing
- ProfitGuard Structure
- ProfitGuard PeakPercent
- Emergency Protection

doivent être améliorés pour :

- éviter les protections trop rapides ;
- éviter les SL irréalistes ;
- privilégier les niveaux basés sur le prix réel.


---

### 5. Protection contre les gaps et reprises de marché

Ajouter une gestion spécifique :

- ouverture après pause quotidienne ;
- gap important ;
- absence de ticks ;
- reprise de session.


---

### 6. Cohérence Backtest / Live

Analyser les différences entre :

- simulation Strategy Tester ;
- comportement réel broker.

Vérifier :

- fréquence OnTick ;
- modifications SL ;
- spread ;
- exécution.


---

# Sprint 2 - Advanced Market Intelligence

Statut : Prévu

Objectifs :

- amélioration du scoring ;
- analyse multi-timeframe ;
- meilleure détection liquidité ;
- confluence institutionnelle.


---

# Sprint 3 - Adaptive Learning System

Statut : Prévu

Objectifs :

- statistiques avancées ;
- analyse automatique des erreurs ;
- optimisation basée données.


---

# Règle de développement

Chaque sprint doit :

1. être testé séparément ;
2. conserver la stabilité des modules existants ;
3. ajouter des diagnostics avant toute modification automatique ;
4. être validé par backtest puis observation live.

