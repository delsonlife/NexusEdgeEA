# NexusEdgeEA V3 — Architecture du moteur de décision
### Document de conception — aucune ligne de code, aucun pseudo-code

---

## 1. Principe directeur unique

Toute l'architecture V3 découle d'une seule question, posée en continu :

> **« Le scénario de marché est-il toujours valide ? »**

Toute autre question (« quel SL est le plus protecteur », « dois-je entrer maintenant ») est subordonnée à celle-ci. Un module qui répond à une question différente de celle-ci n'a pas le droit de décider — il exécute.

---

## 2. Vue d'ensemble — les quatre couches et leur autorité respective

```
                          ┌─────────────────────────┐
                          │   HARD RISK GUARD        │  ← indépendant, prioritaire sur tout,
                          │   (jamais subordonné)     │     ne consulte jamais le scénario
                          └────────────┬─────────────┘
                                       │ peut interrompre n'importe quoi, à tout moment
                                       ▼
   ┌───────────────┐        ┌─────────────────────────┐        ┌───────────────────┐
   │ STRUCTURE      │──────▶│  TRADE SCENARIO ENGINE   │──────▶│  ACTION ENGINES     │
   │ ENGINE         │       │  (autorité UNIQUE de     │       │  (exécutants,        │
   │ (BOS/CHOCH/    │       │   décision)               │       │   aucune décision    │
   │  Sweep/OB/FVG/ │       │                           │       │   autonome)          │
   │  HTF Bias)     │       └────────────┬──────────────┘       └──────────┬─────────┘
   └───────────────┘                    │                                  │
   ┌───────────────┐                    │ verdict + décision               │ ordre d'exécution
   │ CONFIRMATION   │────────────────────┘                                  ▼
   │ (EMA/RSI/      │                                              ┌───────────────────┐
   │  Momentum)     │                                              │  TradeManager       │
   └───────────────┘                                              │  (inchangé)          │
                                                                    └───────────────────┘
                          ┌─────────────────────────┐
                          │   LEARNING ENGINE         │  ← observe uniquement,
                          │   (découplé, différé)     │     ne décide jamais en direct
                          └─────────────────────────┘
```

Cinq familles de modules, cinq niveaux d'autorité différents. C'est la hiérarchie, pas la liste des modules, qui constitue la vraie nouveauté architecturale.

---

## 3. Les modules, un par un

### 3.1 Structure Engine — le nouveau cœur informationnel

**Rôle** : produire, en continu, l'état structurel du marché — pas une décision, une observation qualifiée.

**Composants** :
- **MarketStructure** (existant, réutilisé tel quel) — BOS, CHOCH, Sweep. Déjà conçu comme observateur pur, déjà fiable.
- **Order Block Detector** (nouveau) — identifie la zone d'origine d'un mouvement impulsif validé par un BOS.
- **Fair Value Gap Detector** (nouveau) — identifie les déséquilibres laissés par un mouvement impulsif.
- **HTF Bias** (nouveau, mais s'appuie sur une brique déjà existante et inutilisée — `CMarketContext`/`CIndicators` réinstanciés sur le timeframe supérieur déjà prévu en configuration).

**Ce qui ne change pas** : la philosophie « observateur pur ». Aucun de ces modules ne doit jamais avoir la capacité de modifier une position, un filtre ou un signal directement. Ils exposent un état, rien de plus.

### 3.2 Confirmation Layer — les indicateurs, rétrogradés

**Rôle** : EMA, RSI, Momentum (et le scoring actuel de `SignalManager`) ne disparaissent pas — ils changent de rôle. Ils cessent d'être le moteur principal de la décision et deviennent une **entrée parmi d'autres** consultée par le Trade Scenario Engine, au même titre que la structure, mais avec un poids subordonné.

### 3.3 Trade Scenario Engine (TSE) — l'autorité unique

**Rôle** : la seule instance du système qui a le droit de répondre à la question centrale. Il consomme la Structure Engine + la Confirmation Layer + l'état courant de la position (si un trade est déjà ouvert), et produit **deux choses distinctes** :

1. **Un verdict** — l'état du scénario : `SCENARIO_VALID`, `SCENARIO_STRENGTHENED`, `SCENARIO_WEAKENED`, `SCENARIO_INVALIDATED`, accompagné d'un niveau de confiance (anticipation déjà actée précédemment) et d'une raison exacte.
2. **Une décision** — l'action à entreprendre en conséquence : ne rien faire, resserrer jusqu'à un niveau donné, prendre partiellement les profits, sortir, autoriser une entrée, etc.

Le TSE fonctionne aussi bien pour la décision d'entrée que pour la gestion d'une position déjà ouverte — **c'est le même moteur, pas deux moteurs séparés**, seule la nature de la décision produite change (entrer/ne pas entrer d'un côté, ajuster/sortir de l'autre). C'est cette unification qui répond directement à la demande de traiter entrée et gestion comme un seul scénario continu.

**Ce que le TSE ne fait jamais** : il ne place jamais lui-même un ordre, ne modifie jamais lui-même un SL. Il décide, il ne touche pas au broker.

### 3.4 Action Engines — les calculateurs actuels, rétrogradés

**Rôle** : BreakEven, Trailing, Structure Protection, Peak Protection, Emergency, et une nouvelle **Partial Exit**. Ce sont des outils spécialisés, appelés explicitement par le TSE quand il a déjà décidé qu'une action de ce type est nécessaire — ils ne se mettent plus en concurrence entre eux, ils ne comparent plus qui est « le plus protecteur ». Chacun sait *comment* exécuter une action ; aucun ne sait plus *si* elle doit avoir lieu.

**Repositionnement notable** : Peak Protection, qui était le mécanisme le plus actif du système actuel, devient un outil de dernier recours — invoqué par le TSE uniquement dans les cas où aucune information structurelle n'est disponible pour justifier une décision plus fine.

### 3.5 Hard Risk Guard — la couche qui ne fait confiance à personne

**Rôle** : le seul module dont l'existence est justifiée précisément par l'hypothèse que le TSE peut se tromper. Il ne consulte jamais le verdict du scénario, ne connaît même pas son existence. Il agit uniquement sur des faits de compte bruts (perte quotidienne, perte consécutive, drawdown global) déjà en grande partie présents aujourd'hui dans le projet, mais dispersés — ce sprint les consolide en une couche unique, explicitement documentée comme non subordonnée.

### 3.6 Learning Engine — le seul module autorisé à être lent

**Rôle** : observe l'historique des décisions et des résultats (la source de vérité déjà exigée pour `TradeEvents.csv`/`TradeFull.csv`), détecte des régularités, et renvoie de la connaissance au TSE **entre les sessions, jamais en direct pendant un trade en cours**. Le découplage temporel n'est pas un détail technique — c'est la garantie qu'un apprentissage encore incertain ne peut jamais perturber une décision en temps réel.

---

## 4. Interfaces entre les modules — les contrats, pas le code

| De | Vers | Ce qui transite |
|---|---|---|
| Structure Engine | Trade Scenario Engine | État structurel qualifié (biais, dernier événement BOS/CHOCH/Sweep, zones OB/FVG actives, biais HTF) |
| Confirmation Layer | Trade Scenario Engine | Score de confirmation (ce qui existe déjà), jamais un verdict propre |
| Trade Scenario Engine | Action Engines | Une décision explicite typée (pas un simple prix) — l'outil à utiliser et le résultat attendu, jamais le calcul lui-même |
| Action Engines | TradeManager | Un ordre d'exécution concret (inchangé par rapport à aujourd'hui) |
| Hard Risk Guard | TradeManager | Un ordre de clôture, directement, sans passer par le TSE |
| Position / historique | Learning Engine | Lecture seule de la source de vérité persistée |
| Learning Engine | Trade Scenario Engine | Connaissance agrégée, livrée en différé, jamais en flux temps réel |

Le principe commun à toutes ces flèches : **plus l'information remonte vers l'autorité de décision, plus elle est qualifiée ; plus elle redescend vers l'exécution, plus elle est concrète.** Aucune flèche ne remonte d'un Action Engine vers le TSE — un outil ne renseigne jamais la décision, il ne fait que l'exécuter.

---

## 5. Entrées — l'architecture à deux vitesses

- **Vitesse lente (contexte)** : recalculée à chaque nouvelle bougie H1, comme aujourd'hui — biais HTF, tendance H1, régime de volatilité, session, cartographie des zones de liquidité. Rien ici ne doit devenir event-driven ; le recalculer plus souvent n'ajouterait aucune information.
- **Vitesse rapide (événements)** : surveillance continue, mais ciblée, de trois transitions précises produites par la Structure Engine — un sweep vient de se produire, un CHOCH ou un BOS vient d'être confirmé, le prix vient d'entrer dans une zone déjà cartographiée. Chaque transition déclenche une interrogation ciblée du TSE, pas un recalcul complet du système.

Une entrée intra-bougie n'a lieu que si les deux vitesses s'accordent : le contexte lent reste favorable **et** la chaîne d'événements rapides se complète. C'est le mécanisme qui répond directement à l'exemple donné (sweep à 20h18, CHOCH à 20h22, BOS à 20h27 — le système ne doit plus attendre 21h00 pour recalculer ce qu'il a déjà les moyens de détecter en continu).

---

## 6. Dépendances — ce qui existe déjà et ce qui doit être construit

**Déjà présent, réutilisable sans modification** : `CMarketStructure`, `CMarketContext`, `CIndicators`, `CTradeManager` (y compris la connaissance des contraintes broker déjà construite), les cinq calculateurs actuels du Profit Protection Engine (deviennent les Action Engines), la logique de disjoncteur journalier déjà présente dans `NexusEdgeEA.mq5`.

**Bloquant, à réactiver avant que le Learning Engine ait un sens** : le chantier de persistance de `CTradeLifecycleTracker` / `TradeEvents.csv` comme source de vérité définitive, mis en pause plus tôt. Le Learning Engine ne peut observer que ce qui est fidèlement enregistré — sans cette fondation, il apprendrait sur des données potentiellement incomplètes, exactement le problème déjà diagnostiqué sur le trade du 23-24 juillet.

**Entièrement nouveau** : Order Block Detector, Fair Value Gap Detector, Trade Scenario Engine, Hard Risk Guard (en tant que couche consolidée), Partial Exit (Action Engine), Learning Engine.

---

## 7. Ordre d'implémentation — sprint par sprint

### Règle transversale, valable pour TOUS les sprints sans exception

**Aucun sprint ne supprime ou ne désactive un comportement existant tant que le nouveau comportement n'a pas fonctionné en parallèle et été validé — à la fois en backtest et en observation réelle.** Ce n'est pas une précaution ponctuelle réservée aux transferts d'autorité vers le Trade Scenario Engine (V3.5 pour l'entrée, V3.7 pour la gestion de position, ci-dessous) — c'est la règle de fonctionnement de toute la refonte. Chaque nouveau module s'installe d'abord **à côté** du système actuel, en mode silencieux ou en simple journalisation, jamais en remplacement immédiat. Le système actuel (calculateurs concurrents, scoring H1 seul) continue de piloter réellement les décisions jusqu'à ce que son remplaçant ait fait ses preuves sur des données suffisantes — la même discipline que celle déjà appliquée à chaque correctif de ce projet depuis le début (implémentation → compilation → backtest → observation réelle → validation → étape suivante), simplement étendue à l'échelle de toute la refonte.

La séquence ci-dessous applique cette règle à chaque étape.

| Sprint | Contenu | Pourquoi à cette place |
|---|---|---|
| **V3.0** | Mise en place du squelette architectural — création des contrats/interfaces entre les futures couches (verdict de scénario, structure de décision, structure d'ordre d'exécution), et des coquilles vides ou en mode passif pour le Trade Scenario Engine, les Action Engines (enveloppe autour des calculateurs actuels, sans changer leur comportement), le Hard Risk Guard et le Learning Engine. **Aucun changement de logique métier** : le système continue de se comporter exactement comme aujourd'hui, les nouvelles structures existent mais ne pilotent rien. Objectif unique : que tout compile, que rien ne casse, et que les sprints suivants n'aient plus qu'à remplir des coquilles déjà en place plutôt qu'à improviser leur intégration au fil de l'eau | Sépare explicitement « poser l'architecture » de « changer le comportement » — le risque de régression de ce sprint est nul par construction, puisque rien de décisionnel n'y change |
| **V3.1** | Exposer l'état de `CMarketStructure` côté entrée (lecture seule) + câbler le biais HTF déjà prévu en configuration mais jamais utilisé — alimente les coquilles posées en V3.0, en mode journalisation uniquement, sans encore influencer aucune décision | Premier remplissage réel, mais toujours sans effet sur le comportement — seulement de la donnée qui commence à circuler dans le nouveau squelette |
| **V3.2** | Order Block Detector + Fair Value Gap Detector, construits sur le même patron « observateur pur » que MarketStructure | Nouveaux détecteurs, mais isolés — validables seuls avant toute connexion |
| **V3.3** | Trade Scenario Engine, côté ENTRÉE uniquement (décision binaire : entrer ou pas) + mécanisme événementiel intra-bougie — déployé d'abord **en parallèle** du pipeline d'entrée actuel : le TSE calcule et journalise sa décision sans encore autoriser ou bloquer une ouverture réelle | La première fois que le TSE existe, volontairement limité à la décision la plus simple, et non encore autorisé à agir — comparaison directe avec les entrées réellement prises par le système actuel avant tout transfert d'autorité |
| **V3.4** | Hard Risk Guard, consolidation de ce qui existe déjà en une couche explicite et indépendante | Ne dépend d'aucun nouveau concept — peut être livré en parallèle des autres sprints, sans remplacer les garde-fous actuels tant qu'il n'a pas démontré une couverture au moins équivalente |
| **V3.5** | Le TSE, validé côté entrée en V3.3, reçoit l'autorité réelle d'autoriser ou bloquer une ouverture — **uniquement après comparaison satisfaisante avec le comportement historique du système actuel sur backtest et en observation réelle** | Premier vrai transfert d'autorité de tout le projet V3, volontairement isolé à la décision d'entrée, la plus simple à valider (pas encore de position ouverte en jeu) |
| **V3.6** | Extension du TSE à la gestion de position, déployée d'abord **en observation seule** (il calcule et journalise sa décision sans encore piloter le SL réel), en parallèle des cinq calculateurs actuels qui continuent de fonctionner sans changement | Étape de validation avant transfert d'autorité — comparaison directe avec le comportement actuel sur des trades réels avant de lui faire confiance |
| **V3.7** | Transformation des calculateurs actuels en Action Engines subordonnés au TSE (fin de `IsMoreProtective`, fin de la concurrence entre calculateurs) — **uniquement après que V3.6 ait démontré, sur des données suffisantes, un comportement au moins aussi bon que le système actuel** | Le sprint le plus délicat pour la non-régression — placé après une phase d'observation complète, jamais en aveugle, et seul sprint de toute la séquence qui retire réellement un comportement existant |
| **V3.8** | Learning Engine | Nécessite une source de vérité fiable (dépendance du chantier de persistance à réactiver au préalable) et des décisions déjà structurées à observer |

Chaque sprint produit un système **immédiatement compilable et testable**, cohérent avec l'existant — jamais une refonte en un seul bloc, conformément à ce qui est demandé. Sur les neuf sprints (V3.0 à V3.8), **seuls V3.5 et V3.7 changent réellement un comportement décisionnel déjà en production** — respectivement le pilotage des entrées et le pilotage de la gestion de position — et chacun ne le fait qu'après une phase de fonctionnement en parallèle déjà validée. Tous les autres sprints ajoutent de la structure ou de l'observation, sans jamais toucher à ce qui pilote réellement le robot aujourd'hui.

---

## 8. Ce que cette architecture NE change PAS

- La philosophie « Live First » et la discipline de validation par les données réelles, déjà bien ancrée dans ce projet.
- Le fait que `CTradeManager` reste l'unique point de passage vers le broker.
- La séparation stricte entre logique de décision et exécution, déjà amorcée par le Profit Protection Engine actuel — la V3 la généralise, elle ne l'invente pas.
- Le principe de traçabilité complète de chaque décision, déjà exigé pour le sprint 1.

La V3 n'est donc pas une rupture totale avec ce qui a été construit jusqu'ici — c'est la généralisation, à l'ensemble du cycle de vie d'un trade, d'un principe que le projet avait déjà commencé à appliquer partiellement.
