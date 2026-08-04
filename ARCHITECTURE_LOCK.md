# NexusEdgeEA — ARCHITECTURE_LOCK.md

**Statut : V4 verrouillée.** Ce document est la vérité officielle de l'architecture.
Tout modèle (Claude, ChatGPT ou autre) reprenant ce projet doit lire CE document
en premier, avant tout fichier source. La cartographie détaillée complète
(diagrammes, responsabilités module par module) reste disponible dans
`NexusEdgeEA_Cartographie_V4_Finale.md` pour approfondissement — ce fichier-ci
est le résumé exécutable qui permet de coder un sprint sans tout relire.

---

## 1. Principe fondamental

Le cycle de vie d'un trade suit un flux **acyclique à sens unique** :

```
Marché → Observation (SMC) → Décision (TSE, shadow) → Signal (legacy)
       → Validation → Exécution → Suivi vivant → Clôture → Post-traitement
```

En parallèle, un flux **strictement passif** capture des événements pour la recherche :

```
Trading Engine → CObservationLayer → CResearchDataLayer → disque (JSONL)
```

---

## 2. Invariants — NE JAMAIS CASSER

1. Un seul point d'exécution broker : `CTradeManager` (seule classe important `<Trade/Trade.mqh>`).
2. `positionId` = ticket de l'ORDRE d'entrée, jamais le ticket du deal.
3. Analyse de signal uniquement à l'ouverture d'une nouvelle bougie `InpTF_Main` — jamais à chaque tick. La gestion de position (protection/trailing), elle, tourne à chaque tick.
4. Le TSE (et tout futur module de décision SMC) ne lit jamais lui-même le marché — reçoit tout en paramètre/valeur.
5. Décision unique par tick pour la protection de profit — un seul candidat retenu, un seul appel d'exécution.
6. Séparation stricte Calcul → Décision → Exécution, non contournable.
7. `CTradeLifecycleTracker` et `CPostCloseWatcher` sont des observateurs purs — ne modifient jamais une position, n'écrivent aucun fichier eux-mêmes.
8. Aucune donnée fabriquée — une valeur non calculable retourne un état neutre honnête documenté, jamais une estimation inventée.
9. Le disjoncteur de sécurité journalier reste piloté exclusivement par la logique legacy du `.mq5`.
10. Le TSE reste en shadow mode tant qu'aucune preuve statistique (`CShadowAnalytics`) n'a été produite — activation = décision humaine, jamais automatique.
11. Aucune conversion argent → prix pour calculer un niveau de protection (Peak/Emergency) — distance de prix mesurée directement sur le marché uniquement (corrigé ISSUE 001/002).
12. La Research Platform n'a et n'aura jamais d'autorité sur le Trading Engine.
13. **Aucun composant métier ne doit dépendre de la Research Platform** — on doit pouvoir supprimer intégralement `CObservationLayer`/`CResearchDataLayer` sans changer le comportement de trading.
14. `CResearchDataLayer` est une couche gelée — toute évolution de format est une décision explicite, jamais réactive.
15. **Un manager décide et détient l'état métier, mais ne mémorise jamais l'activité de ses consommateurs.** Être lu par un pipeline consommateur (TSE, Research, un futur Replay) n'est pas un changement d'état métier — c'est un échange entre composants. La mémoire de "ce qui a déjà été traité" appartient exclusivement au consommateur, jamais au manager qui expose la donnée. *(Verrouillé lors de la revue V4.1-P1 — voir `OpportunityManager.GetTriggeredCount()/GetTriggeredAt()`, volontairement idempotents, sans curseur de livraison à usage unique.)*
16. **Le `VirtualTradeTracker` ne doit jamais réimplémenter une logique métier déjà existante dans le Trading Engine.** Il consomme les décisions (prix d'entrée, SL, TP) déjà produites par les composants existants (`CRiskManager`, etc.) et se contente d'observer leur issue virtuelle. Cet invariant empêche la création d'un "deuxième robot" caché dans la partie Research. *(Verrouillé lors de la revue V4.1-P3.1bis.)*

---

## 3. Concepts clés — ne jamais confondre

| Concept | Nature | Généré par | Portée |
|---|---|---|---|
| `positionId` | Clé de corrélation métier | `CTradeManager.OpenPosition()` | Trade réellement ouvert |
| `opportunityId` | Clé de corrélation Research | `CObservationLayer.CaptureDecision()` | Toute décision TSE, même jamais tradée |
| `Opportunity` *(V4.1)* | **Objet métier**, indépendant des deux ci-dessus | `OpportunityManager` | Candidat structurel, avant toute décision TSE |

**Une même `Opportunity` peut produire plusieurs évaluations Research** (donc plusieurs `opportunityId`) — ne jamais fusionner ces concepts.

---

## 4. Position d'`OpportunityManager` dans le flux (cible V4.1)

```
Génération d'opportunités structurelles (SMC : BOS/CHOCH/OB/FVG/HTF)
            │
            ▼
    OpportunityManager   ← NOUVEAU, V4.1
            │
            ▼
    TSE (toujours shadow au démarrage de V4.1)
```

Principe conservé : **aucune latence artificielle** — la fenêtre d'évaluation reste le tick / la bougie, pas un délai construit.

---

## 5. Feuille de route V4.1 (phasage verrouillé)

| Phase | Contenu | Dépendances autorisées |
|---|---|---|
| **P1** | `OpportunityManager` isolé — types, cycle de vie, tests sur candidats synthétiques | **Aucune** (ni MarketStructure, ni SignalManager, ni TSE, ni TradeManager, ni Research) |
| **P1 Révision 1** | Migration `createdTime` (datetime) → `createdBarIndex` (int) ; ajout `creationReason`. Voir §5bis | Aucune (inchangé) |
| **P2A** | **Verrouillé, 48/48 tests passés.** Branchement `OrderBlockDetector`/`CFVGDetector` → `OpportunityManager` via un pont dédié. Aucun TSE — premier jalon où `OpportunityManager` est validé indépendamment du reste du moteur (référence pour diagnostic post-branchement) | `V3Types.mqh` (types purs uniquement, via le pont — voir §5bis) |
| **P2B** | **Verrouillé, 15/15 tests passés.** `OpportunityManager` → TSE (`EvaluateOpportunity`, shadow uniquement) — aucune ouverture de position | + TSE (lecture seule) |
| **P3** | **Verrouillé.** Intégration réelle `.mq5` (Shadow strict) — confirmé par backtest (13 trades identiques avec/sans patch, XAUUSD H1 fév. 2019) | Tout le Trading Engine, lecture seule |
| **P3.1** | Validation statistique **Pipeline A** — méthodologie pure, aucun nouveau code (backtests multi-années/multi-symboles, lecture des rapports `CStatistics`/`CShadowAnalytics` déjà existants) | Aucun (méthodologie, pas de code) |
| **P3.1bis** (en cours de spécification) | Construction du **`VirtualTradeTracker`** — observe l'issue virtuelle (WIN/LOSS/TIMEOUT) d'un trade jamais ouvert, à partir d'un entry/SL/TP déjà calculés par `CRiskManager`. Nécessaire car le Pipeline B ne produit aujourd'hui aucun résultat financier mesurable (voir invariant 16) | `CRiskManager` (consommation de ses sorties uniquement, jamais de recalcul) |
| **P3.2** | Comparaison chiffrée **Pipeline A vs Pipeline B** (PF, win rate, expectancy, drawdown, RR moyen) + analyse automatique des motifs de refus — possible seulement après P3.1bis | + `VirtualTradeTracker` |
| *Décision humaine* | Le passage à P4 est une décision humaine, jamais automatique (invariant 10) — conditionnée par les résultats de P3.2, pas par une intuition | — |
| **P4** | Connexion au Trading Engine réel — activation d'une autorité réelle pour le TSE via `OpportunityManager` | Tout le moteur |
| **V4.2** | `OpportunityManager` multi-opportunités — non entamé avant que P3.2 ait répondu à "le TSE actuel apporte-t-il une valeur mesurable avec une seule Opportunity à la fois ?" | À définir |

**Règle de passage entre phases : chaque phase doit être validée seule avant la suivante.**

---

## 5bis. Module Opportunity — état détaillé (mis à jour à chaque révision)

**Fichiers** (`Include/Opportunity/`) :
- `OpportunityTypes.mqh` — types purs, zéro dépendance Trading Engine.
- `OpportunityCandidate.mqh` — fabrique + règles de transition structurelles pures.
- `OpportunityManager.mqh` — détient toutes les politiques (expiration, déduplication, sélection). **Zéro dépendance Trading Engine, y compris pendant P2A.**
- `OpportunitySourceSMC.mqh` (P2A) — **seule** pièce du module qui dépend de `V3Types.mqh` (`SScenarioContext`). Pont producteur : lit `orderBlockId`/`fvgId` déjà produits par les détecteurs, ne recalcule jamais BOS/CHOCH/OB/FVG.

**Règles de mapping verrouillées (P2A)** :
- `COrderBlockDetector` → Opportunity : `sourceType="OrderBlock"`, `creationReason="BOS"` **strictement** (le détecteur ne crée jamais un OB sur CHOCH ou Sweep — vérifié dans le code, pas supposé).
- `CFVGDetector` → Opportunity : `sourceType="FVG"`, `creationReason="FVG"` **strictement** — aucune corrélation avec BOS/CHOCH/Sweep même si ces champs sont renseignés dans `SScenarioContext` au même instant (le FVG est une géométrie locale, indépendante de la structure — associer un événement structurel serait une causalité inventée).
- `CStructureObserver` et `CHTFBiasObserver` ne créent **jamais** d'Opportunity — ils décrivent un contexte, pas un objet de marché physique.

**`SOpportunityCandidate` (état courant des champs)** :
```
id, symbol, direction, createdBarIndex, state, sourceType, creationReason, zoneLow, zoneHigh
```
Volontairement absents : `expiresAt`, `dedupKey` (dérivés d'une politique, jamais stockés sur le candidat).

**Expiration** : `m_maxAgeBars` (int), `UpdateExpiration(currentBarIndex)` — `currentBarIndex` toujours injecté par l'orchestrateur, jamais lu via `Bars()`/`iBars()` en interne.

---

## 5ter. P2B — Pipeline Opportunity → TSE (Shadow)

**Fichiers ajoutés** :
- `Include/Opportunity/OpportunityPipeline.mqh` — `COpportunityPipeline`. Détient la mémoire "id déjà dispatché au TSE" (invariant 15 — cette mémoire n'appartient PAS à `COpportunityManager`, qui reste idempotent). Traduit `ENUM_OPPORTUNITY_DIRECTION → ENUM_SIGNAL_TYPE` (le TSE ne connaît rien du module Opportunity). Cadence : `ProcessTick()` doit être appelée à **chaque tick** (pas seulement à la nouvelle bougie H1) — un déclenchement intra-bougie ne doit jamais attendre 45 minutes.
- `Include/TradeScenarioEngine_Revision1.mqh` — **révision proposée** de `TradeScenarioEngine.mqh` (fichier de production déjà en vie, à fusionner manuellement). Extraction d'un cœur privé `ComputeVerdict()` (logique des 4 critères, inchangée), appelé par les deux pipelines shadow suivants :
  - **Pipeline A** (`EvaluateEntry`, inchangé dans son comportement observable) — alimenté par `CSignalManager`.
  - **Pipeline B** (`EvaluateOpportunity`, NOUVEAU) — alimenté par `OpportunityManager` via `COpportunityPipeline`. Compteurs statistiques et `GetOpportunityShadowReport()` totalement séparés du Pipeline A.
  - Les deux pipelines tournent en parallèle, mesurés indépendamment par leurs rapports respectifs, jusqu'à décision statistique de lequel garder (aucune autorité réelle donnée à l'un ou l'autre à ce stade).

**Cadence verrouillée (P2B)** :
| Opération | Cadence |
|---|---|
| `UpdateExpiration()` | Nouvelle bougie H1 uniquement |
| `EvaluatePrice()` | Chaque tick |
| `COpportunityPipeline.ProcessTick()` | Chaque tick |

**Objectif de traçabilité P2B** (démontré dans `Tests/TestOpportunityPipeline.mq5`) : pour chaque candidat dispatché, la séquence `Opportunity #<id> créée → déclenchée → envoyée au TSE → Verdict = ACCEPTED/REJECTED (raison)` doit être reconstituable de bout en bout, sans qu'aucun ordre réel ne soit ouvert.

**Hors périmètre P2B (rappel)** : aucune connexion au Trading Engine réel (`.mq5`), aucune ouverture de position, aucune propagation de l'invalidation OB/FVG vers `Reject()` (voir §5bis, hors périmètre P2A, toujours non traité).

---

## 5quater. P1 Révision 2 + P3 — Intégration réelle (Shadow)

**P1 Révision 2** : `OpportunityManager.EvaluatePrice(symbol, bid, ask)` — remplace l'ancienne signature à un seul prix. Le choix Ask (BUY) / Bid (SELL) est fait **à l'intérieur du manager**, jamais par l'orchestrateur (revue P3 : "le choix Bid/Ask fait partie de la logique métier de déclenchement, pas de l'orchestration"). Testé explicitement (`Test_EvaluatePrice_BidAskAsymmetry`).

**P3 — décision de cadence verrouillée** : un seul appel par tick à `EvaluatePrice()`/`ProcessTick()`, placé **avant** le gate `IsNewBar()` du `.mq5` (seul emplacement garanti à chaque tick). Conséquence assumée : une Opportunity créée sur la bougie en cours n'est visible par le pipeline qu'au tick **suivant** (délai d'un tick, jamais plus). Décision actée en revue P3 : *"une Opportunity représente une zone, pas un signal instantané — ce délai est sans conséquence fonctionnelle"*. Le double-appel (avant + après le gate) a été explicitement écarté au profit de la lisibilité ("une responsabilité = un appel = une cadence").

**Fichiers P3** : `P3_Integration_Patch.md` — patch d'intégration `.mq5`, à appliquer manuellement (includes, input `InpOpportunityMaxAgeBars`, globals, `OnInit`/`OnTick`/`OnDeinit`). Toujours Shadow strict : aucun appel du module Opportunity ne modifie une position ou un ordre.

---

## 5quinquies. P3.1bis — VirtualTradeTracker (Niveau 1 + API Niveau 2 préparée)

**P1 Révision 3** : `SOpportunityCandidate` gagne un champ `triggerPrice` (double), rempli par `EvaluatePrice()` au moment exact de la transition `CREATED → TRIGGERED` (ask pour BUY, bid pour SELL). Nécessaire pour que `VirtualTradeFeed` dispose du prix d'entrée réel sans avoir à le redéduire plus tard.

**Fichiers ajoutés** :
- `Include/VirtualTrade/VirtualTradeTypes.mqh` — `SVirtualTrade`, `ENUM_VIRTUAL_TRADE_STATE` (`OPEN → WIN | LOSS | TIMEOUT`, même discipline que le cycle de vie Opportunity). Réutilise `ENUM_OPPORTUNITY_DIRECTION` (décision de revue : pas de 3ᵉ type de direction redondant).
- `Include/VirtualTrade/VirtualTradeTracker.mqh` — `CVirtualTradeTracker`. **Isolé du Trading Engine** (invariant 16) : ne connaît ni `CRiskManager`, ni le TSE, ni Opportunity. Reçoit uniquement entry/SL/TP déjà calculés, et High/Low/barIndex à chaque bougie (jamais lus en interne, invariant 4).
- `Include/Opportunity/VirtualTradeFeed.mqh` — **seule** pièce qui connaît `CRiskManager`. Appelée pour **chaque** verdict TSE (Authorized *et* Refused). Calcule SL/TP via `CRiskManager` (jamais recalculé), transmet `verdict.confidence` comme `entryScore`.

**Groupes de métriques** (voir en-tête de `VirtualTradeTypes.mqh` pour le détail complet) :
- **Groupe A** (alimenté, Niveau 1) : `exitReason`, `mfe`, `mae`.
- **Groupe B** (API préparée dès Niveau 1, non alimentée tant que `VirtualTradeFeed` n'envoie pas de score) : `entryScore`, `exitScore`, `peakScoreAfterEntry` (= "MaximumScoreAfterEntry", fusion volontaire), `lowestScoreAfterEntry`, `scoreEvolution[]`. `UpdateBar()` accepte déjà un `currentScore` optionnel — aucune rupture d'API prévue quand ce groupe sera activé.
- **Groupe C** (réservé, **non défini**) : `tradeHealthReserved`, `protectionRecommendationReserved` — chaînes vides tant que ces concepts n'auront pas été spécifiés explicitement (probablement V4.2/V4.3). Aucun calcul fictif.

**Worst Case Principle** (vérifié : aucune convention préexistante dans `CPositionManager`/`CTradeLifecycleTracker`/`CPostCloseWatcher` — le problème est spécifique aux trades virtuels) : si SL et TP sont tous deux atteignables dans `[Low, High]` d'une même bougie, le SL est considéré touché en premier → `LOSS`. Objectif : sous-estimer plutôt que surestimer la performance du Pipeline B.

**Règle de priorité clôture > timeout** : un trade touché par SL/TP la bougie même où il aurait dépassé le timeout est compté WIN/LOSS, jamais TIMEOUT.

**Non testé en isolation (limite honnête)** : `VirtualTradeFeed` dépend de `CRiskManager`, qui a lui-même besoin de données de marché réelles — il ne peut donc pas être testé avec des candidats purement synthétiques comme le reste du module Opportunity. Sa validation se fera à l'intégration réelle (comme `OpportunitySourceSMC` en P3), pas avant.

---

## 6. Historique des sprints

| Sprint | Statut | Date de verrouillage |
|---|---|---|
| V3.0 → V3.9 (SMC/TSE/Research) | Verrouillé | *(antérieur à cette reprise)* |
| V4 (cartographie complète) | **Verrouillé** | Session de reprise en cours |
| V4.1-P1 (OpportunityManager isolé) | **Verrouillé** | Session de reprise en cours |
| V4.1-P1 Révision 1 (bougies + creationReason) | **Verrouillé** | Session de reprise en cours |
| V4.1-P2A (branchement SMC → OpportunityManager) | **Verrouillé** — 48/48 tests passés (`TestOpportunityManager.mq5`) | Session de reprise en cours |
| V4.1-P2B (OpportunityManager → TSE, shadow) | **Verrouillé** — 15/15 tests passés (`TestOpportunityPipeline.mq5`) | Session de reprise en cours |
| V4.1-P1 Révision 2 (EvaluatePrice reçoit bid/ask) | **Verrouillé** — 54/54 tests passés (`TestOpportunityManager.mq5`), 15/15 confirmés à nouveau (`TestOpportunityPipeline.mq5`) | Session de reprise en cours |
| V4.1-P3 (intégration `.mq5`, Shadow uniquement) | **Verrouillé** — 13 trades (10 WIN / 3 LOSS) strictement identiques avec/sans le patch (backtest XAUUSD H1, février 2019) ; logs `[OPPORTUNITY_CREATED]`/`[OPPORTUNITY_EXPIRED]` cohérents avec les détections SMC réelles ; Pipeline A (17 évaluations) et Pipeline B (60 évaluations) indépendants et sans collision | Session de reprise en cours |
| V4.1-P1 Révision 3 (`triggerPrice` sur `SOpportunityCandidate`) | **Verrouillé** — 57/57 tests passés (`TestOpportunityManager.mq5`), y compris la vérification explicite BUY→ask / SELL→bid | Session de reprise en cours |
| V4.1-P3.1bis (`VirtualTradeTracker` Niveau 1 + API Niveau 2) | **Verrouillé** — 32/32 tests passés (`TestVirtualTradeTracker.mq5`), couvrant enregistrement, WIN/LOSS, Worst Case Principle, timeout (avec priorité clôture-réelle), MFE/MAE incrémental, API Groupe B (alimentée et non alimentée), Groupe C réservé, non-régression d'état | Session de reprise en cours |

*À mettre à jour à chaque sprint validé.*
