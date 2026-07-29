//+------------------------------------------------------------------+
//|                                                   V3Types.mqh      |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.0 - Contrats de l'architecture V3.                       |
//|                                                                    |
//| Ce fichier ne contient QUE des définitions de types (enum/struct) -|
//| aucune logique, aucun calcul, aucun accès au marché ou au broker.  |
//| C'est le contrat stable entre les futures couches (Structure       |
//| Engine, Trade Scenario Engine, Action Engines, Hard Risk Guard,    |
//| Learning Engine), au même titre que SSignalResult (Types.mqh) est  |
//| déjà le contrat stable entre CSignalManager et le reste du         |
//| système. Volontairement séparé de Types.mqh plutôt que d'y être    |
//| ajouté : ce fichier a vocation à rester la référence de            |
//| l'architecture V3 pendant toute la migration, sans se diluer dans  |
//| les structures déjà volumineuses du système actuel.                |
//|                                                                    |
//| RÈGLE D'OR DE LA V3 (rappel, voir ARCHITECTURE_V3.md) : aucune     |
//| nouvelle intelligence ne remplace une intelligence existante tant  |
//| qu'elle n'a pas démontré, objectivement, qu'elle est au moins      |
//| aussi performante - en backtest et en observation réelle.          |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef V3TYPES_MQH
#define V3TYPES_MQH

//+------------------------------------------------------------------+
//| ENUM_SCENARIO_STATUS                                                |
//|                                                                    |
//| L'état du scénario de marché tel que jugé par le Trade Scenario    |
//| Engine - la réponse à l'unique question qui pilote toute la V3 :   |
//| "le scénario est-il toujours valide ?". Anticipé et validé lors    |
//| de la conception du Trade Supervision Engine (Sprint 1), repris    |
//| ici tel quel comme fondation de la V3.                             |
//+------------------------------------------------------------------+
enum ENUM_SCENARIO_STATUS
  {
   SCENARIO_UNKNOWN       = 0, // Pas encore évalué, ou moteur désactivé (Feature Flag off)
   SCENARIO_VALID         = 1, // Le scénario tient toujours - respiration normale, ne rien faire
   SCENARIO_STRENGTHENED  = 2, // Le scénario se renforce (ex: nouveau BOS favorable, nouvelle prise de liquidité dans le bon sens)
   SCENARIO_WEAKENED      = 3, // Signal d'alerte, pas encore invalidant
   SCENARIO_INVALIDATED   = 4  // Le scénario qui justifiait le trade/l'entrée n'est plus vrai
  };

//+------------------------------------------------------------------+
//| ENUM_SCENARIO_ACTION                                                |
//|                                                                    |
//| L'action que le Trade Scenario Engine décide, en conséquence de    |
//| son verdict. C'est la sortie qui distingue ce modèle de            |
//| l'architecture actuelle : un PRIX de SL n'est plus la décision,    |
//| c'est une CONSÉQUENCE de l'action ci-dessous, calculée ensuite par |
//| l'Action Engine concerné (voir SScenarioDecision.targetLevel).     |
//+------------------------------------------------------------------+
enum ENUM_SCENARIO_ACTION
  {
   ACTION_NONE                    = 0, // Ne rien faire - respiration normale
   ACTION_ALLOW_ENTRY             = 1, // Autoriser l'ouverture d'une position (côté entrée)
   ACTION_BLOCK_ENTRY             = 2, // Bloquer l'ouverture malgré un score favorable par ailleurs
   ACTION_ARM_BREAKEVEN           = 3, // Déplacer le SL à l'équilibre (Action Engine: BreakEven)
   ACTION_TIGHTEN_TO_STRUCTURE    = 4, // Resserrer jusqu'au niveau structurel justifié (Action Engine: Structure Protection)
   ACTION_TIGHTEN_TRAILING        = 5, // Resserrer via trailing classique/ATR (Action Engine: Trailing)
   ACTION_TIGHTEN_SAFETY_FLOOR    = 6, // Filet de sécurité de dernier recours (Action Engine: Peak Protection, rôle réduit - voir ARCHITECTURE_V3.md §3.4)
   ACTION_PARTIAL_EXIT            = 7, // Prise de profit partielle (Action Engine: Partial Exit - à construire)
   ACTION_EXIT_NOW                = 8  // Sortie complète immédiate (Action Engine: Emergency, ou CHOCH contraire confirmé)
  };

//+------------------------------------------------------------------+
//| ENUM_STRUCTURE_DIRECTION (Sprint V3.2A)                              |
//|                                                                    |
//| Réservé aux NOUVEAUX champs directionnels de SScenarioContext       |
//| (Order Block, puis Fair Value Gap au Sprint V3.2B). Les champs      |
//| existants du Sprint V3.1 (bosDirection/chochDirection/              |
//| sweepDirection, en string) restent inchangés - cette structure est  |
//| verrouillée, on ne la retouche pas rétroactivement pour un simple   |
//| souci d'uniformité.                                                 |
//+------------------------------------------------------------------+
enum ENUM_STRUCTURE_DIRECTION
  {
   DIRECTION_NONE    = 0,
   DIRECTION_BULLISH = 1,
   DIRECTION_BEARISH = 2
  };

//+------------------------------------------------------------------+
//| SScenarioVerdict                                                    |
//|                                                                    |
//| Sortie n°1 du Trade Scenario Engine : l'évaluation qualifiée du     |
//| scénario, indépendamment de toute action. confidence est prévu     |
//| dès la conception (anticipation architecturale validée avant même  |
//| le début de la V3) pour ne jamais nécessiter de refonte du         |
//| contrat quand la logique de confiance sera implémentée (hors       |
//| périmètre du Sprint V3.0 - reste à 0.0 tant que le moteur réel     |
//| n'existe pas).                                                     |
//+------------------------------------------------------------------+
struct SScenarioVerdict
  {
   ENUM_SCENARIO_STATUS status;       // Non utilisé pour l'évaluation d'entrée (V3.5) - voir "authorized" ci-dessous. Réservé à EvaluateManagement (sprint ultérieur)
   double               confidence;   // Sprint V3.5 : échelle 0.0 à 1.0 (corrige la documentation initiale "0-100", jamais réellement exploitée avant ce sprint) - somme de 4 contributions de 25% (HTF/Structure/OrderBlock/FVG), score Shadow indépendant de "authorized"
   string               reason;       // Justification textuelle exacte, dans l'esprit "le robot doit toujours pouvoir s'expliquer"
   datetime             evaluatedAt;

   // --- Sprint V3.5 - verdict d'entrée réel (Shadow uniquement, aucune autorité) ---
   bool                 authorized;        // La réponse à "est-ce que j'autoriserais cette entrée" - porte ET stricte sur les 4 critères ci-dessous
   string               scenarioStrength;  // "STRONG" (confidence>=0.75) / "MEDIUM" (>=0.5) / "WEAK", dérivé directement de confidence, aucun seuil caché supplémentaire
   bool                 htfOk;             // Critère 1 : biais HTF aligné avec la direction candidate
   bool                 structureOk;       // Critère 2 : BOS OU CHOCH aligné avec la direction candidate (ajustement validé - pas BOS seul)
   bool                 orderBlockOk;      // Critère 3 : Order Block actif, valide, aligné
   bool                 fvgOk;             // Critère 4 : FVG actif, valide, aligné
  };

//+------------------------------------------------------------------+
//| SScenarioDecision                                                    |
//|                                                                    |
//| Sortie n°2 du Trade Scenario Engine : l'action à entreprendre en   |
//| conséquence du verdict. targetLevel/partialExitPercent ne sont     |
//| renseignés que si l'action concernée les utilise - laissés à 0.0   |
//| sinon (pas de convention "magique", chaque Action Engine sait ce   |
//| qu'il doit lire pour son propre type d'action).                    |
//+------------------------------------------------------------------+
struct SScenarioDecision
  {
   ENUM_SCENARIO_ACTION action;
   double               targetLevel;          // Prix cible, si applicable (ACTION_TIGHTEN_*)
   double               partialExitPercent;   // % à clôturer, si ACTION_PARTIAL_EXIT
   string               reason;
  };

//+------------------------------------------------------------------+
//| SScenarioContext (PLACEHOLDER - volontairement non implémenté)     |
//|                                                                    |
//| AJUSTEMENT POST-REVUE V3.0 : direction architecturale actée pour   |
//| éviter que CTradeScenarioEngine ne devienne un "God Object"        |
//| accumulant des pointeurs vers tous les modules du robot.           |
//|                                                                    |
//| Le TSE ne collecte JAMAIS lui-même les données de marché. Les      |
//| couches d'observation (Structure Engine, Confirmation Layer, et    |
//| plus tard Order Block/FVG/HTF Bias) construiront PROGRESSIVEMENT   |
//| cet objet, sprint après sprint - le TSE se contente de le          |
//| RECEVOIR (en paramètre d'une future évolution d'EvaluateEntry()/    |
//| EvaluateManagement()), de l'interpréter, et de produire un verdict |
//| + une décision. Jamais l'inverse.                                   |
//|                                                                    |
//| VOLONTAIREMENT LAISSÉ QUASI VIDE au Sprint V3.0 : lui donner sa     |
//| forme complète maintenant figerait un contrat avant que les        |
//| besoins réels des sprints V3.1 (biais HTF), V3.2 (Order Block/FVG) |
//| et V3.3 (score de confirmation) ne soient connus. Chaque sprint     |
//| qui ajoute une source d'observation ajoutera SES champs ici, sans  |
//| jamais avoir à toucher à la signature d'Init() ni des méthodes      |
//| Evaluate*() du TSE - c'est tout l'intérêt de ce contrat séparé.    |
//|                                                                    |
//| COMPLÉTÉ (Sprint V3.1) : premiers champs réels, remplis par la      |
//| nouvelle couche CStructureObserver (StructureObserver.mqh). Chaque |
//| champ correspond à une utilité future déjà identifiée pour le TSE  |
//| (Sprint V3.3+) - aucune donnée ajoutée "juste au cas où".           |
//|                                                                    |
//| DETTE TECHNIQUE DOCUMENTÉE (Sprint V3.1, acceptée explicitement) : |
//| bosDetected/chochDetected sont déduits en PARSANT le texte retourné|
//| par CMarketStructure::GetLastEventDescription() ("BOS_BULLISH",    |
//| "CHOCH_BEARISH"...) plutôt que de consommer un type structuré      |
//| dédié - CMarketStructure n'a volontairement pas été modifié ce      |
//| sprint (hors périmètre de V3.1). À migrer vers un contrat typé     |
//| (enum/struct exposé par CMarketStructure) dès qu'une évolution de  |
//| ce module sera au calendrier - prévu au plus tard au Sprint V3.2,  |
//| en même temps que l'ajout d'Order Block/FVG.                        |
//+------------------------------------------------------------------+
struct SScenarioContext
  {
   datetime capturedAt;       // Horodatage de construction du contexte

   // --- Structure de marché (Sprint V3.1 - CStructureObserver) ---
   // Utilité future : prérequis obligatoire (BOS) et véto absolu
   // (CHOCH contraire) déjà actés dans la chaîne de décision cible
   // (voir la mission d'architecture V3 - classement des événements).
   bool     bosDetected;      // Un BOS est-il l'événement structurel le plus récent connu ?
   string   bosDirection;     // "Bullish" / "Bearish" / "" si bosDetected=false
   bool     chochDetected;    // Un CHOCH est-il l'événement structurel le plus récent connu ?
   string   chochDirection;   // "Bullish" / "Bearish" / "" si chochDetected=false
   bool     sweepDetected;    // Un sweep de liquidité a-t-il eu lieu sur la bougie observée ?
   string   sweepDirection;   // "Support" / "Resistance" / "" si sweepDetected=false (vocabulaire de CMarketStructure::DetectSweep, non réinterprété)
   datetime structureEventTime; // Horodatage du dernier événement structurel observé (BOS/CHOCH/Sweep)

   // --- Order Block (Sprint V3.2A - COrderBlockDetector) ---
   // Le détecteur ne recalcule JAMAIS BOS/CHOCH - il consomme
   // exclusivement l'état déjà produit par CMarketStructure (voir
   // ARCHITECTURE_V3.md, précision Sprint V3.2A). orderBlockValid est
   // une CONSTATATION de marché (le prix a clôturé au-delà de la borne
   // opposée), jamais une décision - la séparation Observer → Décrire
   // → Décider reste strictement respectée ici aussi.
   ulong                    orderBlockId;         // Identifiant monotone, 0 = aucun Order Block jamais détecté
   bool                     orderBlockActive;      // Un Order Block a-t-il été identifié et est-il actuellement suivi ?
   bool                     orderBlockValid;       // Constatation de marché : n'a pas (encore) été franchi par une clôture - jamais mis à jour si orderBlockActive=false
   ENUM_STRUCTURE_DIRECTION orderBlockDirection;   // Sens de l'Order Block (DIRECTION_NONE si orderBlockActive=false)
   double                   orderBlockHigh;        // Borne haute de la zone
   double                   orderBlockLow;         // Borne basse de la zone
   datetime                 orderBlockCreatedAt;   // Horodatage de création de l'Order Block actuellement suivi

   // --- Fair Value Gap (Sprint V3.2B - CFVGDetector) ---
   // Contrairement à l'Order Block, le FVG est une propriété LOCALE des
   // prix (géométrie à 3 bougies) - CFVGDetector ne consulte JAMAIS
   // CMarketStructure, aucun couplage artificiel à un BOS/CHOCH.
   //
   // SIMPLIFICATION VOLONTAIRE, DOCUMENTÉE COMME TELLE (pas une
   // définition du concept) : un seul FVG est suivi à la fois - un
   // nouveau FVG détecté remplace le précédent dans ce contexte, même
   // si celui-ci n'était pas encore comblé. La gestion simultanée de
   // plusieurs FVG est reportée à une évolution ultérieure, si les
   // statistiques d'observation en démontrent le besoin.
   //
   // CONVENTION INTERNE AU PROJET, PAS UN CONSENSUS DE LA LITTÉRATURE
   // SMC (à ne jamais modifier "parce qu'une autre école SMC fait
   // différemment" sans une décision explicite et documentée) :
   // fvgValid devient false dès qu'une bougie CLÔTURE au-delà de la
   // borne opposée - comblement complet par clôture, pas un simple
   // contact (mitigation) ni un comblement partiel du corps.
   ulong                    fvgId;           // Identifiant monotone, 0 = aucun FVG jamais détecté
   bool                     fvgActive;        // Un FVG a-t-il été identifié et est-il actuellement suivi ?
   bool                     fvgValid;         // Constatation de marché : pas encore comblé (convention ci-dessus) - jamais mis à jour si fvgActive=false
   ENUM_STRUCTURE_DIRECTION fvgDirection;     // Sens du FVG (DIRECTION_NONE si fvgActive=false)
   double                   fvgHigh;          // Borne haute de la zone
   double                   fvgLow;           // Borne basse de la zone
   datetime                 fvgCreatedAt;     // Horodatage de création du FVG actuellement suivi
   double                   fvgFillRatio;     // RÉSERVÉ, non calculé au Sprint V3.2B (toujours 0.0) - champ posé dès maintenant pour que le Learning Engine (V3.8) puisse un jour distinguer un FVG comblé à 20% d'un FVG comblé à 95%, sans modification de structure ultérieure

   // --- Higher Timeframe Bias (Sprint V3.3 - CHTFBiasObserver) ---
   // Réutilise CMarketStructure telle quelle (Option A), reconfigurée
   // sur InpTF_High - même logique de swings/BOS/CHOCH déjà validée en
   // H1, une seule source de vérité pour le concept de "biais
   // structurel", pas une seconde implémentation.
   //
   // CADENCE, à respecter par tout sprint futur : le HTF Bias est
   // recalculé UNIQUEMENT lors de la clôture d'une nouvelle bougie
   // HTF (InpTF_High), puis reste inchangé jusqu'à la suivante - jamais
   // à chaque tick, jamais à chaque bougie H1.
   bool                     htfBiasAvailable;   // false tant que la première mise à jour du module HTF n'a pas eu lieu (démarrage, historique insuffisant) - distingue "pas encore de donnée" de "biais neutre" (DIRECTION_NONE avec htfBiasAvailable=true)
   ENUM_STRUCTURE_DIRECTION htfBiasDirection;   // Signification valide uniquement si htfBiasAvailable=true
   ENUM_TIMEFRAMES          htfBiasTimeframe;   // Unité de temps concernée (= InpTF_High), pour qu'aucun consommateur futur ne suppose "H4" en dur
   datetime                 htfBiasUpdatedAt;   // Horodatage de la dernière TRANSITION de direction, pas de la dernière lecture
  };

//+------------------------------------------------------------------+
//| Fonctions utilitaires de conversion texte (diagnostics/logs) -     |
//| même convention que CUtilities::SignalTypeToString etc. déjà       |
//| existant, pour rester cohérent avec le style du projet.            |
//+------------------------------------------------------------------+
string ScenarioStatusToString(const ENUM_SCENARIO_STATUS status)
  {
   switch(status)
     {
      case SCENARIO_VALID:        return("VALID");
      case SCENARIO_STRENGTHENED: return("STRENGTHENED");
      case SCENARIO_WEAKENED:     return("WEAKENED");
      case SCENARIO_INVALIDATED:  return("INVALIDATED");
      default:                    return("UNKNOWN");
     }
  }

string ScenarioActionToString(const ENUM_SCENARIO_ACTION action)
  {
   switch(action)
     {
      case ACTION_ALLOW_ENTRY:          return("ALLOW_ENTRY");
      case ACTION_BLOCK_ENTRY:          return("BLOCK_ENTRY");
      case ACTION_ARM_BREAKEVEN:        return("ARM_BREAKEVEN");
      case ACTION_TIGHTEN_TO_STRUCTURE: return("TIGHTEN_TO_STRUCTURE");
      case ACTION_TIGHTEN_TRAILING:     return("TIGHTEN_TRAILING");
      case ACTION_TIGHTEN_SAFETY_FLOOR: return("TIGHTEN_SAFETY_FLOOR");
      case ACTION_PARTIAL_EXIT:         return("PARTIAL_EXIT");
      case ACTION_EXIT_NOW:             return("EXIT_NOW");
      default:                          return("NONE");
     }
  }

string StructureDirectionToString(const ENUM_STRUCTURE_DIRECTION direction)
  {
   switch(direction)
     {
      case DIRECTION_BULLISH: return("Bullish");
      case DIRECTION_BEARISH: return("Bearish");
      default:                return("");
     }
  }

#endif // V3TYPES_MQH
//+------------------------------------------------------------------+