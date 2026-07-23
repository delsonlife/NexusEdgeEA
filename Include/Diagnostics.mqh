//+------------------------------------------------------------------+
//|                                                 Diagnostics.mqh    |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| Description : Module de télémétrie centralisé.                    |
//|   CDiagnostics N'A AUCUNE LOGIQUE DE TRADING. Il observe et       |
//|   compte ce que les autres modules décident déjà, pour produire   |
//|   des statistiques globales sur tout le pipeline :                |
//|     Bougies analysées -> Filters -> SignalManager -> Validator   |
//|     -> TradeManager -> Trade clôturé (WIN/LOSS + raison + MFE/MAE)|
//|                                                                    |
//|   Objectif : répondre objectivement à "quel module élimine le     |
//|   plus de trades ?" et "où perd-on de l'argent ?" avec des        |
//|   chiffres, jamais des suppositions.                               |
//|                                                                    |
//|   La section finale "ANALYSE ET SUGGESTIONS" ne fait QUE décrire   |
//|   des observations statistiques - elle ne modifie jamais aucun    |
//|   paramètre ni aucune règle de trading.                            |
//|                                                                    |
//|   Activable/désactivable via InpDiagnosticsEnabled pour ne pas    |
//|   impacter les performances quand il n'est pas utilisé.            |
//|                                                                    |
//| MODIFIÉ (Phase 1 - Instrumentation) :                             |
//|   - RecordTradeClosed() reçoit désormais des paramètres           |
//|     supplémentaires OPTIONNELS (captureRatioPercent,               |
//|     timeInProfitSec, timeInLossSec, trailingActivated,             |
//|     breakEvenActivated), alimentés par CTradeLifecycleTracker via |
//|     l'orchestrateur. Les valeurs par défaut préservent le          |
//|     comportement exact d'avant si jamais un appelant ne les        |
//|     fournit pas.                                                    |
//|   - Ajout d'un mécanisme de SNAPSHOT/DELTA (ResetDailySnapshot /  |
//|     GenerateDailyReport) permettant de produire un rapport        |
//|     quotidien SANS jamais réinitialiser les compteurs cumulatifs  |
//|     utilisés par GenerateReport() (rapport de fin de session,     |
//|     appelé dans OnDeinit - inchangé, toujours complet depuis le    |
//|     démarrage de l'EA).                                            |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#include "Types.mqh"

#ifndef DIAGNOSTICS_MQH
#define DIAGNOSTICS_MQH

#define DIAG_MAX_LABELS 20
#define DIAG_NEAR_MISS_POINTS 10.0 // Seuil "quasi-signal" : score manquant <= 10 pts

//+------------------------------------------------------------------+
//| Classe CDiagnostics                                                   |
//+------------------------------------------------------------------+
class CDiagnostics
  {
private:
   bool              m_enabled;

   // --- Bougies analysées ---
   int               m_barsAnalyzed;

   // --- Étage Filters (CFilters::Evaluate) ---
   int               m_filtersPassed;
   int               m_filtersBlocked;
   string            m_filterBlockLabels[DIAG_MAX_LABELS];
   int               m_filterBlockCounts[DIAG_MAX_LABELS];
   int               m_filterBlockLabelCount;

   // --- Étage SignalManager ---
   int               m_signalNone;
   int               m_signalBuy;
   int               m_signalSell;
   int               m_signalNoneInsufficientScore; // score < seuil
   int               m_signalNoneNearMiss;           // score manquant <= DIAG_NEAR_MISS_POINTS
   int               m_signalNoneTie;                // bullish == bearish (cas limite)

   // --- Étage Validator ---
   int               m_validatorAllowed;
   int               m_validatorRefused;
   string            m_validatorRefuseLabels[DIAG_MAX_LABELS];
   int               m_validatorRefuseCounts[DIAG_MAX_LABELS];
   int               m_validatorRefuseLabelCount;

   // --- Étage TradeManager (ouverture) ---
   int               m_tradesOpened;
   int               m_tradesFailedToOpen;

   // --- Étage clôture des trades (WIN/LOSS, raison, MFE/MAE) ---
   int               m_closedWin;
   int               m_closedLoss;
   string            m_closeReasonLabels[DIAG_MAX_LABELS];
   int               m_closeReasonCounts[DIAG_MAX_LABELS];
   int               m_closeReasonLabelCount;
   double            m_sumMfeWin;   // MFE en PRIX (legacy, issu de SPositionRecord - conservé tel quel)
   double            m_sumMaeWin;
   double            m_sumMfeLoss;
   double            m_sumMaeLoss;
   double            m_sumDurationWinSec;
   double            m_sumDurationLossSec;

   // --- NOUVEAU (Phase 1) : métriques en ARGENT RÉEL ($), issues de
   // CTradeLifecycleTracker - distinctes des MFE/MAE prix ci-dessus,
   // car ce sont deux unités différentes répondant à deux besoins
   // différents (le prix pour la calibration SL/TP, l'argent pour le
   // pilotage quotidien "combien ai-je laissé sur la table").
   double            m_sumMfeMoney;
   double            m_sumMaeMoney;
   int               m_countLifecycleTrades;    // Nombre de trades pour lesquels ces données étaient disponibles
   double            m_sumCaptureRatio;
   int               m_countCaptureRatio;        // Ne compte que les trades où le Capture Ratio est calculable (MFE > 0)
   int               m_sumTimeInProfitSec;
   int               m_sumTimeInLossSec;
   int               m_trailingActivatedCount;
   int               m_breakEvenActivatedCount;

   // --- Répartition WIN/LOSS par dimension (Direction/Tendance/Pattern/Session) ---
   // Même mécanisme générique réutilisé 4 fois (labels/total/wins/profitSum)
   // pour répondre à "quel pattern est le plus rentable ?", "Londres vs
   // New York ?", "BUY vs SELL ?" sans dupliquer la logique 4 fois.
   string            m_directionLabels[DIAG_MAX_LABELS];
   int               m_directionTotal[DIAG_MAX_LABELS];
   int               m_directionWins[DIAG_MAX_LABELS];
   double            m_directionProfitSum[DIAG_MAX_LABELS];
   int               m_directionLabelCount;

   string            m_trendLabels[DIAG_MAX_LABELS];
   int               m_trendTotal[DIAG_MAX_LABELS];
   int               m_trendWins[DIAG_MAX_LABELS];
   double            m_trendProfitSum[DIAG_MAX_LABELS];
   int               m_trendLabelCount;

   string            m_patternLabels[DIAG_MAX_LABELS];
   int               m_patternTotal[DIAG_MAX_LABELS];
   int               m_patternWins[DIAG_MAX_LABELS];
   double            m_patternProfitSum[DIAG_MAX_LABELS];
   int               m_patternLabelCount;

   string            m_sessionLabels[DIAG_MAX_LABELS];
   int               m_sessionTotal[DIAG_MAX_LABELS];
   int               m_sessionWins[DIAG_MAX_LABELS];
   double            m_sessionProfitSum[DIAG_MAX_LABELS];
   int               m_sessionLabelCount;

   //---------------------------------------------------------------
   // NOUVEAU (Phase 1) : instantané des compteurs pertinents pour le
   // rapport quotidien. Structure INTERNE (pas dans Types.mqh - c'est
   // un détail d'implémentation de CDiagnostics, jamais échangé avec
   // un autre module). La copie de tableaux à taille fixe fonctionne
   // nativement en MQL5 (même principe déjà utilisé par
   // SValidationReport::checks[20] ailleurs dans le projet).
   //---------------------------------------------------------------
   struct SDailySnapshot
     {
      int      barsAnalyzed;
      int      filtersBlocked;
      int      signalBuy;
      int      signalSell;
      int      signalNone;
      int      validatorRefused;
      int      tradesOpened;
      int      closedWin;
      int      closedLoss;
      double   sumMfeMoney;
      double   sumMaeMoney;
      int      countLifecycleTrades;
      double   sumCaptureRatio;
      int      countCaptureRatio;
      int      sumTimeInProfitSec;
      int      sumTimeInLossSec;
      int      trailingActivatedCount;
      int      breakEvenActivatedCount;
      string   filterBlockLabels[DIAG_MAX_LABELS];
      int      filterBlockCounts[DIAG_MAX_LABELS];
      int      filterBlockLabelCount;
      string   closeReasonLabels[DIAG_MAX_LABELS];
      int      closeReasonCounts[DIAG_MAX_LABELS];
      int      closeReasonLabelCount;
     };

   SDailySnapshot    m_dayStart; // État des compteurs au dernier ResetDailySnapshot()
   bool              m_dayStartCaptured;

   //---------------------------------------------------------------
   // Trouve (ou crée) l'index d'un label dans un tableau
   // label/compteur parallèle générique (utilisé pour Filters,
   // Validator ET raisons de clôture - pas de duplication).
   //---------------------------------------------------------------
   int               FindOrAddLabel(string &labels[], int &counts[], int &labelCount, const string label) const
     {
      for(int i = 0; i < labelCount; i++)
        {
         if(labels[i] == label)
            return(i);
        }
      if(labelCount < DIAG_MAX_LABELS)
        {
         labels[labelCount] = label;
         counts[labelCount] = 0;
         labelCount++;
         return(labelCount - 1);
        }
      return(-1); // Table pleine (ne devrait pas arriver avec 20 emplacements)
     }

   //---------------------------------------------------------------
   // Formate la section "top raisons" pour un couple labels/counts
   // donné, triée par fréquence décroissante (tri à bulles simple,
   // le nombre d'entrées est toujours petit) avec pourcentage du total.
   //---------------------------------------------------------------
   string            FormatTopReasons(const string &labels[], const int &counts[], const int labelCount, const int totalForPercent) const
     {
      string localLabels[DIAG_MAX_LABELS];
      int localCounts[DIAG_MAX_LABELS];
      for(int i = 0; i < labelCount; i++)
        {
         localLabels[i] = labels[i];
         localCounts[i] = counts[i];
        }

      for(int i = 0; i < labelCount - 1; i++)
        {
         for(int j = i + 1; j < labelCount; j++)
           {
            if(localCounts[j] > localCounts[i])
              {
               int tmpC = localCounts[i]; localCounts[i] = localCounts[j]; localCounts[j] = tmpC;
               string tmpL = localLabels[i]; localLabels[i] = localLabels[j]; localLabels[j] = tmpL;
              }
           }
        }

      string result = "";
      for(int i = 0; i < labelCount; i++)
        {
         double pct = (totalForPercent > 0) ? ((double)localCounts[i] / (double)totalForPercent * 100.0) : 0.0;
         result += StringFormat("      -> %s : %d fois (%.1f%%)\n", localLabels[i], localCounts[i], pct);
        }
      return(result);
     }

   //---------------------------------------------------------------
   // Retourne le libellé et le % du plus gros contributeur d'un
   // tableau label/count (utilisé pour la section suggestions).
   //---------------------------------------------------------------
   string            GetTopLabel(const string &labels[], const int &counts[], const int labelCount, int &topCountOut) const
     {
      topCountOut = 0;
      string topLabel = "";
      for(int i = 0; i < labelCount; i++)
        {
         if(counts[i] > topCountOut)
           {
            topCountOut = counts[i];
            topLabel    = labels[i];
           }
        }
      return(topLabel);
     }

   //---------------------------------------------------------------
   // Enregistre un trade clôturé dans UNE dimension de répartition
   // (Direction, Tendance, Pattern ou Session - même mécanisme
   // générique réutilisé 4 fois, pas de duplication).
   //---------------------------------------------------------------
   void              RecordBreakdown(string &labels[], int &totals[], int &wins[], double &profitSums[],
                                     int &labelCount, const string label, const bool isWin, const double profit) const
     {
      int idx = FindOrAddLabel(labels, totals, labelCount, label);
      if(idx < 0)
         return;
      totals[idx]++;
      if(isWin)
         wins[idx]++;
      profitSums[idx] += profit;
     }

   //---------------------------------------------------------------
   // Formate une dimension de répartition complète, triée par
   // nombre de trades décroissant : Label -> N trades, WinRate%, Profit.
   //---------------------------------------------------------------
   string            FormatBreakdown(const string &labels[], const int &totals[], const int &wins[], const double &profitSums[],
                                     const int labelCount, const string title) const
     {
      if(labelCount == 0)
         return("");

      // Tri par nombre de trades décroissant (tri à bulles, petites tables)
      string localLabels[DIAG_MAX_LABELS];
      int localTotals[DIAG_MAX_LABELS];
      int localWins[DIAG_MAX_LABELS];
      double localProfits[DIAG_MAX_LABELS];
      for(int i = 0; i < labelCount; i++)
        {
         localLabels[i]  = labels[i];
         localTotals[i]  = totals[i];
         localWins[i]    = wins[i];
         localProfits[i] = profitSums[i];
        }
      for(int i = 0; i < labelCount - 1; i++)
        {
         for(int j = i + 1; j < labelCount; j++)
           {
            if(localTotals[j] > localTotals[i])
              {
               int tC = localTotals[i]; localTotals[i] = localTotals[j]; localTotals[j] = tC;
               int wC = localWins[i]; localWins[i] = localWins[j]; localWins[j] = wC;
               double pC = localProfits[i]; localProfits[i] = localProfits[j]; localProfits[j] = pC;
               string lC = localLabels[i]; localLabels[i] = localLabels[j]; localLabels[j] = lC;
              }
           }
        }

      string result = StringFormat("   %s :\n", title);
      for(int i = 0; i < labelCount; i++)
        {
         double winRate = (localTotals[i] > 0) ? ((double)localWins[i] / localTotals[i] * 100.0) : 0.0;
         result += StringFormat("      -> %s : %d trades | WinRate=%.1f%% | Profit net=%.2f\n",
                                localLabels[i], localTotals[i], winRate, localProfits[i]);
        }
      return(result);
     }

   //---------------------------------------------------------------
   // NOUVEAU (Phase 1). Construit un instantané de tous les compteurs
   // utilisés par le rapport quotidien, à partir de l'état ACTUEL
   // (cumulatif depuis le démarrage de l'EA). Ne modifie rien.
   //---------------------------------------------------------------
   SDailySnapshot    CaptureCurrentState() const
     {
      SDailySnapshot s;
      s.barsAnalyzed            = m_barsAnalyzed;
      s.filtersBlocked          = m_filtersBlocked;
      s.signalBuy               = m_signalBuy;
      s.signalSell              = m_signalSell;
      s.signalNone              = m_signalNone;
      s.validatorRefused        = m_validatorRefused;
      s.tradesOpened            = m_tradesOpened;
      s.closedWin               = m_closedWin;
      s.closedLoss              = m_closedLoss;
      s.sumMfeMoney             = m_sumMfeMoney;
      s.sumMaeMoney             = m_sumMaeMoney;
      s.countLifecycleTrades    = m_countLifecycleTrades;
      s.sumCaptureRatio         = m_sumCaptureRatio;
      s.countCaptureRatio       = m_countCaptureRatio;
      s.sumTimeInProfitSec      = m_sumTimeInProfitSec;
      s.sumTimeInLossSec        = m_sumTimeInLossSec;
      s.trailingActivatedCount  = m_trailingActivatedCount;
      s.breakEvenActivatedCount = m_breakEvenActivatedCount;
      s.filterBlockLabelCount   = m_filterBlockLabelCount;
      s.closeReasonLabelCount   = m_closeReasonLabelCount;
      for(int i = 0; i < DIAG_MAX_LABELS; i++)
        {
         s.filterBlockLabels[i] = m_filterBlockLabels[i];
         s.filterBlockCounts[i] = m_filterBlockCounts[i];
         s.closeReasonLabels[i] = m_closeReasonLabels[i];
         s.closeReasonCounts[i] = m_closeReasonCounts[i];
        }
      return(s);
     }

   //---------------------------------------------------------------
   // NOUVEAU (Phase 1). Calcule le delta (aujourd'hui uniquement)
   // d'un tableau label/count entre l'état actuel et le snapshot de
   // début de journée, et retourne le TOP N label le plus fréquent
   // dans ce delta (utilisé pour "Filtre le plus bloquant" etc.).
   // snapshotLabels/snapshotCounts/snapshotLabelCount = état à
   // ResetDailySnapshot(). Les nouveaux labels apparus dans la
   // journée (absents du snapshot) sont traités comme partant de 0.
   //---------------------------------------------------------------
   void              ComputeLabelDeltas(const string &currentLabels[], const int &currentCounts[], const int currentLabelCount,
                                        const string &snapLabels[], const int &snapCounts[], const int snapLabelCount,
                                        string &deltaLabelsOut[], int &deltaCountsOut[], int &deltaLabelCountOut) const
     {
      deltaLabelCountOut = currentLabelCount;
      for(int i = 0; i < currentLabelCount; i++)
        {
         deltaLabelsOut[i] = currentLabels[i];
         int baseline = 0;
         for(int j = 0; j < snapLabelCount; j++)
           {
            if(snapLabels[j] == currentLabels[i])
              {
               baseline = snapCounts[j];
               break;
              }
           }
         int delta = currentCounts[i] - baseline;
         deltaCountsOut[i] = (delta > 0) ? delta : 0;
        }
     }

public:
                     CDiagnostics()
     {
      m_enabled                     = true;
      m_barsAnalyzed                = 0;
      m_filtersPassed               = 0;
      m_filtersBlocked              = 0;
      m_filterBlockLabelCount       = 0;
      m_signalNone                  = 0;
      m_signalBuy                   = 0;
      m_signalSell                  = 0;
      m_signalNoneInsufficientScore = 0;
      m_signalNoneNearMiss          = 0;
      m_signalNoneTie               = 0;
      m_validatorAllowed            = 0;
      m_validatorRefused            = 0;
      m_validatorRefuseLabelCount   = 0;
      m_tradesOpened                = 0;
      m_tradesFailedToOpen          = 0;
      m_closedWin                   = 0;
      m_closedLoss                  = 0;
      m_closeReasonLabelCount       = 0;
      m_sumMfeWin                   = 0.0;
      m_sumMaeWin                   = 0.0;
      m_sumMfeLoss                  = 0.0;
      m_sumMaeLoss                  = 0.0;
      m_sumDurationWinSec           = 0.0;
      m_sumDurationLossSec          = 0.0;
      m_sumMfeMoney                 = 0.0;
      m_sumMaeMoney                 = 0.0;
      m_countLifecycleTrades        = 0;
      m_sumCaptureRatio             = 0.0;
      m_countCaptureRatio           = 0;
      m_sumTimeInProfitSec          = 0;
      m_sumTimeInLossSec            = 0;
      m_trailingActivatedCount      = 0;
      m_breakEvenActivatedCount     = 0;
      m_directionLabelCount         = 0;
      m_trendLabelCount             = 0;
      m_patternLabelCount           = 0;
      m_sessionLabelCount           = 0;
      m_dayStartCaptured            = false;
     }

   bool              Init(const bool enabled)
     {
      m_enabled = enabled;
      if(m_enabled)
        {
         m_dayStart = CaptureCurrentState();
         m_dayStartCaptured = true;
        }
      return(true);
     }

   bool              IsEnabled() const { return(m_enabled); }

   //---------------------------------------------------------------
   // Extrait le label du PREMIER check en échec d'un rapport
   // (CFilters ou CValidator partagent la même struct SValidationReport)
   // - utilitaire statique, pas de duplication entre les 2 appels.
   //---------------------------------------------------------------
   static string     GetFirstFailedLabel(const SValidationReport &report)
     {
      for(int i = 0; i < report.checksCount; i++)
        {
         if(report.checks[i].result == CHECK_FAILED)
            return(report.checks[i].label);
        }
      return("");
     }

   void              RecordBarAnalyzed()
     {
      if(!m_enabled) return;
      m_barsAnalyzed++;
     }

   //---------------------------------------------------------------
   // À appeler avec le SValidationReport retourné par CFilters::Evaluate().
   //---------------------------------------------------------------
   void              RecordFiltersResult(const SValidationReport &report)
     {
      if(!m_enabled) return;

      if(report.tradeAllowed)
         m_filtersPassed++;
      else
        {
         m_filtersBlocked++;
         string label = GetFirstFailedLabel(report);
         int idx = FindOrAddLabel(m_filterBlockLabels, m_filterBlockCounts, m_filterBlockLabelCount, label);
         if(idx >= 0)
            m_filterBlockCounts[idx]++;
        }
     }

   //---------------------------------------------------------------
   // À appeler avec le SSignalResult retourné par CSignalManager. Les
   // valeurs bullish/bearish/threshold servent uniquement à classer
   // la raison du SIGNAL_NONE (score insuffisant / quasi-signal /
   // égalité) - aucune décision n'est prise ici, seulement observation.
   //---------------------------------------------------------------
   void              RecordSignal(const ENUM_SIGNAL_TYPE type, const double bullishTotal,
                                  const double bearishTotal, const double thresholdPoints)
     {
      if(!m_enabled) return;

      if(type == SIGNAL_BUY)
         m_signalBuy++;
      else if(type == SIGNAL_SELL)
         m_signalSell++;
      else
        {
         m_signalNone++;
         double winning = MathMax(bullishTotal, bearishTotal);
         double missing = thresholdPoints - winning;

         if(MathAbs(bullishTotal - bearishTotal) < 0.0001 && winning > 0.0)
            m_signalNoneTie++;
         else if(winning < thresholdPoints)
           {
            m_signalNoneInsufficientScore++;
            if(missing >= 0.0 && missing <= DIAG_NEAR_MISS_POINTS)
               m_signalNoneNearMiss++;
           }
        }
     }

   //---------------------------------------------------------------
   // À appeler avec le SValidationReport retourné par CValidator::Validate().
   //---------------------------------------------------------------
   void              RecordValidatorResult(const SValidationReport &report)
     {
      if(!m_enabled) return;

      if(report.tradeAllowed)
         m_validatorAllowed++;
      else
        {
         m_validatorRefused++;
         string label = GetFirstFailedLabel(report);
         int idx = FindOrAddLabel(m_validatorRefuseLabels, m_validatorRefuseCounts, m_validatorRefuseLabelCount, label);
         if(idx >= 0)
            m_validatorRefuseCounts[idx]++;
        }
     }

   void              RecordTradeOpened(const bool success)
     {
      if(!m_enabled) return;
      if(success)
         m_tradesOpened++;
      else
         m_tradesFailedToOpen++;
     }

   //---------------------------------------------------------------
   // À appeler pour chaque trade nouvellement détecté comme clôturé
   // (via CPositionManager). Centralise l'analyse WIN/LOSS + raison
   // + MFE/MAE + durée, ET la répartition par Direction/Tendance/
   // Pattern/Session (contexte capturé à l'OUVERTURE, transmis par
   // l'orchestrateur via sa table de corrélation).
   //
   // MODIFIÉ (Phase 1) : paramètres optionnels supplémentaires,
   // alimentés par CTradeLifecycleTracker. closeReason est désormais
   // typiquement la version DÉTAILLÉE (CTradeLifecycleTracker::
   // BuildDetailedCloseReason()), ce qui enrichit gratuitement la
   // répartition "Raisons de clôture" déjà existante - aucune
   // structure de comptage supplémentaire n'était nécessaire pour ça.
   //---------------------------------------------------------------
   void              RecordTradeClosed(const bool isWin, const string closeReason,
                                       const double mfe, const double mae, const int durationSeconds,
                                       const double profit,
                                       const string directionLabel = "", const string trendLabel = "",
                                       const string patternLabel = "", const string sessionLabel = "",
                                       const double captureRatioPercent = -1.0,
                                       const int timeInProfitSec = 0, const int timeInLossSec = 0,
                                       const bool trailingActivated = false, const bool breakEvenActivated = false,
                                       const double mfeMoney = 0.0, const double maeMoney = 0.0,
                                       const bool lifecycleDataAvailable = false)
     {
      if(!m_enabled) return;

      if(isWin)
        {
         m_closedWin++;
         m_sumMfeWin += mfe;
         m_sumMaeWin += mae;
         m_sumDurationWinSec += durationSeconds;
        }
      else
        {
         m_closedLoss++;
         m_sumMfeLoss += mfe;
         m_sumMaeLoss += mae;
         m_sumDurationLossSec += durationSeconds;
        }

      int idx = FindOrAddLabel(m_closeReasonLabels, m_closeReasonCounts, m_closeReasonLabelCount, closeReason);
      if(idx >= 0)
         m_closeReasonCounts[idx]++;

      if(directionLabel != "")
         RecordBreakdown(m_directionLabels, m_directionTotal, m_directionWins, m_directionProfitSum, m_directionLabelCount, directionLabel, isWin, profit);
      if(trendLabel != "")
         RecordBreakdown(m_trendLabels, m_trendTotal, m_trendWins, m_trendProfitSum, m_trendLabelCount, trendLabel, isWin, profit);
      if(patternLabel != "")
         RecordBreakdown(m_patternLabels, m_patternTotal, m_patternWins, m_patternProfitSum, m_patternLabelCount, patternLabel, isWin, profit);
      if(sessionLabel != "")
         RecordBreakdown(m_sessionLabels, m_sessionTotal, m_sessionWins, m_sessionProfitSum, m_sessionLabelCount, sessionLabel, isWin, profit);

      // --- NOUVEAU (Phase 1) : métriques issues de CTradeLifecycleTracker ---
      if(lifecycleDataAvailable)
        {
         m_countLifecycleTrades++;
         m_sumMfeMoney        += mfeMoney;
         m_sumMaeMoney         += maeMoney;
         m_sumTimeInProfitSec += timeInProfitSec;
         m_sumTimeInLossSec   += timeInLossSec;
         if(trailingActivated)
            m_trailingActivatedCount++;
         if(breakEvenActivated)
            m_breakEvenActivatedCount++;
         if(captureRatioPercent > -0.5) // -1.0 = non calculable (MFE nul), on ne pollue pas la moyenne
           {
            m_sumCaptureRatio += captureRatioPercent;
            m_countCaptureRatio++;
           }
        }
     }

   //---------------------------------------------------------------
   // Rapport final complet : entonnoir avec pourcentages, détail par
   // étage, analyse des clôtures (WIN/LOSS/raison/MFE/MAE), et
   // suggestions purement observationnelles (aucune modification
   // automatique de la stratégie). INCHANGÉ dans sa structure -
   // toujours cumulatif depuis le démarrage de l'EA, appelé dans
   // OnDeinit. Complété avec le bloc "Laboratoire d'analyse" en fin
   // de rapport.
   //---------------------------------------------------------------
   string            GenerateReport() const
     {
      if(!m_enabled)
         return("CDiagnostics désactivé (InpDiagnosticsEnabled=false) - aucune statistique collectée");

      string r = "===== DIAGNOSTICS GLOBAUX DU PIPELINE =====\n";

      // --- Entonnoir avec pourcentages (demandé explicitement) ---
      r += "\n--- PIPELINE (entonnoir) ---\n";
      r += StringFormat("Bougies analysees                       : %d\n", m_barsAnalyzed);
      double pctFilterBlocked = (m_barsAnalyzed > 0) ? ((double)m_filtersBlocked / m_barsAnalyzed * 100.0) : 0.0;
      r += StringFormat("  v  Filters rejetees                   : %d (%.1f%%)\n", m_filtersBlocked, pctFilterBlocked);
      double pctSignalNone = (m_barsAnalyzed > 0) ? ((double)m_signalNone / m_barsAnalyzed * 100.0) : 0.0;
      r += StringFormat("  v  Signal NONE                        : %d (%.1f%%)\n", m_signalNone, pctSignalNone);
      int totalSignalsGenerated = m_signalBuy + m_signalSell;
      double pctValidatorRefused = (totalSignalsGenerated > 0) ? ((double)m_validatorRefused / totalSignalsGenerated * 100.0) : 0.0;
      r += StringFormat("  v  Validator refuses (sur signaux)    : %d (%.1f%%)\n", m_validatorRefused, pctValidatorRefused);
      double pctTradeFailed = ((m_tradesOpened + m_tradesFailedToOpen) > 0) ? ((double)m_tradesFailedToOpen / (m_tradesOpened + m_tradesFailedToOpen) * 100.0) : 0.0;
      r += StringFormat("  v  TradeManager echecs                : %d (%.1f%%)\n", m_tradesFailedToOpen, pctTradeFailed);
      r += StringFormat("  v  Trades ouverts                     : %d\n", m_tradesOpened);

      // --- Détail par étage ---
      r += "\n--- Etage FILTERS (avant analyse du signal) ---\n";
      r += StringFormat("   Analyse autorisee                    : %d\n", m_filtersPassed);
      r += StringFormat("   Analyse bloquee                      : %d\n", m_filtersBlocked);
      if(m_filtersBlocked > 0)
         r += FormatTopReasons(m_filterBlockLabels, m_filterBlockCounts, m_filterBlockLabelCount, m_filtersBlocked);

      r += "\n--- Etage SIGNALMANAGER ---\n";
      r += StringFormat("   Signal BUY                           : %d\n", m_signalBuy);
      r += StringFormat("   Signal SELL                          : %d\n", m_signalSell);
      r += StringFormat("   Signal NONE (total)                  : %d\n", m_signalNone);
      r += StringFormat("      -> score insuffisant (< seuil)     : %d\n", m_signalNoneInsufficientScore);
      r += StringFormat("      -> dont quasi-signal (< %.0f pts)   : %d\n", DIAG_NEAR_MISS_POINTS, m_signalNoneNearMiss);
      r += StringFormat("      -> egalite Bull=Bear (cas limite)  : %d\n", m_signalNoneTie);

      r += "\n--- Etage VALIDATOR (avant execution) ---\n";
      r += StringFormat("   Trade autorise                       : %d\n", m_validatorAllowed);
      r += StringFormat("   Trade refuse                         : %d\n", m_validatorRefused);
      if(m_validatorRefused > 0)
         r += FormatTopReasons(m_validatorRefuseLabels, m_validatorRefuseCounts, m_validatorRefuseLabelCount, m_validatorRefused);

      r += "\n--- Etage TRADEMANAGER (ouverture) ---\n";
      r += StringFormat("   Positions ouvertes avec succes        : %d\n", m_tradesOpened);
      r += StringFormat("   Echecs d'ouverture (retcode broker)    : %d\n", m_tradesFailedToOpen);

      // --- Analyse des clôtures (point 2) ---
      int totalClosed = m_closedWin + m_closedLoss;
      r += "\n--- Etage CLOTURE DES TRADES (WIN/LOSS) ---\n";
      r += StringFormat("   Trades clotures (total)               : %d\n", totalClosed);
      r += StringFormat("   WIN                                   : %d\n", m_closedWin);
      r += StringFormat("   LOSS                                  : %d\n", m_closedLoss);
      if(m_closeReasonLabelCount > 0)
        {
         r += "   Raisons de cloture :\n";
         r += FormatTopReasons(m_closeReasonLabels, m_closeReasonCounts, m_closeReasonLabelCount, totalClosed);
        }
      if(m_closedWin > 0)
        {
         r += StringFormat("   MFE moyen prix (trades WIN)          : %.5f\n", m_sumMfeWin / m_closedWin);
         r += StringFormat("   MAE moyen prix (trades WIN)           : %.5f\n", m_sumMaeWin / m_closedWin);
         r += StringFormat("   Duree moyenne (trades WIN)            : %.0f sec\n", m_sumDurationWinSec / m_closedWin);
        }
      if(m_closedLoss > 0)
        {
         r += StringFormat("   MFE moyen prix (trades LOSS)          : %.5f\n", m_sumMfeLoss / m_closedLoss);
         r += StringFormat("   MAE moyen prix (trades LOSS)          : %.5f\n", m_sumMaeLoss / m_closedLoss);
         r += StringFormat("   Duree moyenne (trades LOSS)           : %.0f sec\n", m_sumDurationLossSec / m_closedLoss);
        }
      if(m_closedWin > 0 && m_closedLoss > 0)
        {
         r += "   Note : un MAE moyen (LOSS) tres proche de la distance du SL suggere un SL bien calibre.\n";
         r += "          Un MFE moyen (WIN) tres inferieur a la distance du TP suggere un TP trop ambitieux.\n";
        }

      // --- NOUVEAU (Phase 1) : bloc Laboratoire d'analyse (argent réel) ---
      r += "\n--- LABORATOIRE D'ANALYSE (argent reel, depuis CTradeLifecycleTracker) ---\n";
      if(m_countLifecycleTrades > 0)
        {
         r += StringFormat("   Trades avec donnees de vie disponibles : %d\n", m_countLifecycleTrades);
         r += StringFormat("   MFE moyen ($)                          : %.2f\n", m_sumMfeMoney / m_countLifecycleTrades);
         r += StringFormat("   MAE moyen / Heat moyen ($)             : %.2f\n", m_sumMaeMoney / m_countLifecycleTrades);
         r += StringFormat("   Temps moyen en gain                    : %.1f min\n", (m_sumTimeInProfitSec / (double)m_countLifecycleTrades) / 60.0);
         r += StringFormat("   Temps moyen en perte                   : %.1f min\n", (m_sumTimeInLossSec / (double)m_countLifecycleTrades) / 60.0);
         r += StringFormat("   Trailing active                        : %d fois (%.1f%% des trades)\n",
                           m_trailingActivatedCount, (double)m_trailingActivatedCount / m_countLifecycleTrades * 100.0);
         r += StringFormat("   Break Even active                      : %d fois (%.1f%% des trades)\n",
                           m_breakEvenActivatedCount, (double)m_breakEvenActivatedCount / m_countLifecycleTrades * 100.0);
         if(m_countCaptureRatio > 0)
            r += StringFormat("   Capture Ratio moyen                    : %.1f%%\n", m_sumCaptureRatio / m_countCaptureRatio);
        }
      else
         r += "   (Aucune donnee - InpTrackTradeLifecycle desactive ou aucun trade cloture avec suivi)\n";

      // --- Répartition par Direction / Tendance / Pattern / Session (comble le gap signalé) ---
      r += "\n--- REPARTITION WIN/LOSS PAR DIMENSION ---\n";
      string dirBreak = FormatBreakdown(m_directionLabels, m_directionTotal, m_directionWins, m_directionProfitSum, m_directionLabelCount, "Par direction (BUY vs SELL)");
      if(dirBreak != "") r += dirBreak;
      string trendBreak = FormatBreakdown(m_trendLabels, m_trendTotal, m_trendWins, m_trendProfitSum, m_trendLabelCount, "Par tendance a l'entree");
      if(trendBreak != "") r += trendBreak;
      string patternBreak = FormatBreakdown(m_patternLabels, m_patternTotal, m_patternWins, m_patternProfitSum, m_patternLabelCount, "Par pattern a l'entree");
      if(patternBreak != "") r += patternBreak;
      string sessionBreak = FormatBreakdown(m_sessionLabels, m_sessionTotal, m_sessionWins, m_sessionProfitSum, m_sessionLabelCount, "Par session a l'entree");
      if(sessionBreak != "") r += sessionBreak;
      if(dirBreak == "" && trendBreak == "" && patternBreak == "" && sessionBreak == "")
         r += "   (Aucune donnee - pas encore de trades clotures avec contexte associe)\n";

      // --- ANALYSE ET SUGGESTIONS (purement observationnel, point 3) ---
      r += "\n--- ANALYSE ET SUGGESTIONS (observations statistiques, aucune modification automatique) ---\n";

      int biggestStageCount = 0;
      string biggestStageName = "";
      if(m_filtersBlocked >= biggestStageCount) { biggestStageCount = m_filtersBlocked; biggestStageName = "Filters"; }
      if(m_signalNone >= biggestStageCount)     { biggestStageCount = m_signalNone;     biggestStageName = "SignalManager (SIGNAL_NONE)"; }
      if(m_validatorRefused >= biggestStageCount) { biggestStageCount = m_validatorRefused; biggestStageName = "Validator"; }

      double biggestStagePct = (m_barsAnalyzed > 0) ? ((double)biggestStageCount / m_barsAnalyzed * 100.0) : 0.0;
      r += StringFormat("Etage le plus bloquant : %s (%d occurrences, %.1f%% des bougies analysees)\n",
                        biggestStageName, biggestStageCount, biggestStagePct);

      if(biggestStageName == "SignalManager (SIGNAL_NONE)" && m_signalNoneInsufficientScore > 0)
        {
         double pctNearMiss = (double)m_signalNoneNearMiss / m_signalNoneInsufficientScore * 100.0;
         r += StringFormat("   Cause : score inferieur au seuil sur %.1f%% des SIGNAL_NONE, dont %.1f%% manquent de moins de %.0f points.\n",
                           (double)m_signalNoneInsufficientScore / m_signalNone * 100.0, pctNearMiss, DIAG_NEAR_MISS_POINTS);
         r += "   Suggestion : ce seuil (InpScore_Threshold) merite une analyse - une part significative des rejets sont des quasi-signaux.\n";
        }
      else if(biggestStageName == "Filters" && m_filtersBlocked > 0)
        {
         int topCount = 0;
         string topLabel = GetTopLabel(m_filterBlockLabels, m_filterBlockCounts, m_filterBlockLabelCount, topCount);
         double topPct = (double)topCount / m_filtersBlocked * 100.0;
         r += StringFormat("   Cause principale : le filtre '%s' bloque %.1f%% des rejets Filters.\n", topLabel, topPct);
         r += "   Suggestion : ce filtre precis merite une analyse de calibrage si sa frequence semble anormalement elevee.\n";
        }
      else if(biggestStageName == "Validator" && m_validatorRefused > 0)
        {
         int topCount = 0;
         string topLabel = GetTopLabel(m_validatorRefuseLabels, m_validatorRefuseCounts, m_validatorRefuseLabelCount, topCount);
         double topPct = (double)topCount / m_validatorRefused * 100.0;
         r += StringFormat("   Cause principale : le check '%s' bloque %.1f%% des refus Validator.\n", topLabel, topPct);
         r += "   Suggestion : verifier si ce check est structurellement trop strict ou reflete un vrai risque a eviter.\n";
        }

      if(totalClosed >= 10) // Statistiquement peu significatif en dessous
        {
         double winRate = (double)m_closedWin / totalClosed * 100.0;
         r += StringFormat("Win Rate observe sur %d trades clotures : %.1f%%\n", totalClosed, winRate);
        }
      else
         r += StringFormat("Trades clotures (%d) encore insuffisants pour une analyse statistique fiable du Win Rate.\n", totalClosed);

      r += "=============================================";
      return(r);
     }

   //---------------------------------------------------------------
   // NOUVEAU (Phase 1). Génère le rapport quotidien demandé, calculé
   // en DELTA par rapport au dernier ResetDailySnapshot() - ne touche
   // JAMAIS aux compteurs cumulatifs utilisés par GenerateReport().
   // profitPercentToday et profitFactorToday sont calculés par
   // CStatistics (source légitime des calculs monétaires globaux -
   // voir CStatistics::GetProfitSince/GetProfitFactorSince) et
   // transmis ici pour assemblage final - pas de duplication de ce
   // calcul dans CDiagnostics.
   //---------------------------------------------------------------
   string            GenerateDailyReport(const double profitPercentToday, const double profitFactorToday) const
     {
      if(!m_enabled || !m_dayStartCaptured)
         return("CDiagnostics : rapport quotidien indisponible (module desactive ou snapshot non initialise)");

      int barsToday       = m_barsAnalyzed - m_dayStart.barsAnalyzed;
      int signalsToday    = (m_signalBuy + m_signalSell) - (m_dayStart.signalBuy + m_dayStart.signalSell);
      int tradesToday     = m_tradesOpened - m_dayStart.tradesOpened;
      int winsToday       = m_closedWin - m_dayStart.closedWin;
      int lossesToday     = m_closedLoss - m_dayStart.closedLoss;
      int closedToday     = winsToday + lossesToday;
      double winRateToday = (closedToday > 0) ? ((double)winsToday / closedToday * 100.0) : 0.0;

      int lifecycleToday  = m_countLifecycleTrades - m_dayStart.countLifecycleTrades;
      double mfeAvgToday  = (lifecycleToday > 0) ? (m_sumMfeMoney - m_dayStart.sumMfeMoney) / lifecycleToday : 0.0;
      double maeAvgToday  = (lifecycleToday > 0) ? (m_sumMaeMoney - m_dayStart.sumMaeMoney) / lifecycleToday : 0.0;
      int captureCountToday = m_countCaptureRatio - m_dayStart.countCaptureRatio;
      double captureAvgToday = (captureCountToday > 0)
                              ? (m_sumCaptureRatio - m_dayStart.sumCaptureRatio) / captureCountToday
                              : 0.0;
      double timeProfitAvgToday = (lifecycleToday > 0)
                                  ? ((m_sumTimeInProfitSec - m_dayStart.sumTimeInProfitSec) / (double)lifecycleToday) / 60.0
                                  : 0.0;
      double timeLossAvgToday  = (lifecycleToday > 0)
                                 ? ((m_sumTimeInLossSec - m_dayStart.sumTimeInLossSec) / (double)lifecycleToday) / 60.0
                                 : 0.0;
      int trailingToday   = m_trailingActivatedCount - m_dayStart.trailingActivatedCount;
      int breakEvenToday  = m_breakEvenActivatedCount - m_dayStart.breakEvenActivatedCount;

      string r = "===== RAPPORT DU JOUR =====\n\n";
      r += StringFormat("Bougies analysees : %d\n\n", barsToday);
      r += StringFormat("Signaux detectes : %d\n\n", signalsToday);
      r += StringFormat("Trades ouverts : %d\n\n", tradesToday);
      r += StringFormat("Trades gagnants : %d\n\n", winsToday);
      r += StringFormat("Trades perdants : %d\n\n", lossesToday);
      r += StringFormat("Win Rate : %.0f %%\n\n", winRateToday);
      r += StringFormat("Profit Net : %+.2f %%\n\n", profitPercentToday);
      r += StringFormat("Profit Factor : %.2f\n\n", profitFactorToday);
      if(lifecycleToday > 0)
        {
         r += StringFormat("Capture Ratio moyen : %.0f %%\n\n", captureAvgToday);
         r += StringFormat("MFE moyen : %.0f $\n\n", mfeAvgToday);
         r += StringFormat("MAE moyen : %.0f $\n\n", maeAvgToday);
         r += StringFormat("Trailing active : %d fois\n\n", trailingToday);
         r += StringFormat("Break Even active : %d fois\n\n", breakEvenToday);
        }

      // Raisons de clôture du jour (delta), incluant naturellement la
      // distinction "SL initial" / "SL Trailing" / "Break Even" / "TP"
      // puisque closeReason recu par RecordTradeClosed() est deja la
      // version detaillee (voir CTradeLifecycleTracker::BuildDetailedCloseReason)
      if(m_closeReasonLabelCount > 0)
        {
         string deltaLabels[DIAG_MAX_LABELS];
         int    deltaCounts[DIAG_MAX_LABELS];
         int    deltaLabelCount;
         ComputeLabelDeltas(m_closeReasonLabels, m_closeReasonCounts, m_closeReasonLabelCount,
                           m_dayStart.closeReasonLabels, m_dayStart.closeReasonCounts, m_dayStart.closeReasonLabelCount,
                           deltaLabels, deltaCounts, deltaLabelCount);
         bool anyToday = false;
         for(int i = 0; i < deltaLabelCount; i++)
            if(deltaCounts[i] > 0) anyToday = true;
         if(anyToday)
           {
            r += "Raisons de cloture :\n";
            for(int i = 0; i < deltaLabelCount; i++)
              {
               if(deltaCounts[i] > 0)
                  r += StringFormat("  -> %s : %d\n", deltaLabels[i], deltaCounts[i]);
              }
            r += "\n";
           }
        }

      // Top 3 filtres bloquants du jour (delta)
      if(m_filterBlockLabelCount > 0)
        {
         string deltaLabels[DIAG_MAX_LABELS];
         int    deltaCounts[DIAG_MAX_LABELS];
         int    deltaLabelCount;
         ComputeLabelDeltas(m_filterBlockLabels, m_filterBlockCounts, m_filterBlockLabelCount,
                           m_dayStart.filterBlockLabels, m_dayStart.filterBlockCounts, m_dayStart.filterBlockLabelCount,
                           deltaLabels, deltaCounts, deltaLabelCount);

         // Tri par count décroissant (tri à bulles, petite table)
         for(int i = 0; i < deltaLabelCount - 1; i++)
           {
            for(int j = i + 1; j < deltaLabelCount; j++)
              {
               if(deltaCounts[j] > deltaCounts[i])
                 {
                  int tc = deltaCounts[i]; deltaCounts[i] = deltaCounts[j]; deltaCounts[j] = tc;
                  string tl = deltaLabels[i]; deltaLabels[i] = deltaLabels[j]; deltaLabels[j] = tl;
                 }
              }
           }

         int totalFilterBlockedToday = m_filtersBlocked - m_dayStart.filtersBlocked;
         if(totalFilterBlockedToday > 0 && deltaLabelCount > 0 && deltaCounts[0] > 0)
           {
            string ordinal[3] = {"Filtre le plus bloquant", "Deuxieme filtre", "Troisieme filtre"};
            int shown = MathMin(3, deltaLabelCount);
            for(int i = 0; i < shown; i++)
              {
               if(deltaCounts[i] <= 0)
                  break;
               double pct = (double)deltaCounts[i] / totalFilterBlockedToday * 100.0;
               r += StringFormat("%s :\n%s (%.0f %%)\n\n", ordinal[i], deltaLabels[i], pct);
              }
           }
        }

      r += "=============================================";
      return(r);
     }

   //---------------------------------------------------------------
   // NOUVEAU (Phase 1). Redéfinit le point de départ ("aujourd'hui")
   // pour GenerateDailyReport(). À appeler UNE FOIS PAR JOUR, juste
   // après avoir imprimé le rapport quotidien (typiquement dans
   // RefreshDailyStateIfNeeded() de NexusEdgeEA.mq5, au moment où un
   // nouveau jour est détecté). N'affecte JAMAIS les compteurs
   // cumulatifs utilisés par GenerateReport().
   //---------------------------------------------------------------
   void              ResetDailySnapshot()
     {
      if(!m_enabled) return;
      m_dayStart = CaptureCurrentState();
      m_dayStartCaptured = true;
     }
  };

#endif // DIAGNOSTICS_MQH
//+------------------------------------------------------------------+
