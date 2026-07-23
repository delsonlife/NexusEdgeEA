//+------------------------------------------------------------------+
//|                                                     Config.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Fichier de configuration utilisateur.               |
//|   Contient UNIQUEMENT les paramètres "input" exposés à           |
//|   l'utilisateur (et à l'optimiseur du Strategy Tester).           |
//|   Les enums, structs et constantes sont définis dans Types.mqh.  |
//|                                                                    |
//| Ce fichier ne contient aucune logique métier.                     |
//|                                                                    |
//| MODIFIÉ (Phase 1 - Instrumentation) : ajout du groupe "Debug      |
//|   Avancé" (flags par catégorie, consommés par Debug.mqh) et de    |
//|   InpScreenshotOnTrade (désactivé par défaut - voir discussion,   |
//|   fonctionnalité non implémentée dans cette phase). AUCUN input   |
//|   existant n'a été modifié ni supprimé.                           |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef CONFIG_MQH
#define CONFIG_MQH

#include "Types.mqh"

input bool InpEnableDailyLimits = false;   // false pendant les tests, true en production

//+------------------------------------------------------------------+
//| INPUTS - Général                                                   |
//+------------------------------------------------------------------+
input group "=== Général ==="
input long    InpMagicNumber        = 202601;              // Magic Number
input string  InpTradeComment       = "NexusEdgeEA";        // Commentaire des ordres
input ENUM_LOG_LEVEL InpLogLevel    = LOG_LEVEL_INFO;       // Niveau de journalisation

//+------------------------------------------------------------------+
//| INPUTS - Timeframes                                                |
//+------------------------------------------------------------------+
input group "=== Multi Timeframe ==="
input ENUM_TIMEFRAMES InpTF_Main    = PERIOD_H1;            // Timeframe principal (analyse & signal)
input ENUM_TIMEFRAMES InpTF_Low     = PERIOD_M15;           // Timeframe inférieur (confirmation)
input ENUM_TIMEFRAMES InpTF_High    = PERIOD_H4;            // Timeframe supérieur (contexte de tendance)

//+------------------------------------------------------------------+
//| INPUTS - Indicateurs                                               |
//+------------------------------------------------------------------+
input group "=== Indicateurs - Moyennes Mobiles ==="
input int     InpEMA_Fast           = 20;                   // Période EMA rapide
input int     InpEMA_Medium         = 50;                   // Période EMA médiane
input int     InpEMA_Slow           = 100;                  // Période EMA lente
input int     InpEMA_Trend          = 200;                  // Période EMA de tendance long terme

input group "=== Indicateurs - Oscillateurs & Volatilité ==="
input int     InpRSI_Period         = 14;                   // Période RSI
input int     InpATR_Period         = 14;                   // Période ATR
input int     InpADX_Period         = 14;                   // Période ADX
input double  InpADX_TrendThreshold = 25.0;                  // ADX au-dessus duquel une tendance est jugée valide
input double  InpADX_RangeThreshold = 20.0;                  // ADX en-dessous duquel un range est jugé valide
input int     InpBB_Period          = 20;                   // Période Bollinger Bands
input double  InpBB_Deviation       = 2.0;                  // Déviation Bollinger Bands
input bool    InpUseVWAP            = true;                 // Utiliser le VWAP si disponible

//+------------------------------------------------------------------+
//| INPUTS - Filtre de volatilité                                      |
//+------------------------------------------------------------------+
input group "=== Filtre de Volatilité ==="
input double  InpATR_MinPoints      = 80;                   // ATR minimal (points) pour trader
input double  InpATR_MaxPoints      = 3000;                  // ATR maximal (points) pour trader - recalibré pour XAUUSD
input double  InpMaxSpreadPoints    = 300;                  // Spread maximal autorisé (points)

//+------------------------------------------------------------------+
//| INPUTS - Support / Résistance                                      |
//+------------------------------------------------------------------+
input group "=== Support / Resistance ==="
input int     InpSR_LookbackBars           = 150;            // Profondeur d'historique scannee pour les zones
input int     InpSR_SwingStrength          = 2;               // Nb de bougies de chaque cote pour confirmer un swing
input double  InpSR_ZoneMergeDistancePoints = 600.0;          // Distance de fusion des zones (points) - recalibre pour XAUUSD
input double  InpSignal_ZoneTolerancePoints = 600.0;          // Tolerance de confluence Pattern/S-R (points) - recalibre pour XAUUSD


//+------------------------------------------------------------------+
//| INPUTS - Sessions                                                  |
//+------------------------------------------------------------------+
input group "=== Sessions de Trading (heure serveur) ==="
input bool    InpSessionTokyoEnabled   = true;               // Activer session Tokyo
input int     InpSessionTokyoStart     = 0;                  // Heure début Tokyo
input int     InpSessionTokyoEnd       = 9;                  // Heure fin Tokyo
input bool    InpSessionLondonEnabled  = true;               // Activer session Londres
input int     InpSessionLondonStart    = 8;                  // Heure début Londres
input int     InpSessionLondonEnd      = 17;                 // Heure fin Londres
input bool    InpSessionNewYorkEnabled = true;                // Activer session New York
input int     InpSessionNewYorkStart   = 13;                 // Heure début New York
input int     InpSessionNewYorkEnd     = 22;                 // Heure fin New York

//+------------------------------------------------------------------+
//| INPUTS - News Filter                                               |
//+------------------------------------------------------------------+
input group "=== Filtre de News ==="
input bool    InpNewsFilterEnabled  = true;                  // Activer le filtre de news
input int     InpNewsMinutesBefore  = 30;                    // Minutes avant l'annonce (pause)
input int     InpNewsMinutesAfter   = 30;                    // Minutes après l'annonce (pause)

//+------------------------------------------------------------------+
//| INPUTS - Système de score intelligent                              |
//+------------------------------------------------------------------+
input group "=== Système de Score ==="
input double  InpScore_EMA           = 30;                  // Points EMA
input double  InpScore_RSI           = 20;                  // Points RSI
input double  InpScore_ATR           = 10;                  // Points ATR
input double  InpScore_SupportResist = 20;                  // Points Support/Résistance
input double  InpScore_Pattern       = 20;                  // Points Pattern
input double  InpScore_Momentum      = 20;                  // Points Momentum
input double  InpScore_Trend         = 30;                  // Points Tendance
input double  InpScore_Breakout      = 15;                  // Points Breakout
input double  InpScore_Volume        = 15;                  // Points Volume
input double  InpScore_Threshold     = 60;                  // Seuil en % du score maximum possible (PAS des points - ex: 60 = 60% du score max)

//+------------------------------------------------------------------+
//| INPUTS - Gestion du risque                                         |
//+------------------------------------------------------------------+
input group "=== Gestion du Risque ==="
input double  InpRiskPercent        = 1.0;                  // Risque par trade (% du capital)
input ENUM_SL_METHOD InpSL_Method   = SL_METHOD_ATR;         // Méthode de calcul du SL
input double  InpSL_ATR_Multiplier  = 1.5;                  // Multiplicateur ATR pour le SL
input ENUM_TP_METHOD InpTP_Method   = TP_METHOD_RR;          // Méthode de calcul du TP
input double  InpTP_RR_Ratio        = 2.0;                  // Ratio Risk/Reward pour le TP
input double  InpTP_ATR_Multiplier  = 3.0;                  // Multiplicateur ATR pour le TP
input int     InpRisk_SwingLookbackBars = 20;                // Profondeur pour SL_METHOD_LAST_SWING
input double  InpRisk_ZoneBufferPoints  = 200.0;             // Marge de securite au-dela d'une zone S/R (points) - recalibre pour XAUUSD

//+------------------------------------------------------------------+
//| INPUTS - Gestion des positions                                     |
//+------------------------------------------------------------------+
input group "=== Gestion des Positions ==="
input ENUM_POSITION_MODE InpPositionMode = POS_MODE_SINGLE;  // Mode de gestion (Single/Multi)
input int     InpMaxPositions        = 1;                    // Nombre maximal de positions simultanées
input bool    InpUseBreakEven        = true;                 // Activer le Break Even
input double  InpBreakEvenTriggerPts = 300;                  // Déclenchement Break Even (points)
input bool    InpUseTrailingStop     = true;                 // Activer le Trailing Stop
input double  InpTrailingStopPts     = 200;                  // Distance de suivi (points) une fois le trailing actif ("TrailingDistance")
input bool    InpUseTrailingATR      = false;                // Activer Trailing basé sur ATR
input double  InpTrailingStartPts    = 150;                  // NOUVEAU - Profit minimum (points) avant activation du trailing ("TrailingStart")
input double  InpTrailingStepPts     = 50;                   // NOUVEAU - Amelioration minimale (points) du SL avant une nouvelle modification ("TrailingStep")
input int     InpMinimumModifyIntervalSec = 1;                // NOUVEAU - Delai minimal (secondes) entre deux PositionModify() sur la meme position
input bool    InpUsePartialClose     = false;                // Activer la fermeture partielle
input double  InpPartialClosePercent = 50;                   // % de fermeture partielle
input bool    InpUseScalingIn        = false;                // Activer Scaling In (renforcement position)
input bool    InpUseScalingOut       = false;                // Activer Scaling Out
input bool    InpUsePyramiding        = false;                // Activer le Pyramiding
input int     InpMaxPyramidLevels    = 1;                    // Niveaux max de pyramiding

//+------------------------------------------------------------------+
//| INPUTS - Sécurité                                                   |
//+------------------------------------------------------------------+
input group "=== Sécurité ==="
input double  InpMaxDailyLossPercent   = 5.0;                // Perte journalière maximale (%)
input double  InpMaxDrawdownPercent    = 20.0;               // Drawdown maximal global autorisé (%)
input double  InpMaxDailyGainPercent   = 10.0;               // Gain journalier maximal (%) - stop trading si atteint
input int     InpMaxConsecutiveLosses  = 3;                  // Nombre de pertes consécutives avant arrêt
input bool    InpRecoveryModeEnabled   = false;               // Activer le mode Recovery

//+------------------------------------------------------------------+
//| INPUTS - Dashboard                                                  |
//+------------------------------------------------------------------+
input group "=== Dashboard ==="
input bool    InpShowDashboard       = true;                 // Afficher le tableau de bord
input int     InpDashboardX          = 10;                   // Position X du dashboard
input int     InpDashboardY          = 20;                   // Position Y du dashboard

//+------------------------------------------------------------------+
//| INPUTS - Analyse des performances (signaux non exécutés)           |
//+------------------------------------------------------------------+
input group "=== Analyse des Performances ==="
input bool    InpLogAllSignals       = true;                 // Enregistrer TOUS les signaux (même non exécutés)
input int     InpSignalReviewBars1   = 10;                   // Nombre de bougies pour la 1ère revue
input int     InpSignalReviewBars2   = 20;                   // Nombre de bougies pour la 2ème revue
input int     InpSignalReviewBars3   = 50;                   // Nombre de bougies pour la 3ème revue

//+------------------------------------------------------------------+
//| INPUTS - Diagnostic du pipeline                                     |
//+------------------------------------------------------------------+
input group "=== Diagnostic ==="
input bool    InpDebugPipeline       = true;                  // Afficher le detail complet du pipeline (Filters/Signal/Risk/Validator/Trade) a chaque bougie
input bool    InpDiagnosticsEnabled  = true;                  // Activer le module CDiagnostics (statistiques globales, sans impact sur la strategie)
input bool    InpEnableDebugPipelineTxt = true;                // NOUVEAU - Fichier DebugPipeline.txt (trace temporaire OPEN/SL MODIFY/TRADE EVENT/FINAL RECORD/CSV WRITE)

//+------------------------------------------------------------------+
//| INPUTS - Debug Avancé (NOUVEAU - Phase 1)                          |
//| Filtrage par CATÉGORIE, indépendant du niveau de sévérité         |
//| (InpLogLevel, existant, inchangé). Un message DEBUG_TRAILING ne   |
//| s'affiche que si InpLogLevel >= LOG_LEVEL_DEBUG ET                |
//| InpDebugTrailing == true. Voir Debug.mqh.                          |
//+------------------------------------------------------------------+
input group "=== Debug Avancé (par catégorie) ==="
input bool    InpDebugTrade          = true;                  // Debug détaillé : ouverture/modification/clôture de position
input bool    InpDebugSignal         = false;                 // Debug détaillé : calcul du score et des signaux
input bool    InpDebugTrailing       = false;                 // Debug détaillé : Break Even / Trailing Stop (tick par tick)
input bool    InpDebugStats          = false;                 // Debug détaillé : statistiques et diagnostics

//+------------------------------------------------------------------+
//| INPUTS - Laboratoire d'analyse (NOUVEAU - Phase 1)                 |
//+------------------------------------------------------------------+
input group "=== Laboratoire d'Analyse ==="
input bool    InpTrackTradeLifecycle = true;                  // Activer le suivi vivant des trades (MFE/MAE/$, evenements, Capture Ratio...)
input bool    InpTrackPostClose      = true;                  // Activer le suivi du marche APRES la cloture d'un trade (5/15/30min, 1h, 4h)
input bool    InpGenerateDailyReport = true;                  // Générer automatiquement un rapport quotidien à chaque changement de jour
input bool    InpScreenshotOnTrade   = false;                 // Capture d'écran à l'ouverture/clôture - NON IMPLÉMENTÉ dans cette phase, réservé pour une évolution future

//+------------------------------------------------------------------+
//| INPUTS - Analyse technique complementaire (Fibonacci / Structure) |
//| Ces parametres ne pilotent QUE de l'observation/logging - aucune  |
//| influence sur les signaux, filtres ou decisions de trading.        |
//+------------------------------------------------------------------+
input group "=== Analyse Fibonacci / Structure de Marche ==="
input int     InpFib_LookbackBars       = 50;                 // Profondeur scannee pour trouver le swing de reference (Fibonacci)
input int     InpStructure_SwingStrength = 2;                 // Nb de bougies de chaque cote pour confirmer un swing (BOS/CHOCH/Sweep)
input int     InpStructure_LookbackBars  = 50;                // Profondeur scannee pour trouver le swing confirme le plus recent

//+------------------------------------------------------------------+
//| INPUTS - Profit Guard (moteur de protection hierarchique)         |
//| PREMIÈRE CONNEXION Structure -> Execution, EXCEPTION VOLONTAIRE   |
//| et documentee de l'architecture (voir ProfitProtectionEngine.mqh) |
//| STRICTEMENT LIMITEE a la protection d'un profit deja acquis -     |
//| ne pilote jamais une entree.                                      |
//+------------------------------------------------------------------+
input group "=== Profit Guard (protection hierarchique du profit) ==="
input bool    InpUseProfitGuard                    = true;   // Activer le Profit Guard (Niveaux 2-4, en plus de BreakEven/Trailing)
input ENUM_PROFIT_GUARD_ACTIVATION_MODE InpProfitGuardActivationMode = ACTIVATION_BY_R; // Mode d'armement (defaut recommande : par R)
input double  InpProfitGuardActivationR            = 1.0;    // Armement a partir de N x le risque initial (1R), si mode = ACTIVATION_BY_R
input double  InpProfitGuardActivationMoney        = 20.0;   // Armement a partir de N $ de profit flottant, si mode = ACTIVATION_BY_MONEY
input double  InpProfitGuardStructureBufferATR     = 0.30;   // Marge (x ATR) sous/sur le Higher Low/Lower High confirme (Niveau 2)
input double  InpProfitGuardMinRetainPercent       = 40.0;   // Filet de securite : % du PeakProfit garanti si aucune structure favorable (Niveau 3)
input bool    InpProfitGuardEmergencyEnabled       = true;   // Activer la protection d'urgence (Niveau 4)
input double  InpProfitGuardEmergencyDrawdownPercent = 50.0; // % de recul depuis le PeakProfit qui, combine a un CHOCH contraire, declenche l'urgence
input double  InpProfitGuardEmergencyMomentumThreshold = 40.0; // Seuil de retournement du momentum (proxy d'acceleration - "volume" non implemente, voir doc)
input bool    InpProfitGuardEmergencyCloseImmediately = false; // false = SL agressif (recommande) ; true = fermeture immediate de la position
input double  InpProfitGuardEmergencyRetainPercent = 80.0;   // % du profit COURANT (pas du peak) garanti si SL agressif d'urgence
input bool    InpProfitGuardDiagnosticMode         = false;  // NOUVEAU - trace detaillee par tick (eligibilite + SL propose de chaque calculateur) dans DebugPipeline.txt - NE PAS laisser actif en continu (tres verbeux)

//+------------------------------------------------------------------+
//| Fonction utilitaire : construit la structure des poids de score  |
//| à partir des inputs. Centralise l'accès pour éviter toute        |
//| duplication dans les autres modules.                              |
//+------------------------------------------------------------------+
SScoreWeights GetScoreWeights()
  {
   SScoreWeights w;
   w.emaScore           = InpScore_EMA;
   w.rsiScore           = InpScore_RSI;
   w.atrScore           = InpScore_ATR;
   w.supportResistScore = InpScore_SupportResist;
   w.patternScore       = InpScore_Pattern;
   w.momentumScore      = InpScore_Momentum;
   w.trendScore         = InpScore_Trend;
   w.breakoutScore      = InpScore_Breakout;
   w.volumeScore        = InpScore_Volume;
   return(w);
  }

//+------------------------------------------------------------------+
//| Fonction utilitaire : construit la configuration des sessions    |
//| indexée par ENUM_SESSION_NAME.                                     |
//+------------------------------------------------------------------+
SSessionConfig GetSessionConfig(const ENUM_SESSION_NAME session)
  {
   SSessionConfig cfg;
   switch(session)
     {
      case SESSION_TOKYO:
         cfg.enabled   = InpSessionTokyoEnabled;
         cfg.startHour = InpSessionTokyoStart;
         cfg.endHour   = InpSessionTokyoEnd;
         break;
      case SESSION_LONDON:
         cfg.enabled   = InpSessionLondonEnabled;
         cfg.startHour = InpSessionLondonStart;
         cfg.endHour   = InpSessionLondonEnd;
         break;
      case SESSION_NEWYORK:
         cfg.enabled   = InpSessionNewYorkEnabled;
         cfg.startHour = InpSessionNewYorkStart;
         cfg.endHour   = InpSessionNewYorkEnd;
         break;
      default:
         cfg.enabled   = false;
         cfg.startHour = 0;
         cfg.endHour   = 0;
         break;
     }
   return(cfg);
  }

#endif // CONFIG_MQH
//+------------------------------------------------------------------+
