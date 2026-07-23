//+------------------------------------------------------------------+
//|                                                 Statistics.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Statistiques de performance du robot.               |
//|   CStatistics s'appuie sur CPositionManager (déjà construit) pour |
//|   calculer Win Rate, Profit Factor, Espérance mathématique,       |
//|   Drawdown, Recovery Factor, RR moyen (délégué à                 |
//|   CPositionManager, pas recalculé) et Sharpe Ratio.                |
//|                                                                    |
//|   NOTE (recommandation discutée avec l'utilisateur) : le Sharpe   |
//|   Ratio est peu fiable sur un petit nombre de trades - ce qui est |
//|   justement le profil recherché ("peu de trades, bon taux de     |
//|   réussite"). Il est fourni comme indicateur SECONDAIRE ; Profit  |
//|   Factor, Expectancy et Max Drawdown restent les métriques        |
//|   principales à suivre.                                           |
//|                                                                    |
//| MODIFIÉ (Phase 1 - Instrumentation) : ajout de                    |
//|   GetProfitFactorSince(datetime), sur le même modèle que          |
//|   GetProfitSince() déjà existant - nécessaire au calcul du Profit |
//|   Factor DU JOUR dans le rapport quotidien (CDiagnostics::        |
//|   GenerateDailyReport()). Aucune méthode existante modifiée.       |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef STATISTICS_MQH
#define STATISTICS_MQH

#include "Types.mqh"
#include "Utilities.mqh"
#include "PositionManager.mqh"

//+------------------------------------------------------------------+
//| Classe CStatistics                                                    |
//+------------------------------------------------------------------+
class CStatistics
  {
private:
   CPositionManager *m_positionManager; // Référence non propriétaire
   double            m_initialBalance;  // Solde de référence pour le calcul du drawdown
   bool              m_initialized;

public:
                     CStatistics()
     {
      m_positionManager = NULL;
      m_initialBalance  = 0.0;
      m_initialized     = false;
     }

   //---------------------------------------------------------------
   // Initialise le module. initialBalance doit être le solde au
   // début de la période analysée (début du backtest ou mise en
   // service réelle), utilisé comme référence pour le drawdown.
   //---------------------------------------------------------------
   bool              Init(CPositionManager *positionManager, const double initialBalance)
     {
      if(positionManager == NULL)
        {
         Print("CStatistics::Init - CPositionManager invalide (NULL)");
         return(false);
        }

      m_positionManager = positionManager;
      m_initialBalance  = initialBalance;
      m_initialized     = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   int               GetTotalTrades() const
     {
      return(m_positionManager.GetRecordCount());
     }

   int               GetBuyCount() const
     {
      int total = m_positionManager.GetRecordCount();
      int count = 0;
      for(int i = 0; i < total; i++)
        {
         if(m_positionManager.GetRecord(i).type == SIGNAL_BUY)
            count++;
        }
      return(count);
     }

   int               GetSellCount() const
     {
      int total = m_positionManager.GetRecordCount();
      int count = 0;
      for(int i = 0; i < total; i++)
        {
         if(m_positionManager.GetRecord(i).type == SIGNAL_SELL)
            count++;
        }
      return(count);
     }

   //---------------------------------------------------------------
   // Win Rate en pourcentage (trades gagnants / total).
   //---------------------------------------------------------------
   double            GetWinRate() const
     {
      int total = m_positionManager.GetRecordCount();
      if(total == 0)
         return(0.0);
      int wins = m_positionManager.GetWinningTradesCount();
      return((double)wins / (double)total * 100.0);
     }

   //---------------------------------------------------------------
   // Profit Factor = somme des gains / valeur absolue de la somme
   // des pertes. Retourne 0.0 si aucune perte enregistrée n'empêche
   // la division (traité comme "non calculable" plutôt que l'infini).
   //---------------------------------------------------------------
   double            GetProfitFactor() const
     {
      int total = m_positionManager.GetRecordCount();
      double grossProfit = 0.0;
      double grossLoss   = 0.0;

      for(int i = 0; i < total; i++)
        {
         double profit = m_positionManager.GetRecord(i).profit;
         if(profit > 0.0)
            grossProfit += profit;
         else if(profit < 0.0)
            grossLoss += MathAbs(profit);
        }

      return(CUtilities::SafeDivide(grossProfit, grossLoss, 0.0));
     }

   //---------------------------------------------------------------
   // NOUVEAU (Phase 1). Profit Factor calculé uniquement sur les
   // trades dont closeTime >= fromTime - même formule que
   // GetProfitFactor(), restreinte à une fenêtre temporelle. Sur le
   // même modèle que GetProfitSince() ci-dessous, pour rester
   // cohérent avec le style déjà établi dans ce fichier.
   //---------------------------------------------------------------
   double            GetProfitFactorSince(const datetime fromTime) const
     {
      int total = m_positionManager.GetRecordCount();
      double grossProfit = 0.0;
      double grossLoss   = 0.0;

      for(int i = 0; i < total; i++)
        {
         SPositionRecord rec = m_positionManager.GetRecord(i);
         if(rec.closeTime < fromTime)
            continue;

         if(rec.profit > 0.0)
            grossProfit += rec.profit;
         else if(rec.profit < 0.0)
            grossLoss += MathAbs(rec.profit);
        }

      return(CUtilities::SafeDivide(grossProfit, grossLoss, 0.0));
     }

   //---------------------------------------------------------------
   // Espérance mathématique = profit moyen par trade (délégué à
   // CPositionManager, pas recalculé pour éviter la duplication).
   //---------------------------------------------------------------
   double            GetExpectancy() const
     {
      return(m_positionManager.GetAverageProfit());
     }

   //---------------------------------------------------------------
   // RR moyen réalisé, délégué à CPositionManager (source unique de
   // ce calcul, voir la limite documentée dans PositionManager.mqh).
   //---------------------------------------------------------------
   double            GetAverageRR() const
     {
      return(m_positionManager.GetAverageRR());
     }

   //---------------------------------------------------------------
   // Rejoue la séquence des trades clôturés pour calculer le drawdown
   // maximal (en % du pic d'équité atteint) et le profit net. Les
   // deux sont calculés ensemble pour n'avoir à rejouer la séquence
   // qu'une seule fois.
   //---------------------------------------------------------------
   void              ComputeDrawdownAndNetProfit(double &maxDrawdownPercent, double &maxDrawdownAmount, double &netProfit) const
     {
      maxDrawdownPercent = 0.0;
      maxDrawdownAmount  = 0.0;
      netProfit          = 0.0;

      int total = m_positionManager.GetRecordCount();
      if(total == 0 || m_initialBalance <= 0.0)
         return;

      double equity = m_initialBalance;
      double peak    = m_initialBalance;

      for(int i = 0; i < total; i++)
        {
         double profit = m_positionManager.GetRecord(i).profit;
         equity += profit;
         netProfit += profit;

         if(equity > peak)
            peak = equity;

         double drawdownAmount  = peak - equity;
         double drawdownPercent = CUtilities::SafeDivide(drawdownAmount, peak, 0.0) * 100.0;

         if(drawdownPercent > maxDrawdownPercent)
           {
            maxDrawdownPercent = drawdownPercent;
            maxDrawdownAmount  = drawdownAmount;
           }
        }
     }

   double            GetMaxDrawdownPercent() const
     {
      double ddPercent, ddAmount, netProfit;
      ComputeDrawdownAndNetProfit(ddPercent, ddAmount, netProfit);
      return(ddPercent);
     }

   //---------------------------------------------------------------
   // Recovery Factor = profit net / drawdown maximal (en montant).
   //---------------------------------------------------------------
   double            GetRecoveryFactor() const
     {
      double ddPercent, ddAmount, netProfit;
      ComputeDrawdownAndNetProfit(ddPercent, ddAmount, netProfit);
      return(CUtilities::SafeDivide(netProfit, ddAmount, 0.0));
     }

   //---------------------------------------------------------------
   // Sharpe Ratio simplifié, basé sur les rendements par trade (pas
   // annualisé). INDICATEUR SECONDAIRE : peu significatif avec un
   // faible nombre de trades (voir note en tête de fichier).
   //---------------------------------------------------------------
   double            GetSharpeRatioApprox() const
     {
      int total = m_positionManager.GetRecordCount();
      if(total < 2 || m_initialBalance <= 0.0)
         return(0.0);

      double returns[];
      ArrayResize(returns, total);
      double sumReturns = 0.0;

      for(int i = 0; i < total; i++)
        {
         double r = m_positionManager.GetRecord(i).profit / m_initialBalance;
         returns[i] = r;
         sumReturns += r;
        }

      double meanReturn = sumReturns / total;

      double sumSquaredDiff = 0.0;
      for(int i = 0; i < total; i++)
         sumSquaredDiff += MathPow(returns[i] - meanReturn, 2);

      double stdDev = MathSqrt(sumSquaredDiff / total);
      if(stdDev <= 0.0)
         return(0.0);

      return(meanReturn / stdDev);
     }

   //---------------------------------------------------------------
   // Profit sur une fenêtre temporelle donnée (jour/semaine/mois),
   // en sommant les trades clôturés dont closeTime tombe dans
   // [fromTime, TimeCurrent()].
   //---------------------------------------------------------------
   double            GetProfitSince(const datetime fromTime) const
     {
      int total = m_positionManager.GetRecordCount();
      double sum = 0.0;
      for(int i = 0; i < total; i++)
        {
         SPositionRecord rec = m_positionManager.GetRecord(i);
         if(rec.closeTime >= fromTime)
            sum += rec.profit;
        }
      return(sum);
     }

   double            GetDailyProfit() const
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      return(GetProfitSince(StructToTime(dt)));
     }

   double            GetWeeklyProfit() const
     {
      return(GetProfitSince(TimeCurrent() - 7 * 86400));
     }

   double            GetMonthlyProfit() const
     {
      return(GetProfitSince(TimeCurrent() - 30 * 86400));
     }

   //---------------------------------------------------------------
   // Génère un rapport texte complet, exploitable directement dans
   // CLogger ou pour analyse manuelle après un backtest - c'est ce
   // rapport qui permettra d'itérer objectivement sur l'EA.
   //---------------------------------------------------------------
   string            GenerateReport() const
     {
      double ddPercent, ddAmount, netProfit;
      ComputeDrawdownAndNetProfit(ddPercent, ddAmount, netProfit);

      string report = "=== Rapport de Performance NexusEdgeEA ===\n";
      report += StringFormat("Trades totaux       : %d (BUY=%d, SELL=%d)\n", GetTotalTrades(), GetBuyCount(), GetSellCount());
      report += StringFormat("Win Rate            : %.2f%%\n", GetWinRate());
      report += StringFormat("Profit Factor       : %.2f\n", GetProfitFactor());
      report += StringFormat("Esperance/trade     : %.2f\n", GetExpectancy());
      report += StringFormat("RR moyen realise    : %.2f\n", GetAverageRR());
      report += StringFormat("Profit net          : %.2f\n", netProfit);
      report += StringFormat("Drawdown maximal    : %.2f%% (%.2f en montant)\n", ddPercent, ddAmount);
      report += StringFormat("Recovery Factor     : %.2f\n", GetRecoveryFactor());
      report += StringFormat("Sharpe (approx, secondaire) : %.3f\n", GetSharpeRatioApprox());
      report += StringFormat("Profit du jour      : %.2f\n", GetDailyProfit());
      report += StringFormat("Profit de la semaine: %.2f\n", GetWeeklyProfit());
      report += StringFormat("Profit du mois      : %.2f\n", GetMonthlyProfit());

      return(report);
     }
  };

#endif // STATISTICS_MQH
//+------------------------------------------------------------------+
