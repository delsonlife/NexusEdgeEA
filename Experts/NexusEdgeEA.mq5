//+------------------------------------------------------------------+
//|                                                 NexusEdgeEA.mq5    |
//|                                                  NexusEdgeEA        |
//|                                                                    |
//| Orchestrateur principal. Instancie tous les modules du projet et |
//| connecte OnInit/OnTick/OnDeinit. Analyse UNIQUEMENT à l'ouverture |
//| d'une nouvelle bougie (jamais à chaque tick), conformément à la  |
//| philosophie du robot.                                             |
//|                                                                    |
//| NOTE DE PORTÉE : cette version pilote l'analyse sur le timeframe |
//| principal (InpTF_Main, H1 par défaut). InpTF_Low (M15) et         |
//| InpTF_High (H4) sont exposés en configuration mais pas encore      |
//| utilisés comme filtres de confirmation supplémentaires - ce sera  |
//| une évolution naturelle (instancier une 2e/3e CMarketContext sur  |
//| ces timeframes et croiser leur tendance dans CSignalManager) une  |
//| fois que les premiers backtests auront validé le cœur du système. |
//|                                                                    |
//| MODIFIÉ (Phase 1 - Instrumentation, "laboratoire d'analyse") :    |
//|   - Orchestration de CDebug, CTradeLifecycleTracker et             |
//|     CPostCloseWatcher, en plus des modules déjà existants.        |
//|   - AUCUNE logique de trading, de signal, de risque, de Break     |
//|     Even ni de Trailing Stop n'a été modifiée. Ce fichier ne fait |
//|     qu'AJOUTER des appels d'observation autour de la logique      |
//|     existante (avant/après chaque opération déjà présente).       |
//|   - Chaque trade est désormais indexé par le même "positionId"    |
//|     (= ticket du deal d'entrée = POSITION_ID MT5) à travers TOUS  |
//|     les fichiers de sortie : TradeSnapshots, TradeEvents,          |
//|     TradeFull, Trades.csv, PostCloseReview.                        |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property version   "1.00"
#property strict

// Adapte ces chemins si tes fichiers sont dans des sous-dossiers
// (Core/Market/Trading/Interface/AI) plutôt qu'à plat dans
// MQL5/Include/NexusEdgeEA/
#include <NexusEdgeEA/Types.mqh>
#include <NexusEdgeEA/Config.mqh>
#include <NexusEdgeEA/Utilities.mqh>
#include <NexusEdgeEA/Logger.mqh>
#include <NexusEdgeEA/Debug.mqh>
#include <NexusEdgeEA/Validator.mqh>
#include <NexusEdgeEA/Indicators.mqh>
#include <NexusEdgeEA/MarketContext.mqh>
#include <NexusEdgeEA/Patterns.mqh>
#include <NexusEdgeEA/SupportResistance.mqh>
#include <NexusEdgeEA/Fibonacci.mqh>
#include <NexusEdgeEA/MarketStructure.mqh>
#include <NexusEdgeEA/Sessions.mqh>
#include <NexusEdgeEA/NewsFilter.mqh>
#include <NexusEdgeEA/Filters.mqh>
#include <NexusEdgeEA/SignalManager.mqh>
#include <NexusEdgeEA/RiskManager.mqh>
#include <NexusEdgeEA/TradeManager.mqh>
#include <NexusEdgeEA/ProfitProtectionEngine.mqh>
#include <NexusEdgeEA/PositionManager.mqh>
#include <NexusEdgeEA/TradeLifecycleTracker.mqh>
#include <NexusEdgeEA/PostCloseWatcher.mqh>
#include <NexusEdgeEA/Statistics.mqh>
#include <NexusEdgeEA/Dashboard.mqh>
#include <NexusEdgeEA/SignalRecorder.mqh>
#include <NexusEdgeEA/Diagnostics.mqh>
// --- V3 - Squelette architectural (Sprint V3.0) - voir ARCHITECTURE_V3.md ---
#include <NexusEdgeEA/V3Types.mqh>
#include <NexusEdgeEA/TradeScenarioEngine.mqh>
#include <NexusEdgeEA/StructureObserver.mqh>
#include <NexusEdgeEA/OrderBlockDetector.mqh>
#include <NexusEdgeEA/FVGDetector.mqh>
#include <NexusEdgeEA/HTFBiasObserver.mqh>
#include <NexusEdgeEA/ShadowAnalytics.mqh>
#include <NexusEdgeEA/AccountMetrics.mqh>
#include <NexusEdgeEA/ObservationLayer.mqh>
#include <NexusEdgeEA/HardRiskGuard.mqh>
#include <NexusEdgeEA/LearningEngine.mqh>
// --- V4.1 - Module Opportunity (P1/P2A/P2B/P3) ---
#include <NexusEdgeEA/Opportunity/OpportunityManager.mqh>
#include <NexusEdgeEA/Opportunity/OpportunitySourceSMC.mqh>
#include <NexusEdgeEA/Opportunity/OpportunityPipeline.mqh>
#include <NexusEdgeEA/VirtualTrade/VirtualTradeTracker.mqh>
#include <NexusEdgeEA/Opportunity/VirtualTradeFeed.mqh>
#include <NexusEdgeEA/TradeHealth/TradeHealthGuardian.mqh>
// --- Sprint PropFirm - Protection de portefeuille FTMO ---
#include <NexusEdgeEA/PropFirm/PropFirmRiskGuard.mqh>

//+------------------------------------------------------------------+
//| Instances globales de tous les modules                            |
//+------------------------------------------------------------------+
CLogger              g_logger;
CIndicators          g_indicators;
CMarketContext       g_marketContext;
CPatterns            g_patterns;
CSupportResistance   g_supportResistance;
CMarketStructure     g_marketStructure;   // NOUVEAU - CFibonacci est statique, aucune instance necessaire
CSessions            g_sessions;
CNewsFilter          g_newsFilter;
CFilters             g_filters;
CSignalManager       g_signalManager;
CRiskManager         g_riskManager;
CTradeManager        g_tradeManager;
CProfitProtectionEngine g_profitGuard;      // NOUVEAU - moteur de protection hierarchique du profit
CPositionManager     g_positionManager;
CTradeLifecycleTracker g_tradeTracker;      // NOUVEAU (Phase 1)
CPostCloseWatcher    g_postCloseWatcher;    // NOUVEAU (Phase 1)
CStatistics          g_statistics;
CDashboard           g_dashboard;
CSignalRecorder      g_signalRecorder;
CValidator           g_validator;
CDiagnostics         g_diagnostics;
// --- V3 - Squelette architectural (Sprint V3.0) ---
CTradeScenarioEngine g_scenarioEngine;    // NOUVEAU (V3.0) - coquille, aucune autorite reelle avant V3.5/V3.7
CStructureObserver   g_structureObserver; // NOUVEAU (V3.1) - couche d'observation, remplit g_scenarioContext
COrderBlockDetector  g_orderBlockDetector; // NOUVEAU (V3.2A) - couche d'observation, remplit g_scenarioContext
CFVGDetector         g_fvgDetector;        // NOUVEAU (V3.2B) - couche d'observation, remplit g_scenarioContext (independant de CMarketStructure)
CMarketStructure     g_marketStructureHTF; // NOUVEAU (V3.3) - seconde instance INDEPENDANTE de CMarketStructure, configuree sur InpTF_High (Option A, voir HTFBiasObserver.mqh) - ne remplace ni ne modifie g_marketStructure (H1)
CHTFBiasObserver     g_htfBiasObserver;    // NOUVEAU (V3.3) - couche d'observation, remplit g_scenarioContext
CShadowAnalytics     g_shadowAnalytics;    // NOUVEAU (V3.6) - appariement verdict/trade reel, memoire uniquement, aucune influence
CAccountMetrics      g_accountMetrics;     // NOUVEAU (V3.6.5) - etat courant du compte, corrige le verrouillage permanent du drawdown
CResearchDataLayer   g_researchDataLayer;  // NOUVEAU (V3.9, Increment I1) - persistance, validee en isolation avec des evenements synthetiques
CObservationLayer    g_observationLayer;   // NOUVEAU (V3.9.2, Increment I2) - traduction Decision/Execution -> evenements structures, aucune influence sur le trading
SScenarioContext     g_scenarioContext;   // NOUVEAU (V3.1) - dernier contexte observe (cadence H1), lu en lecture seule par les appels shadow du TSE
CHardRiskGuard       g_hardRiskGuard;     // NOUVEAU (V3.0) - coquille, logique reelle migree au V3.4
CLearningEngine      g_learningEngine;    // NOUVEAU (V3.0) - coquille, logique reelle au V3.8
// --- V4.1 - Module Opportunity (P1/P2A/P2B/P3) ---
COpportunityManager     g_opportunityManager;    // NOUVEAU (V4.1-P3) - Shadow uniquement, aucune autorite reelle
COpportunitySourceSMC   g_opportunitySourceSMC;  // NOUVEAU (V4.1-P3) - pont OrderBlockDetector/CFVGDetector -> Opportunity
COpportunityPipeline    g_opportunityPipeline;   // NOUVEAU (V4.1-P3) - dispatch vers TSE (EvaluateOpportunity), Shadow
CVirtualTradeTracker    g_virtualTradeTracker;   // NOUVEAU (V4.1-P3.1bis) - Niveau 1 (Groupe A), Shadow uniquement, aucun trade reel
int                     g_lastBarIndex = 0;      // NOUVEAU (V4.1-P3) - currentBarIndex, calcule une fois par nouvelle bougie H1, injecte partout ou necessaire (invariant 4 : le module Opportunity ne lit jamais le marche lui-meme)
CTradeHealthGuardian    g_tradeHealthGuardian;   // NOUVEAU (V4.1-P3.3) - modes reversibles, jamais de regression du SL (garanti par IsMoreProtective, inchange)

// --- Sprint PropFirm - Protection de portefeuille FTMO ---
CPropFirmRiskGuard      g_propFirmRiskGuard;        // NOUVEAU - protection compte entier, aucune autorite d'execution directe
bool                    g_propFirmTradingBlocked = false; // NOUVEAU - flag DEDIE, separe du disjoncteur legacy existant (jamais fusionne avec lui)
//+------------------------------------------------------------------+
//| État global de sécurité (perte/gain journalier, jours, pertes    |
//| consécutives)                                                     |
//+------------------------------------------------------------------+
double   g_initialBalance     = 0.0;
datetime g_currentDayStart    = 0;
bool     g_tradingStoppedToday = false;
int      g_lastLoggedTradeCount = 0;
ulong    g_partialClosedTickets[]; // Tickets déjà partiellement clôturés (évite les répétitions)

// --- Table de corrélation : contexte capturé à l'OUVERTURE d'un
// trade, retrouvé au moment de sa CLÔTURE pour alimenter la
// répartition par Direction/Tendance/Pattern/Session de CDiagnostics.
// Clé = ticket de l'ORDRE d'entrée = POSITION_ID MT5 (CORRIGÉ - voir
// le diagnostic du bug openPositionId dans le bloc d'ouverture
// ci-dessous : ce tableau était alimenté avec la MÊME variable
// openPositionId, donc il souffrait du MÊME bug silencieusement -
// FindAndRemoveOpenContext() ne trouvait jamais de correspondance,
// et la répartition par Direction/Tendance/Pattern/Session de
// CDiagnostics recevait 0 contribution depuis le début, sans erreur
// visible. Corrigé automatiquement par la correction de openPositionId).
ulong    g_ctxPositionId[];
string   g_ctxTrend[];
string   g_ctxPattern[];
string   g_ctxSession[];

// --- NOUVEAU (Phase 1) : table de corrélation du SNAPSHOT COMPLET
// (STradeSnapshot entier), retrouvé à la clôture pour assembler
// STradeFullRecord (ouverture + vie + clôture en une seule ligne).
// Séparée de g_ctx* ci-dessus par prudence (ne pas risquer de casser
// un mécanisme de corrélation déjà validé et en production) plutôt
// que fusionnée avec lui.
ulong           g_snapPositionId[];
STradeSnapshot  g_snapData[];

// NOUVEAU (correctif journalisation) : déduplication des événements
// système répétitifs (même principe que le "news pendant le trade" du
// tracker) - évite de spammer SystemEvents.csv à chaque bougie tant
// que la même raison de blocage persiste.
string g_lastFilterBlockLabel    = "";
string g_lastValidatorBlockLabel = "";

//+------------------------------------------------------------------+
//| Vérifie si un ticket a déjà fait l'objet d'une fermeture partielle|
//+------------------------------------------------------------------+
bool AlreadyPartiallyClosed(const ulong ticket)
  {
   int total = ArraySize(g_partialClosedTickets);
   for(int i = 0; i < total; i++)
     {
      if(g_partialClosedTickets[i] == ticket)
         return(true);
     }
   return(false);
  }

void MarkPartiallyClosed(const ulong ticket)
  {
   int n = ArraySize(g_partialClosedTickets);
   ArrayResize(g_partialClosedTickets, n + 1);
   g_partialClosedTickets[n] = ticket;
  }

//+------------------------------------------------------------------+
//| Enregistre le contexte marché au moment de l'ouverture, pour le  |
//| retrouver plus tard à la clôture (répartition CDiagnostics)      |
//| INCHANGÉ (Phase 1).                                                |
//+------------------------------------------------------------------+
void RecordOpenContext(const ulong positionId, const string trend, const string pattern, const string session)
  {
   int n = ArraySize(g_ctxPositionId);
   ArrayResize(g_ctxPositionId, n + 1);
   ArrayResize(g_ctxTrend, n + 1);
   ArrayResize(g_ctxPattern, n + 1);
   ArrayResize(g_ctxSession, n + 1);
   g_ctxPositionId[n] = positionId;
   g_ctxTrend[n]      = trend;
   g_ctxPattern[n]    = pattern;
   g_ctxSession[n]    = session;
  }

//+------------------------------------------------------------------+
//| Retrouve (et retire) le contexte d'ouverture d'une position       |
//| clôturée. Retourne false si aucun contexte trouvé (ex: trade      |
//| ouvert avant le démarrage de cette session de l'EA).              |
//| INCHANGÉ (Phase 1).                                                |
//+------------------------------------------------------------------+
bool FindAndRemoveOpenContext(const ulong positionId, string &trendOut, string &patternOut, string &sessionOut)
  {
   int total = ArraySize(g_ctxPositionId);
   for(int i = 0; i < total; i++)
     {
      if(g_ctxPositionId[i] == positionId)
        {
         trendOut   = g_ctxTrend[i];
         patternOut = g_ctxPattern[i];
         sessionOut = g_ctxSession[i];

         // Retrait par swap-avec-dernier (ordre non important ici)
         int last = total - 1;
         if(i != last)
           {
            g_ctxPositionId[i] = g_ctxPositionId[last];
            g_ctxTrend[i]      = g_ctxTrend[last];
            g_ctxPattern[i]    = g_ctxPattern[last];
            g_ctxSession[i]    = g_ctxSession[last];
           }
         ArrayResize(g_ctxPositionId, last);
         ArrayResize(g_ctxTrend, last);
         ArrayResize(g_ctxPattern, last);
         ArrayResize(g_ctxSession, last);
         return(true);
        }
     }
   trendOut = ""; patternOut = ""; sessionOut = "";
   return(false);
  }

//+------------------------------------------------------------------+
//| NOUVEAU (Phase 1). Enregistre le snapshot COMPLET d'ouverture,    |
//| pour reconstruction de STradeFullRecord à la clôture. Même        |
//| technique (tableaux parallèles + swap-remove) que g_ctx* ci-dessus|
//| pour rester cohérent avec le style déjà établi dans ce fichier.   |
//+------------------------------------------------------------------+
void RecordOpenSnapshot(const ulong positionId, const STradeSnapshot &snap)
  {
   int n = ArraySize(g_snapPositionId);
   ArrayResize(g_snapPositionId, n + 1);
   ArrayResize(g_snapData, n + 1);
   g_snapPositionId[n] = positionId;
   g_snapData[n]        = snap;
  }

bool FindAndRemoveOpenSnapshot(const ulong positionId, STradeSnapshot &snapOut)
  {
   int total = ArraySize(g_snapPositionId);
   for(int i = 0; i < total; i++)
     {
      if(g_snapPositionId[i] == positionId)
        {
         snapOut = g_snapData[i];

         int last = total - 1;
         if(i != last)
           {
            g_snapPositionId[i] = g_snapPositionId[last];
            g_snapData[i]        = g_snapData[last];
           }
         ArrayResize(g_snapPositionId, last);
         ArrayResize(g_snapData, last);
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Réinitialise l'état journalier si un nouveau jour a commencé      |
//|                                                                    |
//| MODIFIÉ (Phase 1) : génère le rapport quotidien (si activé) pour  |
//| le jour qui vient de se terminer, JUSTE AVANT de basculer sur le  |
//| nouveau jour - sinon CStatistics::GetProfitSince(g_currentDayStart)|
//| calculerait sur la mauvaise fenêtre temporelle. Skippé au tout    |
//| premier appel (g_currentDayStart == 0) pour ne pas produire un    |
//| rapport vide au démarrage de l'EA.                                 |
//+------------------------------------------------------------------+
void RefreshDailyStateIfNeeded()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(today != g_currentDayStart)
     {
      if(InpGenerateDailyReport && g_currentDayStart != 0 && g_diagnostics.IsEnabled())
        {
         double profitPercentToday = CUtilities::SafeDivide(g_statistics.GetProfitSince(g_currentDayStart), g_initialBalance, 0.0) * 100.0;
         double profitFactorToday  = g_statistics.GetProfitFactorSince(g_currentDayStart);
         string dailyReport = g_diagnostics.GenerateDailyReport(profitPercentToday, profitFactorToday);
         g_logger.LogInfo(dailyReport);
         DEBUG_STATS("Rapport quotidien genere et snapshot Diagnostics reinitialise pour le nouveau jour");
         g_diagnostics.ResetDailySnapshot();
        }

      g_currentDayStart     = today;
      g_tradingStoppedToday = false;
      g_logger.LogInfo("Nouveau jour de trading - réinitialisation des limites journalières");
     }
  }

//+------------------------------------------------------------------+
//| Compte les pertes consécutives les plus récentes (historique)     |
//+------------------------------------------------------------------+
int CountRecentConsecutiveLosses()
  {
   int total = g_positionManager.GetRecordCount();
   int count = 0;
   for(int i = total - 1; i >= 0; i--)
     {
      if(g_positionManager.GetRecord(i).profit < 0.0)
         count++;
      else
         break;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Journalise les trades nouvellement clôturés depuis le dernier     |
//| passage (CLogger::LogTrade attend un trade complet)                |
//|                                                                    |
//| MODIFIÉ (Phase 1) : assemble désormais STradeFullRecord (snapshot |
//| d'ouverture + vie du trade via CTradeLifecycleTracker + résultat  |
//| de clôture), écrit les événements chronologiques, la timeline     |
//| texte, et enregistre le trade auprès de CPostCloseWatcher. Le     |
//| détail WIN/LOSS/raison/MFE/MAE existant (CDiagnostics) est         |
//| enrichi avec les nouvelles métriques mais son fonctionnement de   |
//| base reste identique.                                              |
//+------------------------------------------------------------------+
void LogNewlyClosedTrades()
  {
   int total = g_positionManager.GetRecordCount();
   for(int i = g_lastLoggedTradeCount; i < total; i++)
     {
      SPositionRecord rec = g_positionManager.GetRecord(i);

      // Raison de clôture AFFINÉE (distingue SL initial / BreakEven /
      // Trailing - voir la limite documentée dans PositionManager.mqh
      // que ce mécanisme comble directement).
      string detailedReason = g_tradeTracker.BuildDetailedCloseReason(rec.positionId, rec.closeReason);

      // --- Assemblage de STradeFullRecord (ouverture + vie + clôture) ---
      STradeSnapshot openSnap;
      bool hasSnapshot = FindAndRemoveOpenSnapshot(rec.positionId, openSnap);
      if(!hasSnapshot)
         g_logger.LogPipelineDebug(StringFormat("[ERROR]\r\nSnapshot d'ouverture introuvable pour PositionID=%I64u", rec.positionId));

      STradeFullRecord full;
      ZeroMemory(full);
      full.positionId = rec.positionId;

      if(hasSnapshot)
        {
         full.entryTime            = openSnap.entryTime;
         full.symbol               = openSnap.symbol;
         full.timeframe            = openSnap.timeframe;
         full.signalType           = openSnap.signalType;
         full.entryPrice           = openSnap.entryPrice;
         full.slInitial            = openSnap.slPrice;
         full.tpInitial            = openSnap.tpPrice;
         full.lot                  = openSnap.lot;
         full.rrPlanned            = openSnap.rr;
         full.emaFast              = openSnap.emaFast;
         full.emaSlow              = openSnap.emaSlow;
         full.rsi                  = openSnap.rsi;
         full.atr                  = openSnap.atr;
         full.momentum             = openSnap.momentum;
         full.trendState           = openSnap.trendState;
         full.volatilityState      = openSnap.volatilityState;
         full.nearestSupport       = openSnap.nearestSupport;
         full.nearestResistance    = openSnap.nearestResistance;
         full.distanceToSupport    = openSnap.distanceToSupport;
         full.distanceToResistance = openSnap.distanceToResistance;
         full.patternDescription   = openSnap.patternDescription;
         full.breakoutState        = openSnap.breakoutState;
         full.scoreBullish         = openSnap.scoreBullish;
         full.scoreBearish         = openSnap.scoreBearish;
         full.scoreThreshold       = openSnap.scoreThreshold;
         full.fibNearestLevel      = openSnap.fibNearestLevel;      // NOUVEAU
         full.fibDistancePoints    = openSnap.fibDistancePoints;    // NOUVEAU
         full.fibLegDirection      = openSnap.fibLegDirection;      // NOUVEAU
         full.structureEvent       = openSnap.structureEvent;       // NOUVEAU
         full.sweepZone            = openSnap.sweepZone;            // NOUVEAU
        }
      else
        {
         // Trade ouvert avant le démarrage de cette session de l'EA (ou
         // snapshot non retrouvé) - on restitue ce qu'on a, honnêtement,
         // plutôt que de fabriquer de fausses valeurs de contexte.
         full.entryTime          = rec.openTime;
         full.symbol             = rec.symbol;
         full.timeframe          = InpTF_Main;
         full.signalType         = rec.type;
         full.entryPrice         = rec.entryPrice;
         full.patternDescription = "Contexte d'ouverture indisponible (position ouverte avant le demarrage de cette session EA)";
        }

      bool hasLifecycle = g_tradeTracker.FillLifecycleData(rec.positionId, full);
      if(!hasLifecycle)
         g_logger.LogPipelineDebug(StringFormat("[ERROR]\r\nTracker introuvable pour PositionID=%I64u", rec.positionId));

      // NOUVEAU (Profit Guard) : copie des données avant libération de l'état.
      // profitGuardLastSource n'est plus stockée en interne (architecture
      // "décision unique" - chaque changement de mécanisme gagnant est déjà
      // journalisé individuellement dans TradeEvents.csv) ; on reconstitue
      // ici le meilleur résumé possible pour TradeFull.csv : le mécanisme le
      // plus représenté parmi NbModifSL_BreakEven/Trailing/ProfitGuard.
      bool hasGuardData = g_profitGuard.FillGuardData(rec.positionId, full.profitGuardArmed, full.profitGuardPeakProfitMoney);
      if(full.slModificationCountProfitGuard >= full.slModificationCountBreakEven &&
         full.slModificationCountProfitGuard >= full.slModificationCountTrailing && full.slModificationCountProfitGuard > 0)
         full.profitGuardLastSource = "ProfitGuard (voir TradeEvents.csv pour le detail exact par mecanisme)";
      else if(full.slModificationCountTrailing >= full.slModificationCountBreakEven && full.slModificationCountTrailing > 0)
         full.profitGuardLastSource = "Trailing (voir TradeEvents.csv pour le detail exact par mecanisme)";
      else if(full.slModificationCountBreakEven > 0)
         full.profitGuardLastSource = "BreakEven (voir TradeEvents.csv pour le detail exact par mecanisme)";
      else
         full.profitGuardLastSource = "Aucune modification";

      if(InpUseProfitGuard)
        {
         // NOUVEAU (demande explicite point 3) : mesure d'efficacité,
         // DOIT être appelée AVANT ReleaseTrade() qui efface l'état
         // (dont lastWinningIndex, nécessaire à ce calcul).
         g_profitGuard.RecordTradeClosed(rec.positionId, detailedReason, rec.profit);
         g_profitGuard.ReleaseTrade(rec.positionId);
        }

      // --- V3 - Squelette architectural (Sprint V3.0) ---
      // Point d'entree du Learning Engine, pose des maintenant pour que
      // les sprints suivants n'aient pas a retoucher ce pipeline. Sans
      // effet tant que InpV3_EnableLearningEngine=false (defaut) - voir
      // LearningEngine.mqh pour la dependance bloquante (persistance
      // TradeLifecycleTracker a reactiver avant le Sprint V3.8).
      g_learningEngine.OnTradeClosed(rec.positionId, rec.profit > 0.0);

      // --- V3 - Shadow Analytics (Sprint V3.6) ---
      // Cloture reelle du trade : on relie le resultat deja calcule par
      // le pipeline existant (rec.profit, hasSnapshot pour le RR) au
      // verdict Shadow deja lie a l'ouverture (LinkVerdict). Aucune
      // nouvelle lecture de marche, aucun recalcul - rrObtained reste a
      // 0.0 si le contexte d'ouverture est indisponible (position
      // survivante a un redemarrage), meme convention honnete que le
      // reste du projet plutot que d'inventer une valeur.
      double v3RrObtained = 0.0;
      if(hasSnapshot)
        {
         double v3RiskDistance = MathAbs(openSnap.slPrice - openSnap.entryPrice);
         if(v3RiskDistance > 0.0)
            v3RrObtained = MathAbs(rec.exitPrice - openSnap.entryPrice) / v3RiskDistance;
        }
      bool v3WasAuthorized = false;
      bool v3Linked = g_shadowAnalytics.LinkOutcome(rec.positionId, rec.profit > 0.0, rec.profit, v3RrObtained, v3WasAuthorized);
      if(InpDebugPipeline && v3Linked)
        {
         g_logger.LogInfo(StringFormat("[SHADOW_OUTCOME]\nTicket : %I64u\nVerdict : %s\nResultat reel : %s\nProfit : %.2f",
                          rec.positionId, v3WasAuthorized ? "AUTHORIZED" : "REFUSED",
                          (rec.profit > 0.0) ? "WIN" : "LOSS", rec.profit));
        }

      // --- Research Platform (Sprint V3.9.2, Increment I2) - capture ExecutionClose ---
      // Reprend, via le pont interne de CObservationLayer, le meme
      // correlationId que celui capture a l'ouverture (voir
      // ObservationLayer.mqh) - aucun recalcul, uniquement des valeurs
      // deja produites par le pipeline de cloture existant.
      g_observationLayer.CaptureExecutionClose(rec.positionId, rec.symbol, rec.exitPrice, rec.profit > 0.0, rec.profit, detailedReason);

      // --- Research Platform (Sprint V3.9.4, Increment I5) - capture Outcome (dernier evenement du trade) ---
      // "result" : convention explicite (voir ObservationLayer.mqh) -
      // WIN si profit net > 0, LOSS si < 0, BE si strictement egal a 0.
      // "swap"/"commission" lus directement depuis l'historique broker
      // deja consolide (meme primitive HistorySelectByPosition +
      // DEAL_SWAP/DEAL_COMMISSION deja utilisee par CPositionManager -
      // lecture, pas un recalcul de logique de trading). grossProfit
      // derive algebriquement de rec.profit (deja net = brut+swap+
      // commission, voir Types.mqh) - aucune nouvelle source de verite.
      double v3Swap = 0.0, v3Commission = 0.0;
      if(HistorySelectByPosition((long)rec.positionId))
        {
         int v3DealsTotal = HistoryDealsTotal();
         for(int v3d = 0; v3d < v3DealsTotal; v3d++)
           {
            ulong v3DealTicket = HistoryDealGetTicket(v3d);
            if(v3DealTicket == 0)
               continue;
            v3Swap       += HistoryDealGetDouble(v3DealTicket, DEAL_SWAP);
            v3Commission += HistoryDealGetDouble(v3DealTicket, DEAL_COMMISSION);
           }
        }
      double v3GrossProfit = rec.profit - v3Swap - v3Commission;
      string v3Result = (rec.profit > 0.0) ? "WIN" : ((rec.profit < 0.0) ? "LOSS" : "BE");

      g_observationLayer.CaptureOutcome(rec.positionId, rec.symbol, v3Result, v3GrossProfit, rec.profit,
                                        v3Swap, v3Commission, rec.durationSeconds, rec.mfe, rec.mae, rec.rr,
                                        detailedReason, rec.openTime, rec.closeTime);

      full.exitPrice           = rec.exitPrice;
      full.profitFinal         = rec.profit;
      full.closeTime           = rec.closeTime;
      full.durationSeconds     = rec.durationSeconds;
      full.closeReasonRaw      = rec.closeReason;
      full.closeReasonDetailed = detailedReason;
      full.captureRatioPercent = CTradeLifecycleTracker::ComputeCaptureRatio(full.mfeMoney, rec.profit);
      full.profitLeftOnTable   = CTradeLifecycleTracker::ComputeProfitLeftOnTable(full.mfeMoney, rec.profit);
      full.rrRealized          = rec.rr; // NOUVEAU - deja calcule par CPositionManager, jamais recopie jusqu'ici (oubli corrige)
      full.profitPercent       = CUtilities::SafeDivide(rec.profit, g_initialBalance, 0.0) * 100.0; // NOUVEAU

      // --- Timeline + événements chronologiques (AVANT ReleasePosition,
      // qui libère la mémoire du tracker pour ce trade) ---
      int eventCount = 0;
      if(hasLifecycle)
        {
         string timeline = g_tradeTracker.BuildTimelineSummary(rec.positionId);
         if(timeline != "")
            g_logger.LogInfo(timeline);

         eventCount = g_tradeTracker.GetEventCount(rec.positionId);

         if(eventCount == 0)
           {
            // CAS 1/3 : tracker retrouvé, mais aucun événement généré
            // (trade sans BreakEven/Trailing/PartialClose/News - légitime,
            // pas une erreur d'écriture).
            g_logger.LogPipelineDebug(StringFormat(
               "[EVENT CSV WRITE]\r\nPositionID=%I64u\r\nResult=SKIPPED\r\nReason=NoEventsGenerated\r\nFile=NexusEdgeEA_TradeEvents_v2.csv",
               rec.positionId));
           }
         else
           {
            // CAS 2/3 : des événements existent - on tente RÉELLEMENT
            // l'écriture et on rapporte le VRAI résultat de chacune.
            bool allEventsWritten = true;
            int  firstEventErrorCode = 0;
            for(int e = 0; e < eventCount; e++)
              {
               int evErrorCode = 0;
               bool evOk = g_logger.LogTradeEvent(g_tradeTracker.GetEvent(rec.positionId, e), evErrorCode);
               if(!evOk && allEventsWritten)
                 {
                  allEventsWritten    = false;
                  firstEventErrorCode = evErrorCode;
                 }
              }

            if(allEventsWritten)
               g_logger.LogPipelineDebug(StringFormat(
                  "[EVENT CSV WRITE]\r\nPositionID=%I64u\r\nResult=SUCCESS\r\nFile=NexusEdgeEA_TradeEvents_v2.csv\r\nevents_written=%d",
                  rec.positionId, eventCount));
            else
               g_logger.LogPipelineDebug(StringFormat(
                  "[EVENT CSV WRITE]\r\nPositionID=%I64u\r\nResult=FAILED\r\nErrorCode=%d\r\nFile=NexusEdgeEA_TradeEvents_v2.csv",
                  rec.positionId, firstEventErrorCode));
           }
        }
      else
        {
         // CAS 3/3 : tracker introuvable (déjà signalé par le bloc [ERROR]
         // ci-dessus) - on le redit ici explicitement dans le contexte de
         // l'écriture, pour que ce fichier seul suffise à comprendre pourquoi
         // TradeEvents_v2.csv n'a rien reçu pour ce trade.
         g_logger.LogPipelineDebug(StringFormat(
            "[EVENT CSV WRITE]\r\nPositionID=%I64u\r\nResult=SKIPPED\r\nReason=TrackerNotFound\r\nFile=NexusEdgeEA_TradeEvents_v2.csv",
            rec.positionId));
        }

      // NOUVEAU (correctif diagnostic) : [FINAL RECORD], juste avant l'écriture CSV
      g_logger.LogPipelineDebug(StringFormat(
         "[FINAL RECORD]\r\n\r\nticket=%I64u\r\nPositionID=%I64u\r\nprofit=%.2f\r\nRR=%.2f\r\nprofitPercent=%.2f\r\npartialCount=%d\r\nNbModifSL=%d\r\nNbModifSL_BreakEven=%d\r\nNbModifSL_Trailing=%d\r\neventsCount=%d",
         rec.positionId, rec.positionId, full.profitFinal, full.rrRealized, full.profitPercent, full.partialCloseCount,
         full.slModificationCount, full.slModificationCountBreakEven, full.slModificationCountTrailing, eventCount));

      int fullErrorCode = 0;
      bool fullWriteSuccess = g_logger.LogTradeFull(full, fullErrorCode);

      // NOUVEAU (correctif diagnostic) : [CSV WRITE] avec VRAI résultat
      if(fullWriteSuccess)
         g_logger.LogPipelineDebug(StringFormat(
            "[CSV WRITE]\r\nPositionID=%I64u\r\nResult=SUCCESS\r\nFile=NexusEdgeEA_TradeFull_v2.csv",
            rec.positionId));
      else
         g_logger.LogPipelineDebug(StringFormat(
            "[CSV WRITE]\r\nPositionID=%I64u\r\nResult=FAILED\r\nErrorCode=%d\r\nFile=NexusEdgeEA_TradeFull_v2.csv",
            rec.positionId, fullErrorCode));

      g_logger.LogTrade(rec.positionId, rec.symbol, rec.type, 0.0, rec.entryPrice, rec.exitPrice,
                        0.0, 0.0,
                        (rec.profit > 0.0) ? rec.profit : 0.0,
                        (rec.profit < 0.0) ? MathAbs(rec.profit) : 0.0,
                        "Cloture detectee via historique", rec.durationSeconds,
                        detailedReason, rec.mfe, rec.mae);

      DEBUG_TRADE(StringFormat("Trade cloture positionId=%I64u profit=%.2f raison='%s' captureRatio=%.1f%%",
                 rec.positionId, rec.profit, detailedReason, full.captureRatioPercent));

      // --- CDiagnostics (répartition existante + nouvelles métriques) ---
      string trendAtEntry, patternAtEntry, sessionAtEntry;
      FindAndRemoveOpenContext(rec.positionId, trendAtEntry, patternAtEntry, sessionAtEntry);

      g_diagnostics.RecordTradeClosed(rec.profit > 0.0, detailedReason, rec.mfe, rec.mae, rec.durationSeconds,
                                      rec.profit, CUtilities::SignalTypeToString(rec.type),
                                      trendAtEntry, patternAtEntry, sessionAtEntry,
                                      full.captureRatioPercent, full.timeInProfitSec, full.timeInLossSec,
                                      full.trailingActivatedTime > 0, full.breakEvenActivatedTime > 0,
                                      full.mfeMoney, full.maeMoney, hasLifecycle);

      // --- CPostCloseWatcher : suivre le marché après cette clôture ---
      if(InpTrackPostClose)
         g_postCloseWatcher.RegisterClosedTrade(rec.positionId, rec.symbol, rec.type, rec.exitPrice, rec.profit, rec.closeTime);

      // --- Libération du tracker pour ce trade (tout a déjà été lu) ---
      if(hasLifecycle)
         g_tradeTracker.ReleasePosition(rec.positionId, rec.profit);
      g_tradeHealthGuardian.ReleasePosition(rec.positionId); // NOUVEAU (V4.1-P3.3)
      // NOUVEAU : purge le throttle de modification pour ce ticket clôturé
      // (voir CTradeManager::ClearModifyTracking - évite une croissance
      // illimitée des tableaux internes sur un compte utilisé en continu).
      g_tradeManager.ClearModifyTracking(rec.positionId);
     }
   g_lastLoggedTradeCount = total;
  }

//+------------------------------------------------------------------+
//| Gère Break Even / Trailing / Partial Close sur toutes les        |
//| positions ouvertes sous ce Magic Number                           |
//|                                                                    |
//| MODIFIÉ (Phase 1) : AUCUNE ligne de logique de Break Even/        |
//| Trailing/Partial Close n'a été modifiée. Seuls des appels          |
//| d'OBSERVATION ont été ajoutés autour des appels existants à        |
//| CTradeManager (avant/après), pour que CTradeLifecycleTracker       |
//| puisse enregistrer ce qui s'est réellement passé - il ne déclenche|
//| et ne modifie jamais rien lui-même (voir sa philosophie en tête    |
//| de TradeLifecycleTracker.mqh).                                     |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   // --- Sprint PropFirm - Protection de portefeuille (AVANT toute
   // gestion par position - portefeuille entier, pas un trade individuel) ---
   if(InpUsePropFirmRiskGuard && g_propFirmRiskGuard.IsInitialized())
     {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      datetime serverTime   = TimeCurrent();
      datetime gmtTime      = TimeGMT();

      SPropFirmVerdict pfVerdict = g_propFirmRiskGuard.Evaluate(currentBalance, currentEquity, serverTime, gmtTime);

      if(pfVerdict.timezoneMismatchDetected)
         g_logger.LogError(pfVerdict.reason); // Avertissement seul - ne bloque rien

      if(pfVerdict.dailyLossBreached || pfVerdict.maxLossBreached)
        {
         if(!g_propFirmTradingBlocked) // Log uniquement au moment de la transition, pas a chaque tick
            g_logger.LogError(StringFormat(
               "[PROPFIRM_BREACH] %s | Equity=%.2f DailyFloor=%.2f MaxFloor=%.2f - FERMETURE DE TOUTES LES POSITIONS",
               pfVerdict.reason, pfVerdict.currentEquity, pfVerdict.dailyLossFloor, pfVerdict.maxLossFloor));

         g_propFirmTradingBlocked = true; // Flag DEDIE, jamais fusionne avec le disjoncteur legacy

         for(int p = PositionsTotal() - 1; p >= 0; p--)
           {
            ulong closeTicket = PositionGetTicket(p);
            if(closeTicket == 0)
               continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)
               continue;
            if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
               continue;
            g_tradeManager.ApplyExternalClose(closeTicket);
           }

         return; // COURT-CIRCUIT total - aucune gestion ProfitProtectionEngine ce tick
        }
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      // --- NOUVEAU (Phase 1) : mise à jour "vivante" (MFE/MAE $, temps
      // en gain/perte) - à CHAQUE tick, pour chaque position ouverte.
      // Le tracker ne lit rien lui-même : on lui transmet le profit
      // flottant actuel, déjà disponible ici.
      double currentProfitMoney = PositionGetDouble(POSITION_PROFIT);
      g_tradeTracker.Update(ticket, currentProfitMoney);

      // --- NOUVEAU : une annonce importante tombe-t-elle pendant que ce trade est ouvert ? ---
      string newsDetailNow;
      bool newsActiveNow = g_newsFilter.IsNewsBlockActive(newsDetailNow);
      if(newsActiveNow)
         g_tradeTracker.RecordNewsDuringTrade(ticket, newsDetailNow, currentProfitMoney);

      // --- NOUVEAU (Sprint 1 - Etape 1, correctif ISSUE 001/002) ---
      // Distance de prix favorable mesuree DIRECTEMENT sur le marche
      // (jamais reconstruite depuis un montant en devise) : c'est cette
      // grandeur, et uniquement elle, que CPeakPercentLevelCalculator et
      // CEmergencyLevelCalculator utilisent desormais pour placer un
      // niveau de SL - plus aucune dependance a tickValue/tickSize/lot
      // pour ce calcul (voir en-tete de ProfitProtectionEngine.mqh).
      ENUM_POSITION_TYPE posTypeGuard   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             openPriceGuard = PositionGetDouble(POSITION_PRICE_OPEN);
      double             currentPriceGuard = (posTypeGuard == POSITION_TYPE_BUY)
                                             ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                             : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double             currentFavorablePriceDistance = (posTypeGuard == POSITION_TYPE_BUY)
                                                         ? (currentPriceGuard - openPriceGuard)
                                                         : (openPriceGuard - currentPriceGuard);

      // --- V3 - Squelette architectural (Sprint V3.0/V3.1) ---
      // Evaluation en mode OBSERVATION SEULE, par position ouverte, a
      // chaque tick - meme cadence que ProfitProtectionEngine (pour
      // permettre une future comparaison tick a tick), mais sans
      // AUCUNE influence sur "posTypeGuard"/"currentFavorablePriceDistance"
      // ni sur ce qui suit. g_scenarioContext (V3.1) est le dernier
      // contexte observe a la cadence H1 (variable globale, mise a jour
      // dans le bloc nouvelle bougie) - relu ici en lecture seule, aucun
      // nouveau calcul. Aucun log par tick (verbeux) : seul le
      // compteur agrege est expose via GetShadowReport() a OnDeinit().
      SScenarioVerdict  v3MgmtVerdict;
      SScenarioDecision v3MgmtDecision;
      g_scenarioEngine.EvaluateManagement(ticket, g_scenarioContext, v3MgmtVerdict, v3MgmtDecision);

      // --- REFONTE "décision unique" (demande explicite, point 1) ---
      // BreakEven, Trailing et Profit Guard (Structure/PeakPercent/
      // Emergency) sont désormais des CALCULATEURS d'un seul et même
      // moteur (CProfitProtectionEngine). Une seule comparaison, un
      // seul appel ApplyExternalProtection() par tick - plus de blocs
      // if() séparés qui pourraient chacun tenter leur propre
      // modification.
      g_profitGuard.Update(ticket, currentProfitMoney, currentFavorablePriceDistance);

      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double atrNow     = g_indicators.GetATR(0);
      SMarketContext contextNow = g_marketContext.GetContext();

      // --- NOUVEAU (V4.1-P3.3) : mise a jour du Guardian, CHAQUE TICK.
      // currentFavorablePriceDistance deja calcule plus haut dans cette
      // boucle. TimeCurrent() est appele ICI par l'orchestrateur, jamais
      // a l'interieur de CTradeHealthGuardian (invariant 4).
      if(g_tradeHealthGuardian.IsTracked(ticket))
         g_tradeHealthGuardian.Update(ticket, currentFavorablePriceDistance, contextNow.momentum, TimeCurrent());

      double oldSLGuard    = PositionGetDouble(POSITION_SL);
      double currentTPGuard = PositionGetDouble(POSITION_TP);

      double finalSL; ENUM_PROTECTION_SOURCE source; string decisionNote; bool closeNow; string diagnosticTrace;
      bool hasCandidate = g_profitGuard.ComputeFinalStopLevel(ticket, oldSLGuard, currentTPGuard, currentProfitMoney,
                                                              g_marketStructure, atrNow, contextNow.momentum,
                                                              tickValue, tickSize,
                                                              finalSL, source, decisionNote, closeNow, diagnosticTrace,
                                                              currentFavorablePriceDistance);

      // NOUVEAU (mode diagnostic, demande explicite) : trace par tick,
      // écrite QUE si InpProfitGuardDiagnosticMode=true (sinon
      // diagnosticTrace reste vide et ce bloc ne coûte qu'une
      // comparaison de chaîne vide).
      if(diagnosticTrace != "")
         g_logger.LogPipelineDebug("[PROFIT GUARD DIAGNOSTIC]\r\n" + diagnosticTrace);

      if(hasCandidate)
        {
         bool guardApplied = g_profitGuard.ApplyProtection(g_tradeManager, ticket, currentTPGuard,
                                                           finalSL, closeNow, InpMinimumModifyIntervalSec);
         if(guardApplied)
           {
            string sourceLabel = CProfitProtectionEngine::SourceToString(source);
            g_profitGuard.RecordApplied(source); // NOUVEAU (demande explicite point 1) - distingue "retenu" d'"appliqué"
            if(closeNow)
              {
               DEBUG_TRADE(StringFormat("ProfitGuard URGENCE - fermeture immediate ticket=%I64u profit=%.2f", ticket, currentProfitMoney));
               g_logger.LogPipelineDebug(StringFormat("[TRADE EVENT]\r\nticket=%I64u\r\nevent_type=PROFIT_GUARD_EMERGENCY_CLOSE\r\nnote=%s\r\nevent_saved=true", ticket, decisionNote));

               // --- Research Platform (Sprint V3.9.4, Increment I4) - capture Protection (fermeture forcee) ---
               g_observationLayer.CaptureProtection(ticket, _Symbol, "FORCED_CLOSE", sourceLabel,
                                                    oldSLGuard, oldSLGuard, currentProfitMoney, decisionNote);
              }
            else
              {
               PositionSelectByTicket(ticket);
               double newSLGuard = PositionGetDouble(POSITION_SL);
               g_tradeTracker.RecordProtectionApplied(ticket, source, sourceLabel, oldSLGuard, newSLGuard, currentProfitMoney, decisionNote);
               DEBUG_TRAILING(StringFormat("Protection appliquee ticket=%I64u mecanisme=%s SL %.5f -> %.5f (profit=%.2f)",
                                           ticket, sourceLabel, oldSLGuard, newSLGuard, currentProfitMoney));

               // NOUVEAU (correctif diagnostic + traçabilité, demande explicite point 2)
               int nbModifSL, nbModifBE, nbModifTrail, nbModifPG;
               bool foundForCounts = g_tradeTracker.GetModifyCounts(ticket, nbModifSL, nbModifBE, nbModifTrail, nbModifPG);
               g_logger.LogPipelineDebug(StringFormat(
                  "[SL MODIFY]\r\nticket=%I64u\r\nPositionID=%I64u\r\nmecanisme_gagnant=%s\r\nold_SL=%.5f\r\nnew_SL=%.5f\r\nsuccess=true\r\n%s\r\n\r\nCounters:\r\nNbModifSL=%d\r\nNbModifSL_BreakEven=%d\r\nNbModifSL_Trailing=%d\r\nNbModifSL_ProfitGuard=%d",
                  ticket, ticket, sourceLabel, oldSLGuard, newSLGuard, decisionNote,
                  nbModifSL, nbModifBE, nbModifTrail, nbModifPG));
               g_logger.LogPipelineDebug(StringFormat(
                  "[TRADE EVENT]\r\nticket=%I64u\r\nevent_type=%s\r\nnote=%s\r\nevent_saved=%s",
                  ticket, sourceLabel, decisionNote, foundForCounts ? "true" : "false"));

               // --- Research Platform (Sprint V3.9.4, Increment I4) - capture Protection (SL modifie) ---
               g_observationLayer.CaptureProtection(ticket, _Symbol, "SL_MODIFIED", sourceLabel,
                                                    oldSLGuard, newSLGuard, currentProfitMoney, decisionNote);
              }
           }
        }

      if(InpUsePartialClose && !AlreadyPartiallyClosed(ticket))
        {
         // Déclenchement heuristique : profit >= 2x le seuil de Break
         // Even. Ajustable ici si besoin d'un input dédié plus tard.
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPoints = (posType == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / point : (openPrice - currentPrice) / point;

         if(profitPoints >= InpBreakEvenTriggerPts * 2.0)
           {
            if(g_tradeManager.PartialClose(ticket, InpPartialClosePercent))
              {
               MarkPartiallyClosed(ticket);
               // NOTE : CTradeManager::PartialClose() ne retourne pas le
               // volume exact exécuté - on enregistre donc le pourcentage
               // DEMANDÉ (InpPartialClosePercent), pas le volume réel en
               // lots. Documenté ici pour éviter toute fausse précision.
               double profitNow = PositionGetDouble(POSITION_PROFIT);
               g_tradeTracker.RecordPartialClose(ticket, InpPartialClosePercent, profitNow);
               DEBUG_TRADE(StringFormat("Fermeture partielle ticket=%I64u pourcentage_demande=%.0f%%", ticket, InpPartialClosePercent));

               // --- Research Platform (Sprint V3.9.4, Increment I4) - capture Protection (cloture partielle) ---
               // Pas de changement de SL ici - oldSL/newSL identiques,
               // le pourcentage demande est porte par "decisionNote"
               // (le contrat CaptureProtection ne prevoit pas de champ
               // dedie, conformement au principe "aucune donnee inutile"
               // deja applique a chaque champ de ce projet).
               double currentSLForPartial = PositionGetDouble(POSITION_SL);
               g_observationLayer.CaptureProtection(ticket, _Symbol, "PARTIAL_CLOSE", "PartialClose",
                                                    currentSLForPartial, currentSLForPartial, profitNow,
                                                    StringFormat("pourcentage_demande=%.0f%%", InpPartialClosePercent));
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| ResyncSurvivingPositions                                            |
//|                                                                    |
//| NOUVEAU (correctif prioritaire, angle mort identifie par revue     |
//| d'architecture du 2026-07-23, avant la poursuite du Sprint 1).     |
//|                                                                    |
//| PROBLEME : g_profitGuard.RegisterTrade() n'etait appele qu'au      |
//| moment de OpenPosition() (un seul site d'appel dans tout ce        |
//| fichier). Si l'EA redemarre (VPS reboot, mise a jour Windows,      |
//| recompilation, crash terminal) pendant qu'un trade est ouvert, ce  |
//| trade devenait invisible pour CProfitProtectionEngine :            |
//| ComputeFinalStopLevel() retourne false des sa toute premiere ligne |
//| (FindIndex(positionId) < 0) - AVANT MEME d'evaluer BreakEven ou    |
//| Trailing, qui pourtant n'ont besoin d'aucun etat stocke. Un trade  |
//| survivant a un redemarrage perdait donc TOUTE protection active    |
//| jusqu'a sa cloture manuelle.                                       |
//|                                                                    |
//| CORRECTIF : au demarrage, apres g_profitGuard.Init(), on scanne    |
//| les positions deja ouvertes sous notre symbole/Magic Number et on  |
//| les reenregistre - reutilisation PURE de RegisterTrade()/Update(), |
//| deja publiques et deja appelees ailleurs avec la meme signature.   |
//| Aucune nouvelle methode, aucune nouvelle interface, aucune         |
//| modification de ProfitProtectionEngine.mqh.                        |
//|                                                                    |
//| LIMITE HONNETE DOCUMENTEE : le SL INITIAL (utilise pour calculer   |
//| riskMoneyPerR, donc le mode d'armement ACTIVATION_BY_R) n'est      |
//| persiste nulle part ailleurs dans le projet - seul le SL COURANT   |
//| est visible sur la position au redemarrage (potentiellement deja   |
//| deplace par BreakEven/Trailing avant l'arret). On utilise donc le  |
//| SL courant comme approximation du SL initial : c'est la meilleure  |
//| information disponible sans persistance dediee (voir echange sur   |
//| la persistance de l'apprentissage broker - le meme mecanisme       |
//| pourra un jour couvrir aussi l'etat des trades). De la meme facon, |
//| le PeakProfit / la distance de prix favorable au plus haut ne      |
//| peuvent pas etre reconstruits avec certitude (un retracement       |
//| survenu avant le redemarrage est invisible) : on amorce donc le    |
//| pic au NIVEAU COURANT (borne inferieure honnete), jamais a zero -   |
//| strictement meilleur que l'absence totale de protection observee   |
//| jusqu'ici.                                                          |
//|                                                                    |
//| PERIMETRE : ne couvre que CProfitProtectionEngine (le risque       |
//| financier direct, prioritaire). CTradeLifecycleTracker::           |
//| RegisterNewPosition() presente le meme angle mort (MFE/MAE         |
//| reinitialises), mais necessite un STradeSnapshot complet (contexte |
//| marche a l'entree, non reconstructible avec certitude) - laisse    |
//| volontairement de cote pour une etape dediee ulterieure,           |
//| conformement a la discipline "une etape a la fois".                 |
//+------------------------------------------------------------------+
void ResyncSurvivingPositions()
  {
   int resynced = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(g_profitGuard.IsTracked(ticket))
         continue; // Deja suivi - ne devrait jamais se produire a ce stade de OnInit, garde-fou defensif

      ENUM_POSITION_TYPE posType    = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      ENUM_SIGNAL_TYPE   signalType = (posType == POSITION_TYPE_BUY) ? SIGNAL_BUY : SIGNAL_SELL;
      double entryPrice      = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSLApprox = PositionGetDouble(POSITION_SL); // Approximation honnete - voir limite documentee ci-dessus
      double lot             = PositionGetDouble(POSITION_VOLUME);
      double tickValue       = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize        = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      g_profitGuard.RegisterTrade(ticket, signalType, entryPrice, currentSLApprox, lot, tickValue, tickSize);

      // Amorce immediate du pic avec l'etat COURANT (borne inferieure honnete,
      // jamais zero) - meme formule que ManageOpenPositions() pour la distance
      // de prix favorable (voir Sprint 1 - Etape 1, ISSUE 001/002).
      double currentProfitMoney = PositionGetDouble(POSITION_PROFIT);
      double currentPriceNow    = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currentFavorablePriceDistance = (posType == POSITION_TYPE_BUY) ? (currentPriceNow - entryPrice) : (entryPrice - currentPriceNow);
      g_profitGuard.Update(ticket, currentProfitMoney, currentFavorablePriceDistance);

      resynced++;
     }

   if(resynced > 0)
      g_logger.LogSystemEvent("Resync", StringFormat(
         "%d position(s) deja ouverte(s) reenregistree(s) aupres du Profit Protection Engine apres (re)demarrage de l'EA "
         "(SL initial et PeakProfit approximes a partir de l'etat courant - voir limite documentee dans le code)", resynced));
  }

//+------------------------------------------------------------------+
//| OnInit                                                              |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!g_logger.Init(InpLogLevel, "NexusEdgeEA", InpEnableDebugPipelineTxt))
     {
      Print("Échec initialisation CLogger");
      return(INIT_FAILED);
     }

   // NOUVEAU (Phase 1) : CDebug s'appuie sur le logger déjà initialisé.
   CDebug::Init(&g_logger, InpDebugTrade, InpDebugSignal, InpDebugTrailing, InpDebugStats);

   if(!g_indicators.Init(_Symbol, InpTF_Main, InpEMA_Fast, InpEMA_Medium, InpEMA_Slow, InpEMA_Trend,
                         InpRSI_Period, InpATR_Period, InpADX_Period, InpBB_Period, InpBB_Deviation))
     {
      g_logger.LogError("Échec initialisation CIndicators");
      return(INIT_FAILED);
     }

   if(!g_marketContext.Init(&g_indicators, _Symbol, InpTF_Main,
                            InpADX_TrendThreshold, InpADX_RangeThreshold,
                            InpATR_MinPoints, InpATR_MaxPoints))
     {
      g_logger.LogError("Échec initialisation CMarketContext");
      return(INIT_FAILED);
     }

   g_patterns.Init(_Symbol, InpTF_Main);
   g_supportResistance.Init(_Symbol, InpTF_Main, InpSR_LookbackBars, InpSR_SwingStrength, InpSR_ZoneMergeDistancePoints);
   g_marketStructure.Init(_Symbol, InpTF_Main, InpStructure_SwingStrength, InpStructure_LookbackBars);
   g_structureObserver.Init(GetPointer(g_marketStructure)); // NOUVEAU (V3.1) - couche d'observation, pas le TSE (voir §3.3bis)
   g_orderBlockDetector.Init(GetPointer(g_marketStructure), _Symbol, InpTF_Main); // NOUVEAU (V3.2A) - idem
   g_fvgDetector.Init(_Symbol, InpTF_Main); // NOUVEAU (V3.2B) - pas de pointeur CMarketStructure, volontairement (voir FVGDetector.mqh)

   // --- V3 - HTF Bias Observer (Sprint V3.3) ---
   // g_marketStructureHTF est une instance INDEPENDANTE (Option A) -
   // memes parametres de swing que l'instance H1, uniquement le
   // timeframe change. Aucun conflit d'etat possible (verifie :
   // CMarketStructure ne contient aucun membre statique).
   g_marketStructureHTF.Init(_Symbol, InpTF_High, InpStructure_SwingStrength, InpStructure_LookbackBars);
   g_htfBiasObserver.Init(GetPointer(g_marketStructureHTF), InpTF_High);
   
   // --- V4.1-P3 - Opportunity Pipeline (Shadow) ---
   // Meme discipline que le reste du squelette V3 : initialisation
   // inconditionnelle, aucune autorite reelle (aucun appel a
   // g_opportunityManager/g_opportunityPipeline ne modifie jamais une
   // position - voir OpportunityPipeline.mqh, "AUCUNE DECISION DE TRADING").
   g_opportunityManager.Init(InpOpportunityMaxAgeBars);
   g_opportunitySourceSMC.Init();
   g_opportunityPipeline.Init();
   g_virtualTradeTracker.Init(InpVirtualTradeMaxAgeBars);
   g_tradeHealthGuardian.Init(InpTradeHealthProtectionGivebackRatio, InpTradeHealthDefenseActiveGivebackRatio);

   // --- Sprint PropFirm - Protection de portefeuille FTMO ---
   // Garde-fou : si le capital initial n'est pas configure (0.0 par
   // defaut), le guard reste inactif plutot que de calculer des
   // planchers a partir d'une valeur non renseignee (invariant 8 :
   // aucune donnee fabriquee).
   if(InpUsePropFirmRiskGuard && InpFTMOInitialCapital > 0.0)
     {
      g_propFirmRiskGuard.Init(InpFTMOInitialCapital, InpFTMODailyLossPercent, InpFTMOMaxLossPercent,
                               InpFTMOBrokerGMTOffsetHours, (InpFTMOBrokerGMTOffsetHours != 0.0 || InpFTMOUseManualGMTOffset),
                               InpFTMOUseManualGMTOffset);
      g_logger.LogInfo(StringFormat("[PROPFIRM] Guard active - Capital=%.2f DailyLoss=%.1f%% MaxLoss=%.1f%%",
                       InpFTMOInitialCapital, InpFTMODailyLossPercent, InpFTMOMaxLossPercent));
     }
   else if(InpUsePropFirmRiskGuard && InpFTMOInitialCapital <= 0.0)
     {
      g_logger.LogError("[PROPFIRM] InpUsePropFirmRiskGuard=true mais InpFTMOInitialCapital non configure (0.0) - Guard INACTIF par securite");
     }

   ENUM_NEWS_SOURCE newsSource = InpNewsFilterEnabled ? NEWS_SOURCE_NATIVE_CALENDAR : NEWS_SOURCE_NONE;
   if(!g_newsFilter.Init(newsSource, InpNewsMinutesBefore, InpNewsMinutesAfter, NEWS_IMPORTANCE_HIGH))
      g_logger.LogError("Échec initialisation CNewsFilter (le trading continuera sans filtre de news)");

   if(!g_filters.Init(&g_sessions, &g_newsFilter, InpMaxSpreadPoints, InpMaxDrawdownPercent,
                      InpATR_MinPoints, InpATR_MaxPoints))
     {
      g_logger.LogError("Échec initialisation CFilters");
      return(INIT_FAILED);
     }

   if(!g_signalManager.Init(&g_indicators, &g_marketContext, &g_patterns, &g_supportResistance,
                            _Symbol, InpTF_Main, GetScoreWeights(), InpScore_Threshold, InpSignal_ZoneTolerancePoints))
     {
      g_logger.LogError("Échec initialisation CSignalManager");
      return(INIT_FAILED);
     }

   if(!g_riskManager.Init(&g_indicators, &g_supportResistance, _Symbol, InpTF_Main,
                          InpSL_Method, InpSL_ATR_Multiplier, InpTP_Method, InpTP_RR_Ratio, InpTP_ATR_Multiplier,
                          InpRisk_SwingLookbackBars, InpRisk_ZoneBufferPoints))
     {
      g_logger.LogError("Échec initialisation CRiskManager");
      return(INIT_FAILED);
     }

   g_tradeManager.Init(_Symbol, InpMagicNumber, InpTradeComment);
   g_positionManager.Init(_Symbol, InpTF_Main, InpMagicNumber);

   // NOUVEAU (Phase 1)
   g_tradeTracker.Init(InpTrackTradeLifecycle);
   g_postCloseWatcher.Init(InpTrackPostClose);

   // NOUVEAU (Profit Guard) - REFONTE "décision unique" : construit
   // désormais BreakEven et Trailing comme calculateurs du même moteur
   // (plus d'appels séparés dans ManageOpenPositions).
   g_profitGuard.Init(GetPointer(g_tradeManager), GetPointer(g_marketStructure),
                      InpUseBreakEven, InpBreakEvenTriggerPts, 20.0,
                      InpUseTrailingATR, InpUseTrailingStop,
                      InpTrailingStartPts, InpTrailingStopPts, InpTrailingStepPts, InpSL_ATR_Multiplier,
                      InpUseProfitGuard,
                      InpProfitGuardActivationMode, InpProfitGuardActivationR, InpProfitGuardActivationMoney,
                      InpProfitGuardStructureBufferATR, InpProfitGuardMinRetainPercent,
                      InpProfitGuardEmergencyEnabled, InpProfitGuardEmergencyDrawdownPercent,
                      InpProfitGuardEmergencyMomentumThreshold, InpProfitGuardEmergencyCloseImmediately,
                      InpProfitGuardEmergencyRetainPercent, InpProfitGuardDiagnosticMode,
                      GetPointer(g_tradeHealthGuardian), InpUseDefenseActive,
                      InpDefenseActiveProtectionRetainPercent, InpDefenseActiveDefenseActiveRetainPercent);

   // NOUVEAU (correctif prioritaire - voir doc complete sur ResyncSurvivingPositions()
   // ci-dessus) : reenregistre aupres du Profit Guard toute position deja ouverte
   // au moment ou l'EA demarre/redemarre - sans quoi ces trades perdaient toute
   // protection active (BreakEven/Trailing inclus) jusqu'a leur cloture manuelle.
   ResyncSurvivingPositions();

   // --- V3 - Squelette architectural (Sprint V3.0) ---
   // Initialisation des coquilles - aucune n'a d'autorite reelle a ce
   // stade (voir ARCHITECTURE_V3.md). Les Feature Flags sont transmis
   // tels quels : par defaut tous a false, donc aucun changement de
   // comportement par rapport a la version actuelle.
   // AJUSTEMENT POST-REVUE V3.0 : le TSE ne recoit plus de pointeur
   // vers un module de marche (voir TradeScenarioEngine.mqh, direction
   // SScenarioContext) - uniquement les Feature Flags, qui sont de la
   // configuration.
   g_scenarioEngine.Init(InpV3_EnableTradeScenarioEngine, InpV3_EnableHTFBias,
                         InpV3_EnableStructuralManagement);
   g_hardRiskGuard.Init();
   g_learningEngine.Init(InpV3_EnableLearningEngine);

   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_statistics.Init(&g_positionManager, g_initialBalance);

   // --- V3.6.5 - Account Metrics Layer (correctif du verrouillage drawdown) ---
   // Reconstruit le pic d'equite reel via CUtilities::ReconstructPeakEquity()
   // (fonction statique pure, aucune dependance metier) - une seule fois,
   // ici, puis le composant devient totalement autonome (voir AccountMetrics.mqh).
   g_accountMetrics.Init(g_initialBalance, _Symbol, InpMagicNumber);

   // --- Research Platform (Sprint V3.9.2, Increment I2) ---
   // Fichier dedie, distinct de TradeFull.csv/TradeEvents.csv (voir
   // blueprint V3.8.2). Nom fixe par magic number pour eviter toute
   // collision entre executions (meme prudence que CPositionManager).
   // Sprint V3.9.3.5 : extension .jsonl (JSON Lines), la Research Data
   // Layer a migre son format de stockage - contrat SResearchEvent et
   // contenu des evenements inchanges, seule la representation disque
   // change (voir ResearchDataLayer.mqh).
   string v3ResearchFileName = StringFormat("NexusEdgeEA_Research_%s_%d.jsonl", _Symbol, InpMagicNumber);
   g_researchDataLayer.Init(v3ResearchFileName);
   g_observationLayer.Init(GetPointer(g_researchDataLayer), InpEnableResearchCapture,
                           "AUREX_TSE_V1", IntegerToString((long)InpMagicNumber));

   g_dashboard.Init(InpDashboardX, InpDashboardY, InpShowDashboard);

   if(InpLogAllSignals)
      g_signalRecorder.Init(_Symbol, InpTF_Main, InpSignalReviewBars1, InpSignalReviewBars2, InpSignalReviewBars3);

   g_diagnostics.Init(InpDiagnosticsEnabled);

   RefreshDailyStateIfNeeded();

   g_logger.LogInfo(StringFormat("%s v%s initialisé sur %s (TF principal=%s)",
                                 EA_NAME, EA_VERSION, _Symbol, EnumToString(InpTF_Main)));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_logger.LogInfo(StringFormat("Arrêt de %s (raison=%d)", EA_NAME, reason));
   g_logger.LogInfo(g_statistics.GenerateReport());
   g_logger.LogInfo(g_signalManager.GetContributionReport());
   g_logger.LogInfo(g_diagnostics.GenerateReport());
   g_logger.LogInfo(g_profitGuard.GetActivationReport()); // NOUVEAU (demande explicite point 1)
   g_logger.LogInfo(g_tradeManager.GetBrokerConstraintReport()); // NOUVEAU (Sprint 1 - refus broker)
   // --- V3 - Squelette architectural (Sprint V3.0) ---
   g_logger.LogInfo(g_scenarioEngine.GetShadowReport());
   g_logger.LogInfo(g_scenarioEngine.GetOpportunityShadowReport()); // NOUVEAU (V4.1-P3) - Pipeline B, independant du Pipeline A ci-dessus
   g_logger.LogInfo(g_virtualTradeTracker.GetSummaryReport()); // NOUVEAU (V4.1-P3.1bis) - resultats virtuels du Pipeline B
   g_logger.LogInfo(g_shadowAnalytics.GetReport()); // NOUVEAU (V3.6)
   g_logger.LogInfo(g_hardRiskGuard.GetShadowReport());
   g_logger.LogInfo(g_learningEngine.GetShadowReport());

   g_dashboard.Deinit();
   g_signalRecorder.Deinit();
   g_indicators.Deinit();
   g_logger.Deinit();
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction                                                  |
//|                                                                    |
//| NOUVEAU (CORRECTIF - cause racine des fichiers TradeEvents.csv et |
//| TradeFull.csv vides ou incomplets).                                |
//|                                                                    |
//| DIAGNOSTIC CONFIRMÉ : g_positionManager.Update() et                |
//| LogNewlyClosedTrades() n'étaient appelés QUE dans OnTick(), APRÈS  |
//| le filtre "if(!CUtilities::IsNewBar(...)) return;". Ce filtre est |
//| volontairement là pour l'ANALYSE DE SIGNAL (ne jamais analyser à  |
//| chaque tick, conformément à la philosophie du robot) - mais la    |
//| DÉTECTION DE CLÔTURE d'un trade s'y trouvait accrochée par erreur.|
//| Résultat concret : un trade ouvert et fermé entre deux bougies H1 |
//| (ex: fermé en 3,6 secondes par le Trailing, comme observé en live) |
//| n'était journalisé qu'à l'ouverture de la PROCHAINE bougie H1 -   |
//| jusqu'à 59 minutes plus tard. Si l'EA était arrêté avant cette     |
//| échéance (test court), le trade n'était JAMAIS journalisé : les   |
//| fichiers TradeEvents/TradeFull restaient vides ou incomplets.      |
//|                                                                    |
//| CORRECTIF : OnTradeTransaction() est l'événement natif MT5 déclenché|
//| IMMÉDIATEMENT par le serveur à chaque changement réel (ouverture,  |
//| modification, clôture). On y détecte spécifiquement l'ajout d'un   |
//| deal de SORTIE (DEAL_ENTRY_OUT / DEAL_ENTRY_OUT_BY) et on déclenche |
//| aussitôt la même synchronisation + journalisation qu'avant -       |
//| aucune logique de détection/calcul n'est dupliquée, seul le        |
//| DÉCLENCHEUR change (événement au lieu d'attente de bougie).         |
//| L'appel existant dans OnTick() à la nouvelle bougie est CONSERVÉ   |
//| comme filet de sécurité (rattrape tout ce qui aurait pu être       |
//| manqué, ex: redémarrage de l'EA).                                   |
//|                                                                    |
//| AUCUNE logique de trading n'est modifiée ici - uniquement le       |
//| DÉCLENCHEUR du système de journalisation, conformément à la         |
//| demande explicite ("uniquement le système de journalisation").     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return; // On ne réagit qu'à l'ajout effectif d'un deal (ouverture ou clôture confirmée par le broker)

   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return; // Deal d'ENTRÉE (ouverture) : rien à journaliser ici, déjà fait au moment de OpenPosition()

   // Synchronisation + journalisation IMMÉDIATE, sans attendre la bougie H1.
   g_positionManager.Update();
   LogNewlyClosedTrades();
  }

//+------------------------------------------------------------------+
//| OnTick                                                              |
//| Analyse UNIQUEMENT à l'ouverture d'une nouvelle bougie du         |
//| timeframe principal.                                               |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- V3.6.5 - Account Metrics Layer ---
   // Une seule lecture d'equite, une seule comparaison - avant TOUTE
   // autre logique du tick, y compris ManageOpenPositions(). Voir
   // AccountMetrics.mqh pour la justification de cette cadence.
   g_accountMetrics.Update();

   // Gestion des positions ouvertes (Break Even/Trailing/Partial) :
   // peut s'exécuter à chaque tick, contrairement à l'analyse de
   // signal, car réagir vite au prix est justement le but ici.
   ManageOpenPositions();
   
   // --- V4.1-P3 - Opportunity Pipeline (Shadow uniquement, AUCUN trade) ---
   // Cadence : chaque tick (verrou P2B). bid/ask transmis en parametre -
   // EvaluatePrice() choisit lui-meme Ask (BUY) ou Bid (SELL), voir P1
   // Revision 2 dans OpportunityManager.mqh.
   double v4OppBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double v4OppAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   g_opportunityManager.EvaluatePrice(_Symbol, v4OppBid, v4OppAsk);

   SOpportunityDispatchResult v4OppResults[];
   int v4OppDispatchedCount = g_opportunityPipeline.ProcessTick(g_opportunityManager, g_scenarioEngine,
                                                                 g_scenarioContext, v4OppResults);
   if(v4OppDispatchedCount > 0)
     {
      for(int v4i = 0; v4i < ArraySize(v4OppResults); v4i++)
        {
         if(InpDebugPipeline)
            g_logger.LogInfo(StringFormat(
               "[OPPORTUNITY_SHADOW]\nOpportunity #%s (%s, motif=%s)\nZone : [%.5f - %.5f]\nVerdict : %s (confidence=%.2f)\nDetail : %s",
               v4OppResults[v4i].candidate.id, v4OppResults[v4i].candidate.sourceType,
               v4OppResults[v4i].candidate.creationReason,
               v4OppResults[v4i].candidate.zoneLow, v4OppResults[v4i].candidate.zoneHigh,
               v4OppResults[v4i].verdict.authorized ? "ACCEPTED" : "REJECTED",
               v4OppResults[v4i].verdict.confidence, v4OppResults[v4i].verdict.reason));

         // --- V4.1-P3.1bis - VirtualTradeFeed (Niveau 1 strict) ---
         // Appele pour CHAQUE verdict (Authorized ET Refused) - c'est
         // precisement ce qui permettra en P3.2 de savoir si les refus
         // du TSE etaient justifies. entryScore recupere gratuitement
         // (verdict.confidence deja calcule), currentScore non alimente
         // dans cette premiere integration (voir section 6 ci-dessous).
         string v4VtId = CVirtualTradeFeed::OnVerdict(v4OppResults[v4i].candidate, v4OppResults[v4i].verdict,
                                                       g_lastBarIndex, g_riskManager, g_virtualTradeTracker);
         if(InpDebugPipeline && v4VtId != "")
            g_logger.LogInfo(StringFormat("[VIRTUAL_TRADE_REGISTERED] id=%s opportunity=%s verdict=%s",
                             v4VtId, v4OppResults[v4i].candidate.id,
                             v4OppResults[v4i].verdict.authorized ? "ACCEPTED" : "REJECTED"));
        }
     }

   // NOUVEAU (Phase 1) : CPostCloseWatcher également à chaque tick -
   // opération légère (comparaisons de datetime sur une petite liste),
   // nécessaire pour la granularité de sa fenêtre la plus courte (5 min).
   if(InpTrackPostClose)
     {
      g_postCloseWatcher.Update();
      SPostCloseReview review;
      while(g_postCloseWatcher.PopCompletedReview(review))
         g_logger.LogPostCloseReview(review);
     }

   if(!CUtilities::IsNewBar(_Symbol, InpTF_Main))
      return;

   RefreshDailyStateIfNeeded();
   g_lastBarIndex = Bars(_Symbol, InpTF_Main); // NOUVEAU (V4.1-P3) - calcule ICI, injecte partout ailleurs (invariant 4)
   g_diagnostics.RecordBarAnalyzed();

   g_positionManager.Update();
   LogNewlyClosedTrades();
   if(InpLogAllSignals)
      g_signalRecorder.Update();

   g_marketContext.Update();
   g_supportResistance.Update();
   g_marketStructure.Update(1); // NOUVEAU - meme cadence que MarketContext/SupportResistance

   // --- V3 - Couche d'observation structurelle (Sprint V3.1) ---
   // Meme cadence que g_marketStructure.Update() ci-dessus (une fois par
   // nouvelle bougie H1) - AUCUN nouveau calcul, uniquement la lecture
   // de l'etat deja produit par CMarketStructure. Remplit g_scenarioContext
   // (lu en lecture seule plus loin par les appels shadow du TSE) et
   // journalise les transitions BOS/CHOCH/Sweep derriere InpDebugPipeline
   // (pas de nouveau Feature Flag - ce sprint ne modifie aucune decision).
   string v3StructureLogText; bool v3HasNewStructureEvent;
   g_structureObserver.Observe(1, g_scenarioContext, v3StructureLogText, v3HasNewStructureEvent);
   if(InpDebugPipeline && v3StructureLogText != "")
      g_logger.LogInfo(v3StructureLogText);

   // --- V3 - Détecteur d'Order Block (Sprint V3.2A) ---
   // Même cadence, même discipline que ci-dessus. Ne recalcule jamais
   // BOS/CHOCH - consomme exclusivement l'état déjà lu par
   // g_marketStructure (voir ARCHITECTURE_V3.md, précision V3.2A).
   // Appelé APRÈS g_structureObserver.Observe() : g_scenarioContext
   // contient déjà les champs BOS/CHOCH/Sweep à jour de cette bougie
   // avant que ce détecteur n'y ajoute les champs Order Block.
   string v3OrderBlockLogText; bool v3HasNewOrderBlockEvent;
   g_orderBlockDetector.Observe(1, g_scenarioContext, v3OrderBlockLogText, v3HasNewOrderBlockEvent);
   if(InpDebugPipeline && v3OrderBlockLogText != "")
      g_logger.LogInfo(v3OrderBlockLogText);
      
   // --- V4.1-P3 - Pont SMC -> Opportunity (Order Block) ---
   // Lit exclusivement g_scenarioContext deja rempli ci-dessus - aucun
   // recalcul. creationReason="BOS" strictement (voir OpportunitySourceSMC.mqh).
   string v4OppIdFromOB = g_opportunitySourceSMC.IngestOrderBlock(g_scenarioContext, _Symbol, g_lastBarIndex, g_opportunityManager);
   if(InpDebugPipeline && v4OppIdFromOB != "")
      g_logger.LogInfo(StringFormat("[OPPORTUNITY_CREATED] id=%s source=OrderBlock reason=BOS", v4OppIdFromOB));

   // --- V3 - Détecteur de Fair Value Gap (Sprint V3.2B) ---
   // Même cadence que les détecteurs précédents. NE consulte PAS
   // g_marketStructure (géométrie locale à 3 bougies, indépendante de
   // toute structure - voir FVGDetector.mqh). Appelé APRÈS
   // g_orderBlockDetector.Observe() : g_scenarioContext contient déjà
   // les champs BOS/CHOCH/Sweep/Order Block à jour avant que ce
   // détecteur n'y ajoute les champs FVG.
   string v3FvgLogText; bool v3HasNewFvgEvent;
   g_fvgDetector.Observe(1, g_scenarioContext, v3FvgLogText, v3HasNewFvgEvent);
   if(InpDebugPipeline && v3FvgLogText != "")
      g_logger.LogInfo(v3FvgLogText);
      
   // --- V4.1-P3 - Pont SMC -> Opportunity (FVG) ---
   // creationReason="FVG" strictement, jamais correle a BOS/CHOCH/Sweep
   // meme si ces champs sont renseignes dans g_scenarioContext au meme
   // instant (voir OpportunitySourceSMC.mqh, decision de revue P2A).
   string v4OppIdFromFVG = g_opportunitySourceSMC.IngestFVG(g_scenarioContext, _Symbol, g_lastBarIndex, g_opportunityManager);
   if(InpDebugPipeline && v4OppIdFromFVG != "")
      g_logger.LogInfo(StringFormat("[OPPORTUNITY_CREATED] id=%s source=FVG reason=FVG", v4OppIdFromFVG));

   // --- V4.1-P3 - Politique d'expiration (bougies, voir P1 Revision 1) ---
   int v4OppExpiredCount = g_opportunityManager.UpdateExpiration(g_lastBarIndex);
   if(InpDebugPipeline && v4OppExpiredCount > 0)
      g_logger.LogInfo(StringFormat("[OPPORTUNITY_EXPIRED] count=%d (politique=%d bougies)", v4OppExpiredCount, InpOpportunityMaxAgeBars));
    
   // --- V4.1-P3.1bis - Mise a jour des trades virtuels OPEN (Niveau 1) ---
   // High/Low de la bougie qui vient de cloturer (shift=1, meme
   // convention que le reste du bloc "nouvelle bougie"). Ne lit jamais
   // le marche a l'interieur de VirtualTradeTracker lui-meme -
   // High/Low/barIndex sont injectes ICI (invariant 4).
   double v4VtBarHigh = iHigh(_Symbol, InpTF_Main, 1);
   double v4VtBarLow  = iLow(_Symbol, InpTF_Main, 1);
   int v4VtTotal = g_virtualTradeTracker.GetCount();
   for(int v4vt = v4VtTotal - 1; v4vt >= 0; v4vt--)
     {
      SVirtualTrade v4VtRecord = g_virtualTradeTracker.GetRecord(v4vt);
      if(v4VtRecord.state != VIRTUAL_TRADE_OPEN)
         continue;
      g_virtualTradeTracker.UpdateBar(v4VtRecord.id, v4VtBarHigh, v4VtBarLow, g_lastBarIndex);
     }

   int v4VtTimedOutCount = g_virtualTradeTracker.CheckTimeouts(g_lastBarIndex);
   if(InpDebugPipeline && v4VtTimedOutCount > 0)
      g_logger.LogInfo(StringFormat("[VIRTUAL_TRADE_TIMEOUT] count=%d (politique=%d bougies)", v4VtTimedOutCount, InpVirtualTradeMaxAgeBars));
   // --- V3 - HTF Bias Observer (Sprint V3.3) ---
   // CADENCE STRICTE : ce bloc ne s'exécute QUE si une nouvelle bougie
   // InpTF_High vient de clôturer - jamais à chaque tick, jamais à
   // chaque bougie H1 (contrairement aux observateurs précédents qui
   // tournent à la cadence H1). g_marketStructureHTF n'est mise à jour
   // que dans ce bloc, donc au rythme de InpTF_High uniquement.
   if(CUtilities::IsNewBar(_Symbol, InpTF_High))
     {
      g_marketStructureHTF.Update(1);
      string v3HtfLogText; bool v3HasNewHtfEvent;
      g_htfBiasObserver.Observe(g_scenarioContext, v3HtfLogText, v3HasNewHtfEvent);
      if(InpDebugPipeline && v3HtfLogText != "")
         g_logger.LogInfo(v3HtfLogText);
     }

   // --- Sécurité : perte/gain journalier, pertes consécutives ---
   double dailyProfit = g_statistics.GetDailyProfit();
   double dailyProfitPercent = CUtilities::SafeDivide(dailyProfit, g_initialBalance, 0.0) * 100.0;

   int consecutiveLosses = CountRecentConsecutiveLosses();
   if(!InpRecoveryModeEnabled && consecutiveLosses >= InpMaxConsecutiveLosses)
     {
      if(!g_tradingStoppedToday)
         g_logger.LogSystemEvent("KillSwitch", StringFormat("Trading stoppe pour la journee : %d pertes consecutives (limite=%d)",
                                                             consecutiveLosses, InpMaxConsecutiveLosses));
      g_tradingStoppedToday = true;
     }

   // --- Filtres de marché (gate l'analyse du signal) ---
   SMarketContext context = g_marketContext.GetContext();
   // CORRECTIF V3.6.5 : "currentDrawdown" doit refleter le drawdown
   // COURANT (recuperable), pas le maximum historique jamais atteint.
   // g_statistics.GetMaxDrawdownPercent() reste la reference historique
   // pour les rapports (non modifiee) - CFilters, lui, attend une valeur
   // courante, ce que g_accountMetrics fournit desormais correctement.
   // CFilters lui-meme n'est pas touche : signature et logique internes
   // identiques, seule la source transmise ici change.
   double currentDrawdown = g_accountMetrics.GetCurrentDrawdownPercent();
   SValidationReport filterReport = g_filters.Evaluate(_Symbol, context, currentDrawdown);
   if(InpDebugPipeline)
      g_logger.LogInfo(filterReport.summary);
   g_diagnostics.RecordFiltersResult(filterReport);

   // NOUVEAU (correctif journalisation) : blocage de filtre journalisé
   // systematiquement dans SystemEvents.csv (independamment de
   // InpDebugPipeline), dedoublonne par label pour ne pas spammer tant
   // que la MEME raison bloque bougie apres bougie.
   if(!filterReport.tradeAllowed)
     {
      string filterLabel = CDiagnostics::GetFirstFailedLabel(filterReport);
      if(filterLabel != g_lastFilterBlockLabel)
        {
         g_logger.LogSystemEvent("SessionFilter", StringFormat("Analyse bloquee : %s", filterLabel));
         g_lastFilterBlockLabel = filterLabel;
        }
     }
   else
      g_lastFilterBlockLabel = ""; // Le filtre repasse au vert : la prochaine raison de blocage sera de nouveau journalisee

   SSignalResult signal;
   if(filterReport.tradeAllowed)
     {
      signal = g_signalManager.GenerateSignal(1);
      if(InpDebugPipeline)
         g_logger.LogInfo(signal.reason); // Bloc SCORE DETAIL visible directement dans le journal Experts
      DEBUG_SIGNAL(StringFormat("Signal=%s Score=%.1f Bull=%.1f Bear=%.1f Seuil=%.1f",
                  CUtilities::SignalTypeToString(signal.type), signal.score,
                  signal.bullishScore, signal.bearishScore, signal.thresholdPoints));
     }
   else
     {
      signal.type            = SIGNAL_NONE;
      signal.score           = 0.0;
      signal.confidence      = 0.0;
      signal.time            = iTime(_Symbol, InpTF_Main, 1);
      signal.price           = iClose(_Symbol, InpTF_Main, 1);
      signal.executed        = false;
      signal.bullishScore    = 0.0;
      signal.bearishScore    = 0.0;
      signal.thresholdPoints = 0.0;
      signal.reason          = "Filtré avant analyse : " + filterReport.summary;
     }
   g_diagnostics.RecordSignal(signal.type, signal.bullishScore, signal.bearishScore, signal.thresholdPoints);

   // --- V3 - Shadow Decision Engine (Sprint V3.5) ---
   // Evaluation en mode SHADOW STRICT : le TSE produit desormais un
   // VRAI verdict deterministe (authorized/confidence/4 criteres), mais
   // ce verdict n'influence JAMAIS "signal" ni "g_tradingStoppedToday"
   // ci-dessous - la decision d'entree reelle reste exclusivement
   // pilotee par CSignalManager. "signal.type" est transmis en VALEUR
   // (pas un pointeur vers SignalManager) - le TSE ne lit aucun module,
   // conformement au §3.3bis. Voir ARCHITECTURE_V3.md.
   SScenarioVerdict  v3EntryVerdict;
   SScenarioDecision v3EntryDecision;
   string            v3EntryTrigger = CStructureObserver::BuildTriggerReason(g_scenarioContext, v3HasNewStructureEvent);
   g_scenarioEngine.EvaluateEntry(g_scenarioContext, signal.type, v3EntryVerdict, v3EntryDecision, v3EntryTrigger);

   // --- Research Platform (Sprint V3.9.2, Increment I2) - capture Decision ---
   // Meme condition que le log [TSE] ci-dessous : un evenement reel
   // n'est capture que lorsqu'un signal candidat existe - coherent avec
   // la discipline "pas de spam" deja appliquee a chaque bougie sans
   // signal depuis le Sprint V3.5. v3OpportunityId est reutilise plus
   // bas, dans le meme tick, si un trade s'ouvre reellement.
   string v3OpportunityId = "";
   if(signal.type == SIGNAL_BUY || signal.type == SIGNAL_SELL)
     {
      v3OpportunityId = g_observationLayer.CaptureDecision(v3EntryVerdict, signal.type, _Symbol);

      // --- Research Platform (Sprint V3.9.3.3, Increment I3) - capture Context ---
      // Meme opportunityId que la Decision ci-dessus (meme tick, meme
      // instant) - "context" (SMarketContext) est deja calcule plus haut
      // dans cette fonction (g_marketContext.GetContext(), ligne ~1180),
      // aucun recalcul. Spread et sessions relus via les memes
      // utilitaires deja utilises par le filtre (CUtilities::
      // GetSpreadPoints, CSessions::IsSessionActive) - lecture, pas
      // duplication de logique.
      g_observationLayer.CaptureContext(v3OpportunityId, context, CUtilities::GetSpreadPoints(_Symbol),
                                        g_sessions.IsSessionActive(SESSION_TOKYO),
                                        g_sessions.IsSessionActive(SESSION_LONDON),
                                        g_sessions.IsSessionActive(SESSION_NEWYORK),
                                        _Symbol);
     }

   // Journalisation [TSE] uniquement quand un verdict reel a ete produit
   // (signal candidat present) - structuree par critere OK/KO (demande
   // explicite), format stable pour exploitation statistique future.
   if(InpDebugPipeline && (signal.type == SIGNAL_BUY || signal.type == SIGNAL_SELL))
     {
      g_logger.LogInfo(StringFormat(
         "[TSE]\nDecision : %s\nHTF : %s\nStructure : %s\nOrderBlock : %s\nFVG : %s\nConfidence : %.2f\nScenario : %s",
         v3EntryVerdict.authorized ? "AUTHORIZED" : "REFUSED",
         v3EntryVerdict.htfOk ? "OK" : "KO", v3EntryVerdict.structureOk ? "OK" : "KO",
         v3EntryVerdict.orderBlockOk ? "OK" : "KO", v3EntryVerdict.fvgOk ? "OK" : "KO",
         v3EntryVerdict.confidence, v3EntryVerdict.scenarioStrength));
     }

   // Mode analyse des performances : on enregistre TOUS les signaux,
   // exécutés ou non, y compris ceux filtrés en amont.
   if(InpLogAllSignals)
      g_signalRecorder.RecordSignal(signal);
   g_logger.LogDecision(signal, _Symbol);

   // --- Décision d'exécution ---
   if(signal.type != SIGNAL_NONE && !g_tradingStoppedToday)
     {
      double entryPrice = (signal.type == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slPrice = g_riskManager.CalculateStopLoss(signal.type, entryPrice, 1);
      double tpPrice = g_riskManager.CalculateTakeProfit(signal.type, entryPrice, slPrice, 1);
      double lot     = g_riskManager.CalculateLotSize(InpRiskPercent, entryPrice, slPrice);
      double rr      = g_riskManager.CalculateRR(entryPrice, slPrice, tpPrice);

      if(InpDebugPipeline)
        {
         g_logger.LogInfo(StringFormat(
            "RISK MANAGER : Entry=%.5f | SL=%.5f (dist=%.5f) | TP=%.5f (dist=%.5f) | RR=%.2f | Lot=%.2f",
            entryPrice, slPrice, MathAbs(entryPrice - slPrice), tpPrice, MathAbs(tpPrice - entryPrice), rr, lot));
        }

      string newsDetail, sessionDetail;
      bool newsBlockActive = g_newsFilter.IsNewsBlockActive(newsDetail);
      bool sessionAllowed  = g_sessions.IsWithinAnyEnabledSession(sessionDetail);

      SValidationInput vctx;
      vctx.symbol                 = _Symbol;
      vctx.signalType             = signal.type;
      vctx.lot                    = lot;
      vctx.entryPrice             = entryPrice;
      vctx.slPrice                = slPrice;
      vctx.tpPrice                = tpPrice;
      vctx.currentOpenPositions   = g_tradeManager.CountOpenPositions();
      vctx.maxPositions           = InpMaxPositions;
      vctx.dailyProfitPercent     = dailyProfitPercent;
      vctx.maxDailyLossPercent    = InpMaxDailyLossPercent;
      vctx.maxDailyGainPercent    = InpMaxDailyGainPercent;
      vctx.maxSpreadPoints        = InpMaxSpreadPoints;
      vctx.newsBlockActive        = newsBlockActive;
      vctx.useSessionOverride     = true;
      vctx.sessionAllowedOverride = sessionAllowed;

      // --- Sprint PropFirm - Blocage manuel definitif apres un breach ---
      // Court-circuite AVANT le calcul de validation - inutile de
      // construire vctx/appeler Validate() si le trading est deja
      // bloque. Flag DEDIE (g_propFirmTradingBlocked), jamais fusionne
      // avec le disjoncteur legacy existant (invariant 9 inchange).
      if(g_propFirmTradingBlocked)
        {
         if(InpDebugPipeline)
            g_logger.LogInfo("[PROPFIRM] Trade bloque - deblocage manuel requis suite a un breach precedent");
        }
      else
        {
      SValidationReport validation = g_validator.Validate(vctx);
      if(InpDebugPipeline)
         g_logger.LogInfo(validation.summary);
      g_diagnostics.RecordValidatorResult(validation);

      // NOUVEAU (correctif journalisation) : refus Validator journalise
      // systematiquement, dedoublonne par label (meme principe que le
      // filtre ci-dessus).
      if(!validation.tradeAllowed)
        {
         string validatorLabel = CDiagnostics::GetFirstFailedLabel(validation);
         if(validatorLabel != g_lastValidatorBlockLabel)
           {
            g_logger.LogSystemEvent("RiskManager", StringFormat("Trade refuse : %s", validatorLabel));
            g_lastValidatorBlockLabel = validatorLabel;
           }
        }
      else
         g_lastValidatorBlockLabel = "";

      if(validation.tradeAllowed)
        {
         ulong ticket = 0;
         bool opened = g_tradeManager.OpenPosition(signal.type, lot, slPrice, tpPrice, ticket);
         g_diagnostics.RecordTradeOpened(opened);

         if(InpDebugPipeline)
           {
            g_logger.LogInfo(StringFormat(
               "TRADE MANAGER : Direction=%s Volume=%.2f Entry=%.5f SL=%.5f TP=%.5f | Retcode=%d (%s)",
               CUtilities::SignalTypeToString(signal.type), lot, entryPrice, slPrice, tpPrice,
               g_tradeManager.GetLastRetcode(), g_tradeManager.GetLastRetcodeDescription()));
           }

         if(opened)
           {
            signal.executed = true;
            g_logger.LogInfo(StringFormat("Position ouverte : ticket=%I64u %s lot=%.2f entry=%.5f sl=%.5f tp=%.5f",
                                          ticket, CUtilities::SignalTypeToString(signal.type), lot, entryPrice, slPrice, tpPrice));

            // --- V3 - Shadow Analytics (Sprint V3.6) ---
            // Appariement immediat, dans le meme tick que le verdict
            // Shadow deja produit par le TSE plus haut (v3EntryVerdict) -
            // un fait etabli au moment ou il se produit, pas une
            // reconstruction a posteriori. N'influence rien de ce qui
            // precede ni de ce qui suit.
            g_shadowAnalytics.LinkVerdict(ticket, v3EntryVerdict);
            if(InpDebugPipeline)
              {
               g_logger.LogInfo(StringFormat("[SHADOW_LINK]\nTicket : %I64u\nVerdict : %s\nConfidence : %.2f",
                                ticket, v3EntryVerdict.authorized ? "AUTHORIZED" : "REFUSED", v3EntryVerdict.confidence));
              }

            // --- Research Platform (Sprint V3.9.2, Increment I2) - capture ExecutionOpen ---
            // Appelee UNIQUEMENT dans cette branche de succes reel (ticket
            // deja obtenu du broker) - garantit structurellement que le Cas B
            // (verdict autorise + ordre refuse) ne produit jamais cet
            // evenement. v3OpportunityId identique a celui capture par
            // CaptureDecision plus haut, meme tick.
            g_observationLayer.CaptureExecutionOpen(v3OpportunityId, ticket, _Symbol, lot, entryPrice, slPrice, tpPrice, signal.type);

            // --- Snapshot complet du marché pour le laboratoire d'analyse ---
            double support    = g_supportResistance.GetNearestSupport(entryPrice);
            double resistance = g_supportResistance.GetNearestResistance(entryPrice);
            SPatternResult patternAtEntry = g_patterns.DetectPattern(1);

            // CORRECTIF BUG RACINE (diagnostic confirmé par analyse des CSV
            // réels) : positionId doit être le ticket de l'ORDRE d'entrée
            // (= POSITION_IDENTIFIER MT5 = ce que CPositionManager utilise
            // via DEAL_POSITION_ID pour indexer ses trades clôturés), PAS
            // le ticket du DEAL (GetLastDealTicket()/ResultDeal()) - ce
            // sont deux nombres DIFFÉRENTS en MT5 (ex. observé en live :
            // ordre #9597195360, deal #9278287729). L'ancien code utilisait
            // le ticket du deal comme clé d'enregistrement dans le tracker,
            // alors que la clé de recherche à la clôture (rec.positionId,
            // dans CPositionManager) est le ticket de l'ordre - la
            // recherche échouait donc SYSTÉMATIQUEMENT, expliquant à elle
            // seule les colonnes vides de TradeFull.csv ET le TradeEvents.csv
            // toujours vide (RecordBreakEvenApplied/RecordTrailingApplied
            // échouaient silencieusement, ne trouvant jamais la position).
            // 'ticket' (variable déjà existante = m_trade.ResultOrder(),
            // retourné par OpenPosition()) est la valeur correcte - déjà
            // sous la main, aucun nouvel appel nécessaire.
            ulong openPositionId = ticket;

            // --- NOUVEAU : analyse technique complémentaire (Fibonacci / Structure / Sweep) ---
            string fibLevel, fibLeg;
            double fibDistPts;
            CFibonacci::ComputeNearestLevel(_Symbol, InpTF_Main, InpFib_LookbackBars, entryPrice, 1,
                                            fibLevel, fibDistPts, fibLeg);
            string structureEventNow = g_marketStructure.GetLastEventDescription();
            string sweepZoneNow      = g_marketStructure.DetectSweep(1);

            STradeSnapshot snap;
            snap.positionId            = openPositionId; // NOUVEAU (Phase 1)
            snap.entryTime            = TimeCurrent();
            snap.symbol               = _Symbol;
            snap.timeframe            = InpTF_Main;
            snap.signalType           = signal.type;
            snap.entryPrice           = entryPrice;
            snap.slPrice              = slPrice;
            snap.tpPrice              = tpPrice;
            snap.lot                  = lot;
            snap.rr                   = rr;
            snap.emaFast              = g_indicators.GetEMA(EMA_INDEX_FAST, 1);
            snap.emaSlow              = g_indicators.GetEMA(EMA_INDEX_SLOW, 1);
            snap.rsi                  = g_indicators.GetRSI(1);
            snap.atr                  = context.atrValue;
            snap.momentum             = context.momentum;
            snap.trendState           = context.trend;
            snap.volatilityState      = context.volatility;
            snap.nearestSupport       = support;
            snap.nearestResistance    = resistance;
            snap.distanceToSupport    = (support > 0.0) ? MathAbs(entryPrice - support) : 0.0;
            snap.distanceToResistance = (resistance > 0.0) ? MathAbs(resistance - entryPrice) : 0.0;
            snap.patternDescription   = patternAtEntry.description;
            snap.breakoutState        = g_supportResistance.DetectBreakout(1);
            snap.scoreBullish         = signal.bullishScore;
            snap.scoreBearish         = signal.bearishScore;
            snap.scoreThreshold       = signal.thresholdPoints;
            snap.fibNearestLevel      = fibLevel;       // NOUVEAU
            snap.fibDistancePoints    = fibDistPts;     // NOUVEAU
            snap.fibLegDirection      = fibLeg;         // NOUVEAU
            snap.structureEvent       = structureEventNow; // NOUVEAU
            snap.sweepZone            = sweepZoneNow;      // NOUVEAU

            g_logger.LogTradeSnapshot(snap);

            // NOUVEAU (Phase 1) : enregistrement auprès du tracker vivant
            // et de la table de corrélation pour reconstruction à la
            // clôture (STradeFullRecord).
            g_tradeTracker.RegisterNewPosition(openPositionId, snap,
                                               v3EntryVerdict.confidence, v3EntryVerdict.htfOk,
                                               v3EntryVerdict.structureOk, v3EntryVerdict.orderBlockOk,
                                               v3EntryVerdict.fvgOk, v3EntryVerdict.scenarioStrength,
                                               v3EntryVerdict.authorized);
            g_tradeHealthGuardian.RegisterPosition(openPositionId, (signal.type == SIGNAL_BUY),
                                                   v3EntryVerdict.confidence, v3EntryVerdict.scenarioStrength,
                                                   v3EntryVerdict.authorized);
            RecordOpenSnapshot(openPositionId, snap);
            DEBUG_TRADE(StringFormat("Ouverture %s lot=%.2f entry=%.5f positionId=%I64u",
                       CUtilities::SignalTypeToString(signal.type), lot, entryPrice, openPositionId));

            // NOUVEAU (Profit Guard) : enregistrement pour calcul du 1R
            if(InpUseProfitGuard)
              {
               double tickValueOpen = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
               double tickSizeOpen  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
               g_profitGuard.RegisterTrade(openPositionId, signal.type, entryPrice, slPrice, lot, tickValueOpen, tickSizeOpen);
              }

            // NOUVEAU (correctif diagnostic, demande explicite) : bloc [OPEN]
            // avec les 4 identifiants explicites, pour PROUVER le diagnostic
            // (deal ticket != order ticket/position id) plutôt que de
            // l'affirmer sans preuve vérifiable dans les fichiers.
            ulong dealTicketAtOpen = g_tradeManager.GetLastDealTicket();
            ulong positionTicketAtOpen = 0;
            if(PositionSelectByTicket(ticket))
               positionTicketAtOpen = (ulong)PositionGetInteger(POSITION_TICKET);
            g_logger.LogPipelineDebug(StringFormat(
               "[OPEN]\r\nOrderTicket=%I64u\r\nDealTicket=%I64u\r\nPositionTicket=%I64u\r\nPositionID=%I64u\r\nsymbol=%s\r\ndirection=%s\r\nentry_price=%.5f\r\nSL=%.5f\r\nTP=%.5f\r\ntracker_created=%s",
               ticket, dealTicketAtOpen, positionTicketAtOpen, openPositionId,
               _Symbol, CUtilities::SignalTypeToString(signal.type),
               entryPrice, slPrice, tpPrice, g_tradeTracker.IsTracked(openPositionId) ? "true" : "false"));

            // Corrélation ouverture -> clôture pour CDiagnostics (répartition
            // par Direction/Tendance/Pattern/Session) - INCHANGÉ (Phase 1)
            RecordOpenContext(openPositionId,
                              CUtilities::TrendStateToString(context.trend),
                              patternAtEntry.description,
                              g_sessions.GetCurrentSessionLabel());
           }
        }
      else
         g_logger.LogInfo("Trade refusé par CValidator (voir détail ci-dessus)");
     } // Fin du else PropFirm (Sprint PropFirm) - ferme le bloc ouvert avant Validate()

   // --- V3 - Hard Risk Guard (Sprint V3.4) ---
   // Evaluation REELLE en mode OBSERVATION SEULE : les 5 risques sont
   // desormais vraiment calcules (independamment de tout autre module,
   // voir HardRiskGuard.mqh), mais ce module ne declenche TOUJOURS
   // RIEN - aucun appel a CloseAllPositions() ici, aucune modification
   // de g_tradingStoppedToday. Le disjoncteur reel ci-dessous reste
   // 100% inchange et continue de piloter seul le comportement du
   // robot. Seules les TRANSITIONS de statut sont retournees (voir
   // modele evenementiel documente dans HardRiskGuard.mqh) - v3HardRiskEvents
   // est vide dans l'immense majorite des appels.
   SHardRiskEvent v3HardRiskEvents[];
   g_hardRiskGuard.Evaluate(dailyProfitPercent, InpMaxDailyLossPercent, InpMaxDailyGainPercent,
                            InpMaxDrawdownPercent, InpMaxConsecutiveLosses, InpMaxPositions,
                            _Symbol, InpMagicNumber, v3HardRiskEvents);
   if(InpDebugPipeline)
     {
      for(int v3i = 0; v3i < ArraySize(v3HardRiskEvents); v3i++)
        {
         g_logger.LogInfo(StringFormat("[HARD_RISK]\nType : %s\nStatus : %s\nValue : %.2f\nLimit : %.2f",
                          HardRiskTypeToString(v3HardRiskEvents[v3i].type), HardRiskStatusToString(v3HardRiskEvents[v3i].status),
                          v3HardRiskEvents[v3i].value, v3HardRiskEvents[v3i].limit));
        }
     }

   // --- Gain journalier maximal atteint : on ferme et on stoppe ---
   if(dailyProfitPercent >= InpMaxDailyGainPercent && !g_tradingStoppedToday)
     {
      g_logger.LogSystemEvent("DailyLimit", StringFormat("Gain journalier maximal atteint (%.2f%%) - fermeture et arret pour la journee", dailyProfitPercent));
      g_tradeManager.CloseAllPositions();
      g_tradingStoppedToday = true;
     }
   if(dailyProfitPercent <= -MathAbs(InpMaxDailyLossPercent) && !g_tradingStoppedToday)
     {
      g_logger.LogSystemEvent("DailyLimit", StringFormat("Perte journaliere maximale atteinte (%.2f%%) - fermeture et arret pour la journee", dailyProfitPercent));
      g_tradeManager.CloseAllPositions();
      g_tradingStoppedToday = true;
     }

   // --- Dashboard ---
   SDashboardData dash;
   dash.symbol          = _Symbol;
   dash.trend           = context.trend;
   dash.volatility      = context.volatility;
   dash.signalType      = signal.type;
   dash.score           = signal.score;
   dash.maxScore        = g_signalManager.GetMaxPossibleScore();
   dash.spreadPoints    = CUtilities::GetSpreadPoints(_Symbol);
   dash.atrValue        = context.atrValue;
   dash.rsiValue        = g_indicators.GetRSI(1);
   dash.dailyProfit     = dailyProfit;
   dash.drawdownPercent = currentDrawdown;
   dash.positionsCount  = g_tradeManager.CountOpenPositions();
   dash.maxPositions    = InpMaxPositions;
   dash.sessionLabel    = g_sessions.GetCurrentSessionLabel();
   dash.robotState      = g_tradingStoppedToday ? "Stoppe (limite journaliere)" : "Actif";

   g_dashboard.Update(dash);
  }
//+------------------------------------------------------------------+
