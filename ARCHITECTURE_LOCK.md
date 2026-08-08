# NexusEdgeEA — ARCHITECTURE_LOCK.md

**Statut : V4.1-P3.1bis verrouillé.** Ce document est la vérité officielle
de l'architecture. Tout modèle (Claude, ChatGPT ou autre) reprenant ce
projet doit lire CE document en premier, avant tout fichier source.

---

## 1. Principe fondamental

Cycle de vie d'un trade **réel** (Pipeline A, en production) :

```
Marché → Observation (SMC) → Décision (TSE, shadow) → Signal (legacy)
       → Validation → Exécution → Suivi vivant → Clôture → Post-traitement
```

Cycle de vie d'une **Opportunity** (Pipeline B, en construction, shadow strict) :

```
Marché → Observation (SMC) → OpportunityManager → OpportunityPipeline
       → TradeScenarioEngine (EvaluateOpportunity) → VirtualTradeFeed
       → VirtualTradeTracker (résultat virtuel, AUCUN trade réel)
```

Flux **Research** (strictement passif) :

```
Trading Engine → CObservationLayer → CResearchDataLayer → disque (JSONL)
```

Les trois flux sont **indépendants** : le Pipeline B et la Research Platform
n'ont et n'auront jamais d'autorité sur le Pipeline A tant que P4 n'est pas
explicitement activé — ce qui exige désormais deux conditions cumulatives,
technique **et** statistique (voir invariant 17 et §6/§8).

---

## 2. Invariants — NE JAMAIS CASSER

1. Un seul point d'exécution broker : `CTradeManager` (seule classe important `<Trade/Trade.mqh>`).
2. `positionId` = ticket de l'ORDRE d'entrée, jamais le ticket du deal.
3. Analyse de signal uniquement à l'ouverture d'une nouvelle bougie `InpTF_Main` — jamais à chaque tick. La gestion de position (protection/trailing) tourne à chaque tick.
4. Le TSE (et tout module de décision SMC/Opportunity) ne lit jamais lui-même le marché — reçoit tout en paramètre/valeur.
5. Décision unique par tick pour la protection de profit — un seul candidat retenu, un seul appel d'exécution.
6. Séparation stricte Calcul → Décision → Exécution, non contournable.
7. `CTradeLifecycleTracker` et `CPostCloseWatcher` sont des observateurs purs — ne modifient jamais une position, n'écrivent aucun fichier eux-mêmes.
8. Aucune donnée fabriquée — une valeur non calculable retourne un état neutre honnête documenté, jamais une estimation inventée.
9. Le disjoncteur de sécurité journalier reste piloté exclusivement par la logique legacy du `.mq5`.
10. Le TSE reste en shadow mode tant qu'aucune preuve statistique n'a été produite — activation = décision humaine, jamais automatique.
11. Aucune conversion argent → prix pour calculer un niveau de protection (Peak/Emergency) — distance de prix mesurée directement sur le marché uniquement (corrigé ISSUE 001/002).
12. La Research Platform n'a et n'aura jamais d'autorité sur le Trading Engine.
13. Aucun composant métier ne doit dépendre de la Research Platform — on doit pouvoir supprimer `CObservationLayer`/`CResearchDataLayer` sans changer le comportement de trading.
14. `CResearchDataLayer` est une couche gelée — toute évolution de format est une décision explicite, jamais réactive.
15. Un manager décide et détient l'état métier, mais ne mémorise jamais l'activité de ses consommateurs (voir `OpportunityManager.GetTriggeredCount()/GetTriggeredAt()`, idempotents, sans curseur de livraison à usage unique).
16. Le `VirtualTradeTracker` ne réimplémente jamais une logique métier déjà existante — il consomme les décisions (entry/SL/TP) déjà produites par `CRiskManager` et observe leur issue virtuelle. Aucun "deuxième robot" caché dans la Research.
17. **`P4` (autorité réelle du TSE/Opportunity sur le trading) est INTERDIT tant que DEUX conditions cumulatives ne sont pas remplies** *(mise à jour post-P3.1bis — remplace l'ancienne condition statistique seule)* :
    1. **Validation technique complète** de la couche de gestion intelligente des positions (P3.3 à P3.6 — Trade Health Guardian, recalcul dynamique du TSE, entrées intra-bougie, gestion intelligente incluant la Défense Active).
    2. **Validation statistique** sur plusieurs périodes et plusieurs contextes de marché (P3.1/P3.2), pas un seul mois sur un seul symbole.

    Le passage à P4 reste une décision humaine, jamais une conséquence automatique d'un sprint terminé — même une fois ces deux conditions remplies.

---

## 3. Concepts clés — ne jamais confondre

| Concept | Nature | Généré par | Portée |
|---|---|---|---|
| `positionId` | Clé de corrélation métier | `CTradeManager.OpenPosition()` | Trade réellement ouvert |
| `opportunityId` | Clé de corrélation Research | `CObservationLayer.CaptureDecision()` | Toute décision TSE (Pipeline A), même jamais tradée |
| `Opportunity` (`SOpportunityCandidate.id`) | Objet métier Pipeline B | `OpportunityManager.RegisterCandidate()` | Candidat structurel (Order Block/FVG) |
| `VirtualTrade` (`SVirtualTrade.id`) | Résultat virtuel Pipeline B | `VirtualTradeFeed.OnVerdict()` | Une Opportunity dispatchée au TSE (Authorized OU Refused) |

Ces quatre identifiants sont **indépendants** — une Opportunity peut produire plusieurs évaluations Research, et chaque dispatch au TSE (accepté ou refusé) produit un `VirtualTrade` distinct.

---

## 4. Modules ajoutés (V4.1)

| Dossier | Rôle résumé | Documentation détaillée |
|---|---|---|
| `Include/Opportunity/` | Cycle de vie des candidats structurels (Order Block/FVG), dispatch shadow vers le TSE | `docs/modules/Opportunity.md` |
| `Include/VirtualTrade/` | Observation de l'issue virtuelle (WIN/LOSS/TIMEOUT) d'un trade jamais ouvert | `docs/modules/VirtualTrade.md` |

Fichiers du module `Opportunity/` : `OpportunityTypes.mqh`, `OpportunityCandidate.mqh`, `OpportunityManager.mqh`, `OpportunitySourceSMC.mqh`, `OpportunityPipeline.mqh`, `VirtualTradeFeed.mqh` (pont vers `VirtualTrade/`, seule pièce du dossier Opportunity à connaître `CRiskManager`).

Fichiers du module `VirtualTrade/` : `VirtualTradeTypes.mqh`, `VirtualTradeTracker.mqh` (isolation totale, invariant 16).

Révision associée à `TradeScenarioEngine.mqh` (fichier de production, hors `Opportunity/`/`VirtualTrade/`) : ajout de `EvaluateOpportunity()` et `GetOpportunityShadowReport()`, `EvaluateEntry()` comportementalement inchangé (cœur `ComputeVerdict()` partagé).

---

## 5. Révisions du module Opportunity (P1)

| Révision | Changement | Raison |
|---|---|---|
| **P1 Révision 1** | `createdTime` (datetime) → `createdBarIndex` (int) ; ajout `creationReason` | Le robot raisonne en bougies, jamais en secondes (week-ends, ralentis de marché) |
| **P1 Révision 2** | `EvaluatePrice(symbol, currentPrice)` → `EvaluatePrice(symbol, bid, ask)` | Le choix Ask(BUY)/Bid(SELL) est une logique métier du manager, pas de l'orchestrateur |
| **P1 Révision 3** | Ajout `triggerPrice` à `SOpportunityCandidate`, rempli par `EvaluatePrice()` | Nécessaire à `VirtualTradeFeed` pour calculer SL/TP via `CRiskManager` sans reconstruire le prix a posteriori |

---

## 6. Feuille de route V4

```
V4
│
├── Cartographie                    ✅ Verrouillé
│
├── V4.1-P1                         ✅ Verrouillé
│
├── P1 Revision 1                   ✅ Verrouillé
│
├── P1 Revision 2                   ✅ Verrouillé
│
├── P1 Revision 3                   ✅ Verrouillé
│
├── P2A                             ✅ Verrouillé
│
├── P2B                             ✅ Verrouillé
│
├── P3                              ✅ Verrouillé
│
├── P3.1                            ⬜ Non entamé (méthodologie pure, pas de code)
│
├── P3.1bis                         ✅ Verrouillé
│
├── P3.2                            ⬜ Non entamé — validation statistique
│
├── P3.3 — Trade Health Guardian    ⬜ Non entamé
│
├── P3.4 — Recalcul dynamique TSE   ⬜ Non entamé
│
├── P3.5 — Entrées intra-bougie     ⬜ Non entamé
│
├── P3.6 — Gestion intelligente     ⬜ Non entamé
│         des positions (4 modes,
│         dont Défense Active)
│
├── Décision humaine                🔒 Bloquée tant que P3.2 ET P3.3-P3.6 ne sont pas terminés
│
├── P4                              🚫 INTERDIT tant que les deux conditions cumulatives (invariant 17) ne sont pas remplies
│
└── V4.2                            ⬜ Non entamé (multi-opportunités)
```

### Détail des nouveaux sprints P3.3 à P3.6

*(Décidés après verrouillage de P3.1bis.)*

**Spécification fonctionnelle verrouillée** : voir
`P3.3_SPECIFICATION.md` (référence complète : cadences, Trade Health,
machine à états à 4 modes réversibles, comportement du SL, seuils non
fixés, réponse aux 2 problèmes de production identifiés). Aucun code
écrit à partir de cette spécification à ce stade.

**P3.3 — Trade Health Guardian**
Surveillance active d'un trade après son ouverture, à plusieurs cadences
(tick, quelques secondes, nouvelle bougie H1) — le robot surveille la
santé du trade au lieu d'attendre passivement le SL ou le TP.

**P3.4 — Recalcul dynamique du Trade Scenario Engine**
Le TSE ne reste plus figé au moment de l'entrée : recalcul périodique du
scénario, du score, de la structure, du HTF, de l'Order Block et du FVG
pendant toute la durée du trade. Ce recalcul devient la base des
décisions de gestion de position. *(C'est le sprint qui active enfin le
Groupe B du `VirtualTradeTracker` — `peakScoreAfterEntry`,
`lowestScoreAfterEntry`, `scoreEvolution[]` — préparé mais non alimenté
depuis P3.1bis.)*

**P3.5 — Entrées intra-bougie**
Le robot peut ouvrir une position au milieu d'une bougie H1 lorsqu'une
nouvelle structure valide apparaît et que le score dépasse le seuil.
L'entrée n'est plus limitée à l'ouverture d'une nouvelle bougie.

**P3.6 — Gestion intelligente des positions**
SL dynamique piloté par la qualité actuelle du scénario. Possibilité de
laisser davantage respirer un trade lorsque le scénario reste excellent ;
protection plus agressive lorsqu'il se dégrade. Introduction de quatre
modes de gestion :
- **Offensive**
- **Protection**
- **Neutre**
- **Défense Active** — détection des scénarios invalidés immédiatement
  après l'entrée (HTF cassé, Structure cassée, Order Block invalidé, FVG
  invalidé, ou score devenu inférieur au seuil) ; le robot peut alors
  rapprocher fortement le Stop Loss, voire fermer la position avant le SL
  initial. Objectif : réduire fortement les pertes lorsque le scénario
  d'entrée disparaît rapidement.

---

## 7. Statut actuel (détaillé par sprint)

| Sprint | Statut | Preuve |
|---|---|---|
| Cartographie V4 (Trading Engine + Research Platform) | ✅ Verrouillé | Revue complète du Trading Engine legacy + SMC/TSE V3 + Research Platform V3.9 |
| V4.1-P1 (`OpportunityManager` isolé) | ✅ Verrouillé | Conception validée, aucune dépendance Trading Engine |
| P1 Révision 1 (bougies + `creationReason`) | ✅ Verrouillé | Intégré dans P1 |
| P2A (branchement SMC → `OpportunityManager`) | ✅ Verrouillé | 48/48 tests (`TestOpportunityManager.mq5`) |
| P2B (`OpportunityManager` → TSE, shadow) | ✅ Verrouillé | 15/15 tests (`TestOpportunityPipeline.mq5`) |
| P1 Révision 2 (bid/ask) | ✅ Verrouillé | 54/54 + 15/15 tests confirmés après révision |
| **P3** (intégration `.mq5` réelle, Shadow strict) | ✅ **Verrouillé** | 13 trades (10 WIN/3 LOSS) strictement identiques avec/sans patch, backtest XAUUSD H1 fév. 2019 |
| P1 Révision 3 (`triggerPrice`) | ✅ Verrouillé | 57/57 tests (`TestOpportunityManager.mq5`) |
| **P3.1bis** (`VirtualTradeTracker` + `VirtualTradeFeed`) | ✅ **Verrouillé** | 32/32 tests isolés (`TestVirtualTradeTracker.mq5`) + intégration réelle confirmée (trades réels inchangés, `[VIRTUAL_TRADE_REGISTERED]` cohérents, rapport final cohérent avec Pipeline B — voir `PROJECT_STATUS.md`) |
| P3.1 | ⬜ Non entamé | Validation statistique Pipeline A seule (méthodologie, backtests multi-années/symboles) |
| **P3.2** | ⬜ Non entamé | Comparaison chiffrée Pipeline A vs Pipeline B (PF, win rate, expectancy, drawdown, RR moyen) + analyse des motifs de refus — condition statistique de P4 |
| P3.3 (Trade Health Guardian) | ⬜ Non entamé | Surveillance active multi-cadences du trade après ouverture |
| P3.4 (Recalcul dynamique TSE) | ⬜ Non entamé | Réévaluation périodique du scénario pendant toute la durée du trade — active le Groupe B du `VirtualTradeTracker` |
| P3.5 (Entrées intra-bougie) | ⬜ Non entamé | Ouverture possible en dehors de la cadence "nouvelle bougie H1" |
| P3.6 (Gestion intelligente, 4 modes) | ⬜ Non entamé | SL dynamique, modes Offensive/Protection/Neutre/Défense Active — condition technique de P4 |

**Règle de passage entre phases : chaque phase doit être validée seule avant la suivante.**
**Rappel invariant 17 : P4 reste interdit tant que P3.2 (condition statistique) ET P3.3-P3.6 (condition technique) ne sont pas TOUTES DEUX terminées.**

---

## 8. Prochaine étape

**P3.2** en premier (comparaison chiffrée Pipeline A vs Pipeline B — voir
`PROJECT_STATUS.md` pour les derniers chiffres disponibles), P3.1 pouvant
être mené en parallèle sans code nouveau.

P3.3 à P3.6 (Trade Health Guardian, recalcul dynamique du TSE, entrées
intra-bougie, gestion intelligente des positions) suivront — leur
spécification détaillée n'a pas encore été produite à ce stade, seule la
feuille de route est actée.

**P4 ne sera envisagé qu'une fois les deux conditions cumulatives de
l'invariant 17 remplies** — jamais sur la base d'un seul des deux axes.

*Fin du document.*
