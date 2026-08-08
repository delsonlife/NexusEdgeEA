# Module `Include/VirtualTrade/`

*Documentation — le code de ce dossier est verrouillé, ce fichier ne
modifie rien.*

---

## Rôle

Observe l'issue virtuelle (WIN/LOSS/TIMEOUT) d'un trade **jamais ouvert
réellement**, pour chaque candidat Opportunity dispatché au TSE — que le
verdict soit Authorized ou Refused. Permet de mesurer si le Pipeline B
apporte une valeur réelle avant de lui donner une autorité (P4).

## Fichiers et responsabilités

| Fichier | Responsabilité | Dépendances |
|---|---|---|
| `VirtualTradeTypes.mqh` | Types purs : `ENUM_VIRTUAL_TRADE_STATE`, `SVirtualTrade` | `../Opportunity/OpportunityTypes.mqh` (réutilise `ENUM_OPPORTUNITY_DIRECTION` uniquement — décision de revue : pas de 3ᵉ type de direction redondant) |
| `VirtualTradeTracker.mqh` | Détient la politique de timeout (bougies), applique le Worst Case Principle, calcule MFE/MAE incrémental, expose un rapport de synthèse | `VirtualTradeTypes.mqh` uniquement — **isolation totale du Trading Engine, invariant 16** |

Le pont vers le Trading Engine (`VirtualTradeFeed.mqh`, qui appelle
`CRiskManager`) vit délibérément **dans `Include/Opportunity/`**, pas ici
— voir `docs/modules/Opportunity.md`. `VirtualTrade/` ne connaît jamais
`CRiskManager`, `CTradeManager`, le TSE ou Opportunity.

## Principe architectural

**Invariant 16** : *"Le VirtualTradeTracker ne doit jamais réimplémenter
une logique métier déjà existante dans le Trading Engine. Il consomme les
décisions (prix d'entrée, SL, TP) produites par les composants existants
et se contente d'observer leur issue virtuelle."*

Concrètement : `CVirtualTradeTracker` ne calcule jamais lui-même un SL ou
un TP — il les reçoit déjà calculés (par `CRiskManager`, via
`VirtualTradeFeed`). Il ne lit jamais le marché lui-même — High/Low/
barIndex/score sont toujours reçus en paramètre (invariant 4, même
discipline que le TSE).

## Cycle de vie

```
OPEN ──┬──► WIN       (terminal, TP touché)
       ├──► LOSS      (terminal, SL touché, ou ambiguïté intra-bougie)
       └──► TIMEOUT   (terminal, âge max dépassé sans TP/SL)
```

Aucun retour en arrière. Un trade déjà clôturé (WIN/LOSS) ne peut jamais
être requalifié TIMEOUT — la clôture réelle prime toujours.

## Worst Case Principle

Si, dans une même bougie, le SL **et** le TP sont tous deux atteignables
(`High >= TP` et `Low <= SL` pour un BUY, inversé pour un SELL), le SL est
considéré touché **en premier** → `LOSS`.

**Vérifié avant d'être adopté** : aucune convention préexistante trouvée
dans `CPositionManager`, `CTradeLifecycleTracker` ou `CPostCloseWatcher` —
le problème n'existe que pour les trades virtuels (un trade réel a son
issue déterminée sans ambiguïté par le broker). Objectif de la règle :
sous-estimer plutôt que surestimer la performance du Pipeline B, pour que
toute comparaison future avec le Pipeline A soit conservatrice.

## Groupes de métriques (`SVirtualTrade`)

| Groupe | Champs | Statut |
|---|---|---|
| **A** | `exitReason`, `mfe`, `mae` | Alimenté dès Niveau 1 |
| **B** | `entryScore`, `exitScore`, `peakScoreAfterEntry` (= "MaximumScoreAfterEntry"), `lowestScoreAfterEntry`, `scoreEvolution[]` | Introduits et préparés en **P3.1bis** (`UpdateBar()` accepte déjà un `currentScore` optionnel). Restent **non alimentés en continu** tant que le Trade Scenario Engine reste statique (seul `entryScore` est rempli aujourd'hui, gratuitement, via `verdict.confidence` au moment du dispatch). **Leur alimentation deviendra effective à partir de P3.4**, lorsque le TSE sera recalculé dynamiquement pendant toute la durée du trade — voir `ARCHITECTURE_LOCK.md` §6/§7. *(Précision de conception uniquement : cette fonctionnalité n'est pas encore implémentée à ce jour.)* |
| **C** | `tradeHealthReserved`, `protectionRecommendationReserved` | **Réservé, non défini** — chaînes vides tant que ces concepts n'auront pas été spécifiés explicitement (probablement V4.2/V4.3). Aucun calcul fictif. |

## Tests

`Tests/TestVirtualTradeTracker.mq5` (32/32, isolé — bougies synthétiques,
aucune dépendance réelle). `VirtualTradeFeed.mqh` (le pont) n'est **pas**
testable en isolation, car il dépend de `CRiskManager` — sa validation se
fait uniquement à l'intégration réelle (voir `PROJECT_STATUS.md`).
