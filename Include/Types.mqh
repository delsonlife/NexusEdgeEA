//+------------------------------------------------------------------+
//|                                                      Types.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Couche de types purs du projet.                     |
//|   Contient TOUS les enums, structs et constantes globales.        |
//|   Ne contient aucun input, aucune logique, aucune fonction        |
//|   métier. Ce fichier est la base incluse par tous les autres      |
//|   modules (y compris Config.mqh).                                 |
//|                                                                    |
//| MODIFIÉ (Phase 1 - Instrumentation) : ajout des types nécessaires |
//|   au laboratoire d'analyse (TradeLifecycleTracker, PostCloseWatcher,|
//|   Debug). AUCUN type existant n'a été supprimé ni modifié dans   |
//|   son sens - uniquement des AJOUTS et un champ complémentaire     |
//|   dans STradeSnapshot (positionId, pour la corrélation entre      |
//|   tous les fichiers de sortie).                                   |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef TYPES_MQH
#define TYPES_MQH

//+------------------------------------------------------------------+
//| Constantes globales                                                |
//+------------------------------------------------------------------+
#define EA_NAME     "NexusEdgeEA"
#define EA_VERSION  "1.0.0"

//+------------------------------------------------------------------+
//| ENUMS - Contexte marché                                            |
//+------------------------------------------------------------------+

// État de tendance déterminé par l'analyse multi-timeframe
enum ENUM_TREND_STATE
  {
   TREND_BULLISH       = 0, // Tendance haussière
   TREND_BEARISH       = 1, // Tendance baissière
   TREND_RANGE         = 2, // Range / marché latéral
   TREND_TRANSITION    = 3, // Phase de transition
   TREND_CONSOLIDATION = 4  // Consolidation
  };

// Régime de volatilité (utilisé par MarketContext et les filtres)
enum ENUM_VOLATILITY_STATE
  {
   VOLATILITY_TOO_LOW  = 0, // Volatilité trop faible pour trader
   VOLATILITY_NORMAL   = 1, // Volatilité normale
   VOLATILITY_TOO_HIGH = 2  // Volatilité trop élevée pour trader
  };

// Phase de marché façon Wyckoff (best-effort, heuristique)
enum ENUM_WYCKOFF_PHASE
  {
   WYCKOFF_UNDEFINED    = 0, // Phase indéterminée
   WYCKOFF_ACCUMULATION = 1, // Accumulation
   WYCKOFF_MARKUP       = 2, // Markup (hausse)
   WYCKOFF_DISTRIBUTION = 3, // Distribution
   WYCKOFF_MARKDOWN     = 4  // Markdown (baisse)
  };

// État de compression / expansion du marché (utile pour breakouts)
enum ENUM_COMPRESSION_STATE
  {
   COMPRESSION_NONE      = 0, // Pas de compression particulière
   COMPRESSION_BUILDING  = 1, // Compression en cours de formation
   COMPRESSION_RELEASED  = 2  // Compression relâchée (expansion / breakout)
  };

// État de cassure d'une zone de support/résistance
enum ENUM_BREAKOUT_STATE
  {
   BREAKOUT_NONE           = 0, // Pas de cassure détectée
   BREAKOUT_BULLISH        = 1, // Cassure haussière (confirmée à ce stade)
   BREAKOUT_BEARISH        = 2, // Cassure baissière (confirmée à ce stade)
   BREAKOUT_FALSE_BULLISH  = 3, // Fausse cassure haussière (retour sous la zone)
   BREAKOUT_FALSE_BEARISH  = 4  // Fausse cassure baissière (retour au-dessus de la zone)
  };

//+------------------------------------------------------------------+
//| ENUMS - Signal & Trading                                           |
//+------------------------------------------------------------------+

// Type de signal produit par le SignalManager (ou un moteur IA futur)
enum ENUM_SIGNAL_TYPE
  {
   SIGNAL_NONE = 0, // Aucun signal
   SIGNAL_BUY  = 1, // Signal d'achat
   SIGNAL_SELL = 2  // Signal de vente
  };

// Méthode de calcul du Stop Loss
enum ENUM_SL_METHOD
  {
   SL_METHOD_ATR            = 0, // Basé sur l'ATR
   SL_METHOD_SUPPORT_RESIST = 1, // Basé sur Support/Résistance
   SL_METHOD_LAST_SWING     = 2  // Basé sur le dernier Swing High/Low
  };

// Méthode de calcul du Take Profit
enum ENUM_TP_METHOD
  {
   TP_METHOD_RR             = 0, // Ratio Risk/Reward fixe
   TP_METHOD_ATR            = 1, // Basé sur l'ATR
   TP_METHOD_SUPPORT_RESIST = 2  // Basé sur Support/Résistance
  };

// Mode de gestion des positions
enum ENUM_POSITION_MODE
  {
   POS_MODE_SINGLE = 0, // Une seule position à la fois
   POS_MODE_MULTI  = 1  // Plusieurs positions autorisées
  };

// Sessions de trading
enum ENUM_SESSION_NAME
  {
   SESSION_TOKYO   = 0,
   SESSION_LONDON  = 1,
   SESSION_NEWYORK = 2
  };

// Niveau de journalisation (Logger)
enum ENUM_LOG_LEVEL
  {
   LOG_LEVEL_NONE  = 0, // Aucun log
   LOG_LEVEL_ERROR = 1, // Erreurs uniquement
   LOG_LEVEL_INFO  = 2, // Informations générales
   LOG_LEVEL_DEBUG = 3  // Détail complet (debug)
  };

// Importance d'une annonce économique (mappée depuis le calendrier
// natif MQL5 ou fournie directement via import CSV)
enum ENUM_NEWS_IMPORTANCE
  {
   NEWS_IMPORTANCE_LOW    = 0,
   NEWS_IMPORTANCE_MEDIUM = 1,
   NEWS_IMPORTANCE_HIGH   = 2
  };

// Source des données de news utilisée par CNewsFilter
enum ENUM_NEWS_SOURCE
  {
   NEWS_SOURCE_NONE            = 0, // Filtre de news désactivé
   NEWS_SOURCE_NATIVE_CALENDAR = 1, // Calendrier économique natif MQL5
   NEWS_SOURCE_CSV_IMPORT      = 2  // Import manuel depuis un fichier CSV
  };

//+------------------------------------------------------------------+
//| ENUMS - Validation                                                  |
//+------------------------------------------------------------------+

// Code de résultat retourné par un check individuel du Validator
enum ENUM_CHECK_RESULT
  {
   CHECK_PASSED = 0, // Vérification réussie (✔)
   CHECK_FAILED = 1  // Vérification échouée (❌)
  };

//+------------------------------------------------------------------+
//| ENUMS - Patterns de bougies                                         |
//+------------------------------------------------------------------+

// Pattern de bougie détecté par CPatterns
enum ENUM_CANDLE_PATTERN
  {
   PATTERN_NONE               = 0,
   PATTERN_PINBAR_BULLISH     = 1,
   PATTERN_PINBAR_BEARISH     = 2,
   PATTERN_ENGULFING_BULLISH  = 3,
   PATTERN_ENGULFING_BEARISH  = 4,
   PATTERN_INSIDE_BAR         = 5,
   PATTERN_OUTSIDE_BAR        = 6,
   PATTERN_DOJI               = 7,
   PATTERN_MORNING_STAR       = 8,
   PATTERN_EVENING_STAR       = 9,
   PATTERN_MARUBOZU_BULLISH   = 10,
   PATTERN_MARUBOZU_BEARISH   = 11,
   PATTERN_HAMMER             = 12,
   PATTERN_SHOOTING_STAR      = 13
  };

//+------------------------------------------------------------------+
//| ENUMS - Laboratoire d'analyse (NOUVEAU - Phase 1)                  |
//+------------------------------------------------------------------+

// Type d'événement survenant pendant la vie d'un trade, enregistré
// par CTradeLifecycleTracker dans TradeEvents.csv. Conçu pour être
// EXTENSIBLE sans réécriture : ajouter un futur type d'événement
// (partial close, pyramiding, multi-TP...) ne nécessite qu'une
// nouvelle valeur ici, la struct SPositionEvent restant générique.
enum ENUM_TRADE_EVENT_TYPE
  {
   EVENT_OPENED               = 0, // Ouverture de la position
   EVENT_BREAKEVEN_ACTIVATED  = 1, // Premier déclenchement du Break Even
   EVENT_TRAILING_ACTIVATED   = 2, // Premier déclenchement du Trailing
   EVENT_SL_MODIFIED          = 3, // SL déplacé (Trailing classique, ATR ou BreakEven)
   EVENT_TP_MODIFIED          = 4, // TP modifié
   EVENT_PARTIAL_CLOSE        = 5, // Fermeture partielle (prévu pour évolution future)
   EVENT_PYRAMID_ADD          = 6, // Renforcement de position (prévu pour évolution future)
   EVENT_MANUAL_CLOSE         = 7, // Clôture manuelle détectée
   EVENT_CLOSED               = 8, // Clôture finale de la position
   EVENT_NEWS_DURING_TRADE    = 9, // Une annonce economique importante est tombee pendant que le trade etait ouvert
   EVENT_OTHER                = 10  // Catégorie de secours (ne doit normalement jamais servir)
  };

// Catégorie de message de debug (NOUVEAU - Phase 1, module Debug.mqh).
// Indépendante du niveau de sévérité ENUM_LOG_LEVEL ci-dessus : un
// message peut être de sévérité DEBUG ET de catégorie TRAILING, les
// deux filtres s'appliquant ensemble (voir CDebug dans Debug.mqh).
// DEBUG_CAT_COUNT doit TOUJOURS rester la dernière valeur : elle sert
// uniquement à dimensionner le tableau interne de CDebug. Ajouter une
// future catégorie ne nécessite qu'une valeur de plus avant COUNT.
enum ENUM_DEBUG_CATEGORY
  {
   DEBUG_CAT_TRADE    = 0, // Ouverture / modification / clôture de position
   DEBUG_CAT_SIGNAL   = 1, // Calcul du score et détection de signal
   DEBUG_CAT_TRAILING = 2, // Break Even / Trailing Stop (tick par tick)
   DEBUG_CAT_STATS    = 3, // Statistiques et diagnostics
   DEBUG_CAT_COUNT    = 4  // Sentinelle - ne pas utiliser comme catégorie réelle
  };

// Mode d'armement du Profit Guard (NOUVEAU - moteur de protection
// hiérarchique). Deux modes exclusifs, configurables via
// InpProfitGuardActivationMode.
enum ENUM_PROFIT_GUARD_ACTIVATION_MODE
  {
   ACTIVATION_BY_R      = 0, // Armement en multiple du risque initial du trade (1R = distance entree-SL initial, en $)
   ACTIVATION_BY_MONEY  = 1  // Armement a un montant fixe en $ (optionnel, pour compatibilite avec un besoin utilisateur simple)
  };

// Source de la protection retenue par ProfitProtectionEngine::ComputeFinalStopLevel().
// Sert a la fois de valeur de retour pour la logique interne ET de
// libellé de traçabilité dans TradeEvents.csv (cause).
//
// ÉTENDU (refonte "decision unique") : BreakEven et Trailing sont
// désormais des calculateurs au même titre que Structure/PeakPercent/
// Emergency - une seule décision de SL est calculée par tick, quel
// que soit le mécanisme qui la propose.
enum ENUM_PROTECTION_SOURCE
  {
   PROTECTION_SOURCE_NONE          = 0, // Aucun candidat plus protecteur que le SL actuel
   PROTECTION_SOURCE_BREAKEVEN     = 1, // Break Even
   PROTECTION_SOURCE_TRAILING      = 2, // Trailing (classique ou ATR - distingue via le libellé texte du calculateur)
   PROTECTION_SOURCE_STRUCTURE     = 3, // Higher Low/Lower High confirme + BOS dans le sens du trade
   PROTECTION_SOURCE_PEAK_PERCENT  = 4, // Filet de securite (% du PeakProfit)
   PROTECTION_SOURCE_EMERGENCY     = 5  // CHOCH contraire + effondrement du profit / retournement momentum
  };

// NOUVEAU (refonte "decision unique"). Contexte partagé transmis à
// CHAQUE calculateur de niveau de protection (IProtectionLevelCalculator).
// C'est ce contexte commun qui permet à ProfitProtectionEngine
// d'appeler tous les calculateurs de façon uniforme, sans connaître
// leurs besoins spécifiques - chaque calculateur ne lit que les
// champs qui le concernent. Un futur calculateur FVG/Order Block/
// Equal High-Low n'aura besoin d'AUCUN champ supplémentaire ici tant
// qu'il se contente d'un niveau de prix (le cas de tous les concepts
// SMC de sortie) - et s'il en avait besoin, l'ajouter ici ne casse
// aucun calculateur existant (ils ignorent simplement les champs
// qu'ils n'utilisent pas).
struct SProtectionContext
  {
   ulong             ticket;             // = positionId (voir diagnostic ticket/deal/position - meme convention partout)
   ENUM_SIGNAL_TYPE  type;
   double            entryPrice;
   double            currentSL;
   double            currentTP;
   double            peakProfitMoney;
   double            currentProfitMoney;
   double            atrValue;
   double            currentMomentum;
   double            tickValue;
   double            tickSize;
   double            lot;
  };

//+------------------------------------------------------------------+
//| STRUCTS - Contexte marché                                          |
//+------------------------------------------------------------------+

// Instantané complet du contexte de marché à un instant donné.
// Construit par CMarketContext et consommé en lecture seule par
// tous les autres modules (Signal, Risk, Validator, Dashboard...).
struct SMarketContext
  {
   ENUM_TREND_STATE        trend;             // Tendance globale
   ENUM_VOLATILITY_STATE   volatility;         // Régime de volatilité
   ENUM_WYCKOFF_PHASE      wyckoffPhase;       // Phase Wyckoff estimée
   ENUM_COMPRESSION_STATE  compression;        // État de compression
   double                  momentum;           // Score de momentum (-100..+100)
   double                  marketStrength;     // Force du marché (0..100)
   double                  liquidityScore;     // Score de liquidité estimé (0..100)
   double                  atrValue;           // Valeur ATR courante
   double                  adxValue;           // Valeur ADX courante
   datetime                lastUpdate;         // Heure de la dernière mise à jour
  };

//+------------------------------------------------------------------+
//| STRUCTS - Score & Signal                                            |
//+------------------------------------------------------------------+

// Pondération des critères du système de score intelligent.
struct SScoreWeights
  {
   double emaScore;            // Poids EMA
   double rsiScore;            // Poids RSI
   double atrScore;            // Poids ATR
   double supportResistScore;  // Poids Support/Résistance
   double patternScore;        // Poids Pattern de bougie
   double momentumScore;       // Poids Momentum
   double trendScore;          // Poids Tendance
   double breakoutScore;       // Poids Cassure
   double volumeScore;         // Poids Volume
  };

// Résultat d'un signal détecté (utilisé aussi pour le mode "analyse
// des performances" qui enregistre tous les signaux, exécutés ou non).
// Cette structure est le CONTRAT d'interface entre le moteur de
// décision (CSignalManager aujourd'hui, un moteur IA demain) et le
// reste du système (CTradeManager, CRiskManager, CLogger...).
struct SSignalResult
  {
   ENUM_SIGNAL_TYPE  type;        // BUY / SELL / NONE
   double            score;       // Score total obtenu
   double            confidence;  // Niveau de confiance (0-100%)
   string            reason;      // Justification textuelle du signal
   datetime          time;        // Heure de détection (heure de la bougie)
   double            price;       // Prix au moment du signal
   bool              executed;    // Le signal a-t-il été exécuté en trade ?
   double            bullishScore; // Score haussier brut (diagnostic)
   double            bearishScore; // Score baissier brut (diagnostic)
   double            thresholdPoints; // Seuil en points au moment du calcul (diagnostic)
  };

//+------------------------------------------------------------------+
//| STRUCTS - Risque & Money Management                                 |
//+------------------------------------------------------------------+

// Paramètres de gestion du risque utilisés par RiskManager/MoneyManagement
struct SRiskParams
  {
   double riskPercent;       // Risque en % du capital par trade
   double slDistancePoints;  // Distance du SL en points
   double tickValue;         // Valeur du tick (symbole courant)
   double tickSize;          // Taille du tick
   double volumeMin;         // Volume minimal autorisé par le broker
   double volumeMax;         // Volume maximal autorisé par le broker
   double volumeStep;        // Step de volume du broker
  };

//+------------------------------------------------------------------+
//| STRUCTS - Sessions                                                  |
//+------------------------------------------------------------------+

// Configuration d'activation d'une session de trading
struct SSessionConfig
  {
   bool enabled;    // Session activée ?
   int  startHour;  // Heure de début (heure serveur)
   int  endHour;    // Heure de fin (heure serveur)
  };

//+------------------------------------------------------------------+
//| STRUCTS - Validation                                                |
//+------------------------------------------------------------------+

// Résultat détaillé d'un check individuel effectué par CValidator
struct SValidationCheck
  {
   string             label;   // Nom du check (ex: "Spread", "Session")
   ENUM_CHECK_RESULT  result;  // CHECK_PASSED ou CHECK_FAILED
   string             detail;  // Détail explicatif (raison de l'échec par ex.)
  };

// Rapport global de validation avant l'ouverture d'un trade.
// Regroupe tous les SValidationCheck et indique si le trade est autorisé.
struct SValidationReport
  {
   bool               tradeAllowed;         // true si TOUS les checks sont OK
   SValidationCheck   checks[20];            // Détail de chaque vérification
   int                checksCount;           // Nombre de checks effectivement remplis
   string             summary;               // Résumé textuel formaté (✔/❌)
  };

// Regroupe tous les paramètres nécessaires à un appel CValidator::Validate(),
// pour éviter une fonction à 15 paramètres et centraliser le contrat
// d'entrée du moteur de validation.
struct SValidationInput
  {
   string            symbol;                 // Symbole concerné
   ENUM_SIGNAL_TYPE  signalType;             // BUY / SELL
   double            lot;                    // Volume prévu
   double            entryPrice;             // Prix d'entrée prévu
   double            slPrice;                // Prix du Stop Loss prévu
   double            tpPrice;                // Prix du Take Profit prévu
   int               currentOpenPositions;   // Nombre de positions ouvertes actuellement (ce Magic Number)
   int               maxPositions;           // Nombre maximal autorisé
   double            dailyProfitPercent;     // P/L du jour en % du solde (négatif = perte)
   double            maxDailyLossPercent;    // Perte journalière maximale autorisée (%)
   double            maxDailyGainPercent;    // Gain journalier maximal autorisé (%) - stop trading si atteint
   double            maxSpreadPoints;        // Spread maximal autorisé (points)
   bool              newsBlockActive;        // true si une news importante bloque le trading (calculé par NewsFilter)
   bool              sessionAllowedOverride; // Permet à CSessions de forcer la décision de session une fois ce module créé
   bool              useSessionOverride;     // Si true, sessionAllowedOverride est utilisé au lieu du calcul interne
  };

// Résultat de la détection de pattern de bougie par CPatterns.
struct SPatternResult
  {
   ENUM_CANDLE_PATTERN  pattern;      // Pattern détecté (PATTERN_NONE si aucun)
   bool                 bullish;      // true = biais haussier, false = biais baissier
   double               strength;     // Force du pattern (0-100), basée sur sa géométrie
   string               description;  // Description lisible pour CLogger/CDashboard
   datetime             time;         // Heure de la bougie analysée
  };

// Une annonce économique, qu'elle provienne du calendrier natif MQL5
// ou d'un import CSV manuel (interface commune pour les deux sources).
struct SNewsEvent
  {
   datetime              time;        // Heure prévue de l'annonce
   string                currency;    // Devise concernée (ex: "USD")
   string                name;        // Nom de l'annonce (ex: "Non-Farm Payrolls")
   ENUM_NEWS_IMPORTANCE  importance;  // Niveau d'importance
  };

// Enregistrement d'une position clôturée, reconstruit depuis
// l'historique des deals MT5 par CPositionManager.
struct SPositionRecord
  {
   ulong    positionId;      // POSITION_ID MT5 (identifiant de groupe de deals)
   string   symbol;
   ENUM_SIGNAL_TYPE type;    // BUY / SELL déduit du type de deal d'entrée
   double   volume;
   double   entryPrice;
   double   exitPrice;
   double   profit;          // Profit net (deal profit + swap + commission)
   datetime openTime;
   datetime closeTime;
   int      durationSeconds;
   double   rr;              // Ratio Risk/Reward réalisé (approximatif, basé sur le SL initial de l'ordre d'entrée)
   string   closeReason;     // "TP atteint" / "SL atteint" / "Fermeture EA" / "Fermeture manuelle" / "Stop Out" / "Autre" (deduit de DEAL_REASON)
   double   mfe;             // Maximum Favorable Excursion (en prix, mouvement le plus favorable atteint pendant le trade)
   double   mae;             // Maximum Adverse Excursion (en prix, mouvement le plus défavorable atteint pendant le trade)
  };

// Regroupe toutes les données affichées par CDashboard, pour éviter
// une fonction Update() à 15 paramètres.
struct SDashboardData
  {
   string               symbol;
   ENUM_TREND_STATE     trend;
   ENUM_VOLATILITY_STATE volatility;
   ENUM_SIGNAL_TYPE     signalType;
   double               score;
   double               maxScore;
   double               spreadPoints;
   double               atrValue;
   double               rsiValue;
   double               dailyProfit;
   double               drawdownPercent;
   int                  positionsCount;
   int                  maxPositions;
   string               sessionLabel;
   string               robotState; // ex: "Actif", "Stoppé (perte journaliere max)", "Recovery"
  };

// Snapshot complet du marché au moment de l'ouverture d'un trade,
// pour analyse statistique après plusieurs centaines d'exécutions
// (point 3 du cahier des charges "laboratoire d'analyse").
//
// MODIFIÉ (Phase 1) : ajout de positionId. Avant ce champ, un
// snapshot d'ouverture n'était corrélable à rien après coup - c'est
// désormais la clé commune entre TradeSnapshot, TradeEvents et
// TradeFull (voir STradeFullRecord ci-dessous).
struct STradeSnapshot
  {
   ulong                positionId;           // NOUVEAU - clé de corrélation (POSITION_ID)
   datetime             entryTime;
   string               symbol;
   ENUM_TIMEFRAMES      timeframe;
   ENUM_SIGNAL_TYPE     signalType;
   double               entryPrice;
   double               slPrice;
   double               tpPrice;
   double               lot;
   double               rr;
   double               emaFast;
   double               emaSlow;
   double               rsi;
   double               atr;
   double               momentum;
   ENUM_TREND_STATE     trendState;
   ENUM_VOLATILITY_STATE volatilityState;
   double               nearestSupport;
   double               nearestResistance;
   double               distanceToSupport;
   double               distanceToResistance;
   string               patternDescription;
   ENUM_BREAKOUT_STATE  breakoutState;
   double               scoreBullish;
   double               scoreBearish;
   double               scoreThreshold;

   // --- NOUVEAU (analyse technique complémentaire, demandée explicitement) ---
   string               fibNearestLevel;      // Ex: "61.8%" - niveau Fibonacci le plus proche du prix d'entrée
   double               fibDistancePoints;    // Distance (points) entre l'entrée et ce niveau
   string               fibLegDirection;      // "Impulsion haussiere" / "Impulsion baissiere" / "Indeterminee"
   string               structureEvent;       // "BOS_BULLISH" / "CHOCH_BEARISH" / "Aucun evenement"...
   string               sweepZone;            // "Support" / "Resistance" / "Aucun" - sweep detecte juste avant l'entree
  };

//+------------------------------------------------------------------+
//| STRUCTS - Laboratoire d'analyse (NOUVEAU - Phase 1)                |
//+------------------------------------------------------------------+

// Un événement individuel survenant pendant la vie d'un trade.
// Enregistré par CTradeLifecycleTracker dans TradeEvents.csv - UNE
// LIGNE PAR ÉVÉNEMENT (pas une ligne par trade). Structure GÉNÉRIQUE
// et volontairement simple : previousValue/newValue/note s'adaptent
// à n'importe quel type d'événement (SL, TP, volume partiel...) sans
// avoir besoin d'ajouter des champs spécifiques à chaque nouveau cas
// d'usage futur (partial close, pyramiding, multi-TP...).
struct SPositionEvent
  {
   ulong                   positionId;     // Corrélation avec STradeSnapshot / STradeFullRecord
   datetime                time;           // Horodatage exact de l'événement
   ENUM_TRADE_EVENT_TYPE   eventType;      // Nature de l'événement
   string                  cause;          // Ex: "BreakEven", "TrailingClassique", "TrailingATR", "Manuel"
   double                  previousValue;  // Ex: ancien SL, ancien volume... (0.0 si non applicable)
   double                  newValue;       // Ex: nouveau SL, nouveau volume... (0.0 si non applicable)
   double                  currentProfit;  // Profit flottant en devise au moment exact de l'événement
   string                  note;           // Texte libre complémentaire (optionnel)
  };

// Enregistrement COMPLET d'un trade : contexte d'ouverture + vie du
// trade + résultat de clôture, réunis dans UNE SEULE ligne (fichier
// TradeFull.csv). Objectif explicite validé par l'utilisateur :
// éviter d'avoir à recoller plusieurs fichiers CSV pour répondre à
// des questions comme "les trades ouverts avec RSI 62-68 ont-ils de
// meilleurs résultats ?".
//
// Cette struct NE DUPLIQUE PAS les calculs : ses valeurs proviennent
// telles quelles de STradeSnapshot (ouverture), CTradeLifecycleTracker
// (vie du trade) et SPositionRecord/CPositionManager (clôture, source
// de vérité broker).
struct STradeFullRecord
  {
   // --- Identité ---
   ulong                positionId;

   // --- Contexte d'ouverture (recopié de STradeSnapshot) ---
   datetime             entryTime;
   string               symbol;
   ENUM_TIMEFRAMES      timeframe;
   ENUM_SIGNAL_TYPE     signalType;
   double               entryPrice;
   double               slInitial;
   double               tpInitial;
   double               lot;
   double               rrPlanned;
   double               emaFast;
   double               emaSlow;
   double               rsi;
   double               atr;
   double               momentum;
   ENUM_TREND_STATE     trendState;
   ENUM_VOLATILITY_STATE volatilityState;
   double               nearestSupport;
   double               nearestResistance;
   double               distanceToSupport;
   double               distanceToResistance;
   string               patternDescription;
   ENUM_BREAKOUT_STATE  breakoutState;
   double               scoreBullish;
   double               scoreBearish;
   double               scoreThreshold;
   double               tradeQualityScore;     // NOUVEAU - note 0-100 calculée à l'ouverture (voir TradeLifecycleTracker)

   // --- NOUVEAU (analyse technique complémentaire, demandée explicitement) ---
   string               fibNearestLevel;
   double               fibDistancePoints;
   string               fibLegDirection;
   string               structureEvent;
   string               sweepZone;

   // --- Vie du trade (rempli par CTradeLifecycleTracker) ---
   double               mfeMoney;              // Maximum Favorable Excursion, en devise du compte ($)
   double               maeMoney;              // Maximum Adverse Excursion (Heat), en devise du compte ($)
   int                  timeInProfitSec;       // Temps total passé en profit flottant positif
   int                  timeInLossSec;         // Temps total passé en profit flottant négatif
   int                  slModificationCount;   // Nombre de fois où le SL a été modifié (BreakEven + Trailing confondus)
   int                  slModificationCountBreakEven; // NOUVEAU - dont modifications causées par le BreakEven
   int                  slModificationCountTrailing;  // NOUVEAU - dont modifications causées par le Trailing (classique ou ATR)
   int                  tpModificationCount;   // Nombre de fois où le TP a été modifié
   datetime             breakEvenActivatedTime; // 0 si jamais activé
   datetime             trailingActivatedTime;  // 0 si jamais activé
   int                  newsDuringTradeCount;   // NOUVEAU - nombre d'annonces importantes tombees pendant que le trade etait ouvert
   string               newsDuringTradeLastDetail; // NOUVEAU - detail de la derniere annonce (nom/devise/heure)
   int                  slModificationCountProfitGuard; // NOUVEAU - dont modifications causees par ProfitProtectionEngine (Structure/PeakPercent/Emergency)
   bool                 profitGuardArmed;       // NOUVEAU - le Profit Guard s'est-il arme au moins une fois sur ce trade ?
   double               profitGuardPeakProfitMoney; // NOUVEAU - PeakProfit maximal enregistre par le Profit Guard ($)
   string               profitGuardLastSource;  // NOUVEAU - derniere source de protection ayant modifie le SL (Structure/PeakPercent/Emergency/Aucune)

   // --- Clôture (recopié de SPositionRecord - source de vérité broker) ---
   double               exitPrice;
   double               profitFinal;
   datetime             closeTime;
   int                  durationSeconds;
   string               closeReasonRaw;        // Raison brute MT5 (DEAL_REASON traduit)
   string               closeReasonDetailed;   // Raison affinée par le tracker (ex: "SL Trailing" vs "SL initial jamais modifié")

   // --- Métriques dérivées (Phase 1, demandées explicitement) ---
   double               captureRatioPercent;   // profitFinal / mfeMoney * 100 (0 si mfeMoney == 0)
   double               profitLeftOnTable;     // mfeMoney - profitFinal (en $, "argent laissé sur la table")
   double               rrRealized;            // NOUVEAU - RR reellement obtenu (delegue a CPositionManager, meme limite documentee : base sur le SL initial)
   double               profitPercent;         // NOUVEAU - profitFinal en % du solde initial du compte
   int                  partialCloseCount;     // NOUVEAU - nombre de fermetures partielles effectuees sur ce trade
  };

// CORRECTIF COMPILATION (Phase 1) : ce struct était défini à tort dans
// PostCloseWatcher.mqh. Erreur de dépendance : CLogger (bas niveau,
// utilisé par presque tous les modules) a besoin de connaître ce type
// pour LogPostCloseReview(), mais Logger.mqh n'inclut jamais
// PostCloseWatcher.mqh (et ne le devrait pas - mauvais sens de
// dépendance). Déplacé ici, comme tous les autres formats de sortie
// du projet (STradeSnapshot, SPositionEvent, STradeFullRecord).
//
// Résultat complet d'une revue post-clôture : mouvement du marché
// 5/15/30 minutes puis 1h et 4h après la clôture d'un trade, pour
// répondre à "le trailing a-t-il coupé trop tôt ?".
struct SPostCloseReview
  {
   ulong    positionId;
   string   symbol;
   ENUM_SIGNAL_TYPE type;
   double   exitPrice;
   double   exitProfitMoney;   // Profit avec lequel le trade a été clôturé (pour comparaison)
   datetime exitTime;
   double   move5min;
   double   move15min;
   double   move30min;
   double   move1h;
   double   move4h;
  };

#endif // TYPES_MQH
//+------------------------------------------------------------------+
