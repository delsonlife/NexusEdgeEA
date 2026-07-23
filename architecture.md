# NexusEdgeEA - Architecture

## Vue générale

NexusEdgeEA est un Expert Advisor MT5 développé pour trader principalement XAUUSD avec une approche basée sur :

- Smart Money Concepts (SMC)
- Price Action
- Liquidité
- Structure de marché
- Fair Value Gap (FVG)
- Order Blocks
- Gestion dynamique du risque
- Protection intelligente des profits


# Architecture globale

Le flux principal du système :

NexusEdgeEA.mq5
        |
        |
        ├── MarketContext
        |
        ├── MarketStructure
        |
        ├── Filters
        |
        ├── SignalManager
        |
        ├── Validator
        |
        ├── RiskManager
        |
        ├── TradeManager
        |
        ├── ProfitProtectionEngine
        |
        ├── PositionManager
        |
        ├── TradeLifecycleTracker
        |
        └── Diagnostics


# Description des modules


## NexusEdgeEA.mq5

Point d'entrée principal.

Responsabilités :

- Initialisation des modules
- Gestion OnInit()
- Gestion OnTick()
- Coordination globale


---

## MarketContext.mqh

Analyse du contexte actuel.

Analyse :

- tendance
- volatilité
- ATR
- régime de marché
- conditions générales


---

## MarketStructure.mqh

Analyse structurelle du marché.

Détecte :

- BOS (Break Of Structure)
- CHOCH (Change Of Character)
- swings
- tendance dominante


---

## Filters.mqh

Couche de filtrage avant recherche de signal.

Contrôle :

- sessions
- news
- volatilité
- drawdown
- conditions interdites


---

## SignalManager.mqh

Génération des signaux.

Responsabilités :

- calcul du score
- comparaison Bull/Bear
- validation BUY/SELL/NONE

Le score est actuellement principalement calculé au début des bougies H1.


---

## Validator.mqh

Dernière sécurité avant ouverture.

Contrôle :

- nombre de positions
- conditions de risque
- marge disponible
- distance SL/TP


---

## RiskManager.mqh

Gestion du risque.

Responsabilités :

- calcul du lot
- exposition
- risque par trade


---

## TradeManager.mqh

Gestion des ordres.

Responsabilités :

- ouverture
- modification SL
- modification TP
- communication broker


---

## ProfitProtectionEngine.mqh

Module critique.

Responsabilité :

Protection des gains.

Mécanismes :

- BreakEven
- Trailing classique
- ProfitGuard Structure
- ProfitGuard PeakPercent
- Emergency Protection


Objectif futur :

Protection dynamique basée sur :

- structure marché
- volatilité
- nouveaux swings
- continuation de tendance


---

## PositionManager.mqh

Gestion des positions ouvertes.

Responsabilités :

- suivi temps réel
- état des trades
- supervision


---

## TradeLifecycleTracker.mqh

Analyse complète de la vie d'un trade.

Mesures :

- MFE
- MAE
- durée en gain
- durée en perte
- drawdown maximal
- comportement avant clôture


---

## Diagnostics.mqh

Système d'analyse.

Produit :

- rapports backtest
- statistiques
- raisons des refus
- efficacité des protections


# Philosophie de développement

Chaque modification doit respecter :

1. Ne pas casser les modules existants.
2. Ajouter des diagnostics avant toute modification automatique.
3. Utiliser les données live pour améliorer le système.
4. Privilégier les décisions basées sur la structure du marché.


# Prochaines évolutions prévues

- Trade Supervision Engine
- recalcul dynamique du contexte pendant un trade
- protection contre gaps d'ouverture
- gestion intelligente des retracements
- adaptation dynamique du Stop Loss
