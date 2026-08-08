//+------------------------------------------------------------------+
//|                                       VirtualTradeTracker.mqh       |
//|                                      NexusEdgeEA - V4.1-P3.1bis    |
//|                                                                    |
//| INVARIANT 16 (ARCHITECTURE_LOCK.md) : ce module NE RÉIMPLÉMENTE    |
//| AUCUNE logique métier déjà existante dans le Trading Engine. Il    |
//| reçoit un entry/SL/TP déjà calculés (par CRiskManager, via         |
//| VirtualTradeFeed) et se contente d'observer leur issue virtuelle.  |
//| Aucun appel à CRiskManager, CTradeManager, ou quoi que ce soit du  |
//| Trading Engine depuis ce fichier.                                   |
//|                                                                    |
//| ISOLATION : ne lit jamais le marché lui-même (invariant 4) - High/ |
//| Low/barIndex/score sont TOUJOURS reçus en paramètre.               |
//|                                                                    |
//| WORST CASE PRINCIPLE (revue P3.1bis, vérifié : aucune convention   |
//| préexistante dans CPositionManager/CTradeLifecycleTracker/          |
//| CPostCloseWatcher - le problème n'existe que pour les trades        |
//| virtuels, jamais pour un trade réel où le broker connaît déjà       |
//| l'ordre exact des événements) : si SL ET TP sont tous deux dans     |
//| la fourchette [Low, High] d'UNE MÊME bougie, on considère           |
//| TOUJOURS que le SL a été touché en premier -> LOSS. Objectif :      |
//| sous-estimer plutôt que surestimer la performance du Pipeline B.    |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef VIRTUALTRADETRACKER_MQH
#define VIRTUALTRADETRACKER_MQH

#include "VirtualTradeTypes.mqh"

class CVirtualTradeTracker
  {
private:
   SVirtualTrade     m_trades[];
   int               m_maxBarsAlive; // Politique de timeout, EN BOUGIES (même discipline que OpportunityManager) - 0 = désactivée
   long              m_nextSeq;

   int               FindIndexById(const string id) const
     {
      int total = ArraySize(m_trades);
      for(int i = 0; i < total; i++)
         if(m_trades[i].id == id)
            return(i);
      return(-1);
     }

public:
                     CVirtualTradeTracker()
     {
      m_maxBarsAlive = 0;
      m_nextSeq      = 0;
     }

   //---------------------------------------------------------------
   // maxBarsAlive : politique de TIMEOUT en bougies. 0 = désactivée.
   //---------------------------------------------------------------
   void              Init(const int maxBarsAlive)
     {
      m_maxBarsAlive = maxBarsAlive;
      m_nextSeq      = 0;
      ArrayResize(m_trades, 0);
     }

   int               GetCount() const { return(ArraySize(m_trades)); }

   int               GetCountByState(const ENUM_VIRTUAL_TRADE_STATE state) const
     {
      int total = ArraySize(m_trades);
      int n = 0;
      for(int i = 0; i < total; i++)
         if(m_trades[i].state == state)
            n++;
      return(n);
     }

   //---------------------------------------------------------------
   // Accès en lecture - même patron que CPositionManager
   // (GetRecordCount/GetRecord) déjà établi dans le projet.
   //---------------------------------------------------------------
   SVirtualTrade     GetRecord(const int index) const
     {
      SVirtualTrade empty;
      ZeroMemory(empty);
      if(index < 0 || index >= ArraySize(m_trades))
         return(empty);
      return(m_trades[index]);
     }

   bool              TryGetById(const string id, SVirtualTrade &out) const
     {
      int idx = FindIndexById(id);
      if(idx < 0)
         return(false);
      out = m_trades[idx];
      return(true);
     }

   //---------------------------------------------------------------
   // RegisterTrade - point d'entrée UNIQUE de création. entryScore est
   // OPTIONNEL (Groupe B, EMPTY_VALUE si non fourni - VirtualTradeFeed
   // peut choisir de ne pas l'alimenter en Niveau 1).
   //---------------------------------------------------------------
   string            RegisterTrade(const string symbol, const ENUM_OPPORTUNITY_DIRECTION direction,
                                   const double entryPrice, const double slPrice, const double tpPrice,
                                   const int openBarIndex, const double entryScore = EMPTY_VALUE)
     {
      SVirtualTrade t;
      m_nextSeq++;
      t.id                 = StringFormat("VT-%I64d", m_nextSeq);
      t.symbol             = symbol;
      t.direction          = direction;
      t.entryPrice         = entryPrice;
      t.slPrice            = slPrice;
      t.tpPrice            = tpPrice;
      t.openBarIndex       = openBarIndex;
      t.state              = VIRTUAL_TRADE_OPEN;
      t.exitReason         = "";
      t.mfe                = 0.0;
      t.mae                = 0.0;
      t.closeBarIndex      = -1;
      t.bestFavorablePrice = entryPrice;
      t.worstAdversePrice  = entryPrice;
      t.entryScore             = entryScore;
      t.exitScore              = EMPTY_VALUE;
      t.peakScoreAfterEntry    = entryScore; // amorcé à entryScore si fourni, sinon EMPTY_VALUE
      t.lowestScoreAfterEntry  = entryScore;
      ArrayResize(t.scoreEvolution, 0);
      if(entryScore != EMPTY_VALUE)
        {
         ArrayResize(t.scoreEvolution, 1);
         t.scoreEvolution[0] = entryScore;
        }
      t.tradeHealthReserved             = ""; // Groupe C - NON DEFINI
      t.protectionRecommendationReserved = ""; // Groupe C - NON DEFINI

      int n = ArraySize(m_trades);
      ArrayResize(m_trades, n + 1);
      m_trades[n] = t;
      return(t.id);
     }

   //---------------------------------------------------------------
   // UpdateBar - À APPELER À CHAQUE NOUVELLE BOUGIE pour chaque trade
   // virtuel encore OPEN. Reçoit barHigh/barLow/barIndex en paramètre
   // (jamais lus via iHigh()/iLow() en interne - invariant 4).
   //
   // currentScore est OPTIONNEL (Groupe B, Niveau 2) : EMPTY_VALUE par
   // défaut = non fourni, auquel cas peakScoreAfterEntry/
   // lowestScoreAfterEntry/scoreEvolution[] restent inchangés pour cet
   // appel. Aucune rupture d'API le jour où VirtualTradeFeed commencera
   // à fournir un score réel - c'est le but explicite de cette
   // préparation (revue P3.1bis).
   //
   // WORST CASE PRINCIPLE : si SL et TP sont tous deux atteignables
   // dans [barLow, barHigh] de CETTE bougie, le SL est considéré touché
   // en premier -> LOSS (voir en-tête de fichier).
   //---------------------------------------------------------------
   bool              UpdateBar(const string id, const double barHigh, const double barLow,
                               const int barIndex, const double currentScore = EMPTY_VALUE)
     {
      int idx = FindIndexById(id);
      if(idx < 0)
         return(false);
      if(m_trades[idx].state != VIRTUAL_TRADE_OPEN)
         return(false); // Terminal - plus aucune mise à jour possible

      // --- MFE/MAE (Groupe A) - bornes incrémentales, même principe
      // que CPositionManager::CalculateExcursions mais mises à jour
      // bougie par bougie plutôt que reconstruites après coup. ---
      bool isBuy = (m_trades[idx].direction == OPPORTUNITY_DIRECTION_BUY);
      if(isBuy)
        {
         if(barHigh > m_trades[idx].bestFavorablePrice) m_trades[idx].bestFavorablePrice = barHigh;
         if(barLow  < m_trades[idx].worstAdversePrice)  m_trades[idx].worstAdversePrice  = barLow;
        }
      else
        {
         if(barLow  < m_trades[idx].bestFavorablePrice) m_trades[idx].bestFavorablePrice = barLow;
         if(barHigh > m_trades[idx].worstAdversePrice)  m_trades[idx].worstAdversePrice  = barHigh;
        }
      m_trades[idx].mfe = MathAbs(m_trades[idx].bestFavorablePrice - m_trades[idx].entryPrice);
      m_trades[idx].mae = MathAbs(m_trades[idx].entryPrice - m_trades[idx].worstAdversePrice);

      // --- Groupe B (Niveau 2, préparé) - alimenté uniquement si
      // currentScore est fourni par l'appelant. ---
      if(currentScore != EMPTY_VALUE)
        {
         if(m_trades[idx].peakScoreAfterEntry == EMPTY_VALUE || currentScore > m_trades[idx].peakScoreAfterEntry)
            m_trades[idx].peakScoreAfterEntry = currentScore;
         if(m_trades[idx].lowestScoreAfterEntry == EMPTY_VALUE || currentScore < m_trades[idx].lowestScoreAfterEntry)
            m_trades[idx].lowestScoreAfterEntry = currentScore;

         int n = ArraySize(m_trades[idx].scoreEvolution);
         ArrayResize(m_trades[idx].scoreEvolution, n + 1);
         m_trades[idx].scoreEvolution[n] = currentScore;
        }

      // --- Détection SL/TP touchés (Groupe A) ---
      bool tpTouched = isBuy ? (barHigh >= m_trades[idx].tpPrice) : (barLow <= m_trades[idx].tpPrice);
      bool slTouched = isBuy ? (barLow  <= m_trades[idx].slPrice) : (barHigh >= m_trades[idx].slPrice);

      if(tpTouched && slTouched)
        {
         // WORST CASE PRINCIPLE
         m_trades[idx].state         = VIRTUAL_TRADE_LOSS;
         m_trades[idx].exitReason    = "LOSS (ambiguite intra-bougie, Worst Case Principle applique)";
         m_trades[idx].closeBarIndex = barIndex;
         m_trades[idx].exitScore     = currentScore;
        }
      else if(tpTouched)
        {
         m_trades[idx].state         = VIRTUAL_TRADE_WIN;
         m_trades[idx].exitReason    = "WIN (TP)";
         m_trades[idx].closeBarIndex = barIndex;
         m_trades[idx].exitScore     = currentScore;
        }
      else if(slTouched)
        {
         m_trades[idx].state         = VIRTUAL_TRADE_LOSS;
         m_trades[idx].exitReason    = "LOSS (SL)";
         m_trades[idx].closeBarIndex = barIndex;
         m_trades[idx].exitScore     = currentScore;
        }

      return(true);
     }

   //---------------------------------------------------------------
   // CheckTimeouts - POLITIQUE DE TIMEOUT (même discipline que
   // OpportunityManager::UpdateExpiration - currentBarIndex injecté,
   // jamais lu en interne). À appeler APRÈS UpdateBar() pour cette
   // bougie : un trade touché par SL/TP la bougie même où il aurait
   // dépassé le timeout est compté WIN/LOSS, jamais TIMEOUT (la
   // clôture réelle prime sur l'expiration - même logique que
   // "un candidat déjà TRIGGERED n'expire plus" dans OpportunityManager).
   //---------------------------------------------------------------
   int               CheckTimeouts(const int currentBarIndex)
     {
      if(m_maxBarsAlive <= 0)
         return(0);

      int timedOutCount = 0;
      int total = ArraySize(m_trades);
      for(int i = 0; i < total; i++)
        {
         if(m_trades[i].state != VIRTUAL_TRADE_OPEN)
            continue;
         int ageBars = currentBarIndex - m_trades[i].openBarIndex;
         if(ageBars >= m_maxBarsAlive)
           {
            m_trades[i].state         = VIRTUAL_TRADE_TIMEOUT;
            m_trades[i].exitReason    = "TIMEOUT";
            m_trades[i].closeBarIndex = currentBarIndex;
            timedOutCount++;
           }
        }
      return(timedOutCount);
     }
   //---------------------------------------------------------------
   // GetSummaryReport - AJOUT (intégration P3.1bis). Agrège
   // UNIQUEMENT des données déjà stockées (comptages par état, MFE/MAE
   // moyens sur les trades clôturés) - aucun nouveau calcul métier,
   // conforme à l'invariant 16. Même esprit que GetShadowReport() du
   // TSE ou GetActivationReport() de CProfitProtectionEngine.
   //---------------------------------------------------------------
   string            GetSummaryReport() const
     {
      int total = ArraySize(m_trades);
      int nOpen = 0, nWin = 0, nLoss = 0, nTimeout = 0;
      double sumMfeClosed = 0.0, sumMaeClosed = 0.0;
      int nClosed = 0;

      for(int i = 0; i < total; i++)
        {
         switch(m_trades[i].state)
           {
            case VIRTUAL_TRADE_OPEN:    nOpen++;    break;
            case VIRTUAL_TRADE_WIN:     nWin++;     nClosed++; sumMfeClosed += m_trades[i].mfe; sumMaeClosed += m_trades[i].mae; break;
            case VIRTUAL_TRADE_LOSS:    nLoss++;    nClosed++; sumMfeClosed += m_trades[i].mfe; sumMaeClosed += m_trades[i].mae; break;
            case VIRTUAL_TRADE_TIMEOUT: nTimeout++; nClosed++; sumMfeClosed += m_trades[i].mfe; sumMaeClosed += m_trades[i].mae; break;
           }
        }

      double winRate = (nClosed > 0) ? (100.0 * nWin / nClosed) : 0.0;
      double avgMfe  = (nClosed > 0) ? (sumMfeClosed / nClosed) : 0.0;
      double avgMae  = (nClosed > 0) ? (sumMaeClosed / nClosed) : 0.0;

      return(StringFormat(
         "===== VIRTUAL TRADE TRACKER (V4.1-P3.1bis, Pipeline B) =====\n"
         "Trades virtuels total : %d\n"
         "OPEN=%d | WIN=%d | LOSS=%d | TIMEOUT=%d\n"
         "Win Rate (sur clotures) : %.1f%% (n=%d)\n"
         "MFE moyen (clotures) : %.5f | MAE moyen (clotures) : %.5f\n"
         "=============================================================",
         total, nOpen, nWin, nLoss, nTimeout, winRate, nClosed, avgMfe, avgMae));
     }
  };

#endif // VIRTUALTRADETRACKER_MQH
//+------------------------------------------------------------------+