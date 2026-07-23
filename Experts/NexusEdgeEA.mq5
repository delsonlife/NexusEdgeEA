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

      // --- REFONTE "décision unique" (demande explicite, point 1) ---
      // BreakEven, Trailing et Profit Guard (Structure/PeakPercent/
      // Emergency) sont désormais des CALCULATEURS d'un seul et même
      // moteur (CProfitProtectionEngine). Une seule comparaison, un
      // seul appel ApplyExternalProtection() par tick - plus de blocs
      // if() séparés qui pourraient chacun tenter leur propre
      // modification.
      g_profitGuard.Update(ticket, currentProfitMoney);

      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double atrNow     = g_indicators.GetATR(0);
      SMarketContext contextNow = g_marketContext.GetContext();

      double oldSLGuard    = PositionGetDouble(POSITION_SL);
      double currentTPGuard = PositionGetDouble(POSITION_TP);

      double finalSL; ENUM_PROTECTION_SOURCE source; string decisionNote; bool closeNow; string diagnosticTrace;
      bool hasCandidate = g_profitGuard.ComputeFinalStopLevel(ticket, oldSLGuard, currentTPGuard, currentProfitMoney,
                                                              g_marketStructure, atrNow, contextNow.momentum,
                                                              tickValue, tickSize,
                                                              finalSL, source, decisionNote, closeNow, diagnosticTrace);

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
              }
           }
        }
     }
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
                      InpProfitGuardEmergencyRetainPercent, InpProfitGuardDiagnosticMode);

   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_statistics.Init(&g_positionManager, g_initialBalance);

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
   // Gestion des positions ouvertes (Break Even/Trailing/Partial) :
   // peut s'exécuter à chaque tick, contrairement à l'analyse de
   // signal, car réagir vite au prix est justement le but ici.
   ManageOpenPositions();

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
   g_diagnostics.RecordBarAnalyzed();

   g_positionManager.Update();
   LogNewlyClosedTrades();
   if(InpLogAllSignals)
      g_signalRecorder.Update();

   g_marketContext.Update();
   g_supportResistance.Update();
   g_marketStructure.Update(1); // NOUVEAU - meme cadence que MarketContext/SupportResistance

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
   double currentDrawdown = g_statistics.GetMaxDrawdownPercent();
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
            g_tradeTracker.RegisterNewPosition(openPositionId, snap);
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
