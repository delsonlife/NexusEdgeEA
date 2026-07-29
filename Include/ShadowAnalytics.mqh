//+------------------------------------------------------------------+
//|                                            ShadowAnalytics.mqh     |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.6 - Validation statistique du TSE (Shadow Analytics).     |
//|                                                                    |
//| RÔLE UNIQUE : observer, apparier, compter. Ne modifie jamais un    |
//| ordre, un SL, un TP, un signal. Répond à une seule question :       |
//| "le TSE aurait-il amélioré les performances ?" - jamais "que doit   |
//| faire le robot".                                                    |
//|                                                                    |
//| SÉPARÉ DE CTradeScenarioEngine, DÉLIBÉRÉMENT : évite de faire       |
//| grossir davantage ce dernier (risque de "God Object" déjà identifié |
//| dans l'audit de l'architecture cible). Ce module ne détient AUCUN   |
//| pointeur vers CTradeScenarioEngine, SignalManager, TradeManager,     |
//| RiskManager, ProfitProtectionEngine, HardRiskGuard, LearningEngine   |
//| - il reçoit uniquement, en valeur, ce que l'orchestrateur lui        |
//| transmet explicitement à deux moments : l'ouverture réelle d'un     |
//| trade (verdict Shadow + ticket obtenu) et sa clôture réelle          |
//| (résultat déjà calculé par le pipeline existant).                    |
//|                                                                    |
//| DEUX POPULATIONS DE VERDICTS, JAMAIS MÉLANGÉES (voir conception      |
//| validée) :                                                          |
//|   Population A - verdict lié à un trade RÉELLEMENT ouvert. Seule    |
//|     population sur laquelle un taux de réussite réel est mesurable  |
//|     - c'est la SEULE population que ce module suit.                 |
//|   Population B - verdict produit mais aucun trade réel associé.     |
//|     Aucun taux de réussite ne peut être calculé sans simuler un      |
//|     trade contrefactuel (hors périmètre, refusé explicitement).     |
//|     Sa distribution reste déjà visible dans le rapport TSE existant  |
//|     (V3.5) - non dupliquée ici.                                     |
//|                                                                    |
//| PERSISTANCE : AUCUNE (ajustement validé avant implémentation). Une  |
//| simple structure en mémoire suffit pour ce sprint de validation en  |
//| backtest - un backtest est une session continue, aucun redémarrage  |
//| à survivre. La persistance (fichier, rechargement) pourra être       |
//| introduite plus tard SI un besoin réel apparaît (notamment pour le  |
//| Shadow en conditions live, où l'EA peut réellement redémarrer) -     |
//| pas "par principe" aujourd'hui.                                      |
//|                                                                    |
//| CLÉ D'APPARIEMENT : le ticket broker, jamais une fenêtre temporelle |
//| ni un rapprochement approximatif. Le verdict est lié au ticket DANS |
//| LE MÊME TICK, juste après l'ouverture réelle - un fait établi au     |
//| moment où il se produit, pas une reconstruction a posteriori.        |
//|                                                                    |
//| ANALYSE D'IMPACT INDIVIDUEL PAR CRITÈRE (ajustement validé) : pour  |
//| chaque critère (HTF/Structure/OrderBlock/FVG), le taux de réussite   |
//| réel est calculé séparément selon que CE critère était OK ou KO -    |
//| indépendamment des 3 autres et indépendamment de "authorized". Ça    |
//| mesure la valeur prédictive PROPRE de chaque critère, sans jamais    |
//| modifier la porte ET à 4 critères du ruleset (TradeScenarioEngine.mqh|
//| non touché par ce sprint).                                           |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef SHADOWANALYTICS_MQH
#define SHADOWANALYTICS_MQH

#include "V3Types.mqh"

struct SShadowLinkedTrade
  {
   ulong    ticket;
   datetime decisionTime;
   ENUM_SIGNAL_TYPE direction;
   double   confidence;
   string   scenarioStrength;
   bool     htfOk;
   bool     structureOk;
   bool     orderBlockOk;
   bool     fvgOk;
   bool     authorized;

   // --- Connu uniquement apres la cloture reelle ---
   bool     outcomeKnown;
   bool     isWin;
   double   profit;
   double   rrObtained; // 0.0 si le SL initial n'etait pas disponible (ex: position survivante a un redemarrage - meme limite honnete que le reste du projet)
  };

class CShadowAnalytics
  {
private:
   SShadowLinkedTrade m_trades[]; // En memoire uniquement (voir en-tete) - taille bornee par le nombre de trades reels d'un backtest, jamais un souci de volume

   int                FindIndexByTicket(const ulong ticket) const
     {
      for(int i = 0; i < ArraySize(m_trades); i++)
         if(m_trades[i].ticket == ticket)
            return(i);
      return(-1);
     }

   //---------------------------------------------------------------
   // Calcule OK-win/OK-loss/KO-win/KO-loss pour un critere donne, sur
   // les seuls trades avec outcomeKnown=true (Population A close).
   //---------------------------------------------------------------
   void               ComputeCriterionSplit(const int criterionIndex, int &okWin, int &okLoss, int &koWin, int &koLoss) const
     {
      okWin = 0; okLoss = 0; koWin = 0; koLoss = 0;
      for(int i = 0; i < ArraySize(m_trades); i++)
        {
         if(!m_trades[i].outcomeKnown)
            continue;
         bool ok;
         switch(criterionIndex)
           {
            case 0: ok = m_trades[i].htfOk;        break;
            case 1: ok = m_trades[i].structureOk;   break;
            case 2: ok = m_trades[i].orderBlockOk;  break;
            default: ok = m_trades[i].fvgOk;        break;
           }
         if(ok)
           {
            if(m_trades[i].isWin) okWin++; else okLoss++;
           }
         else
           {
            if(m_trades[i].isWin) koWin++; else koLoss++;
           }
        }
     }

public:
   //---------------------------------------------------------------
   // LinkVerdict - a appeler UNE SEULE FOIS, immediatement apres une
   // ouverture reelle reussie, dans le meme tick que le verdict Shadow
   // deja produit par le TSE (voir en-tete, cle d'appariement).
   //---------------------------------------------------------------
   void               LinkVerdict(const ulong ticket, const SScenarioVerdict &verdict)
     {
      int n = ArraySize(m_trades);
      ArrayResize(m_trades, n + 1);
      m_trades[n].ticket           = ticket;
      m_trades[n].decisionTime     = verdict.evaluatedAt;
      m_trades[n].confidence       = verdict.confidence;
      m_trades[n].scenarioStrength = verdict.scenarioStrength;
      m_trades[n].htfOk            = verdict.htfOk;
      m_trades[n].structureOk      = verdict.structureOk;
      m_trades[n].orderBlockOk     = verdict.orderBlockOk;
      m_trades[n].fvgOk            = verdict.fvgOk;
      m_trades[n].authorized       = verdict.authorized;
      m_trades[n].outcomeKnown     = false;
      m_trades[n].isWin            = false;
      m_trades[n].profit           = 0.0;
      m_trades[n].rrObtained       = 0.0;
     }

   //---------------------------------------------------------------
   // LinkOutcome - a appeler UNE SEULE FOIS, a la cloture reelle d'un
   // trade deja lie via LinkVerdict(). Ne recalcule rien : ne recoit
   // que des valeurs deja calculees par le pipeline existant
   // (SPositionRecord, LogNewlyClosedTrades) - aucune nouvelle lecture
   // d'historique ni de donnee de marche.
   //---------------------------------------------------------------
   bool               LinkOutcome(const ulong ticket, const bool isWin, const double profit, const double rrObtained,
                                  bool &wasAuthorizedOut)
     {
      int idx = FindIndexByTicket(ticket);
      if(idx < 0)
        {
         wasAuthorizedOut = false;
         return(false); // Ticket jamais lie via LinkVerdict (trade ouvert par une session anterieure, par ex.) - pas une erreur, juste hors de la Population A observable ce sprint
        }

      m_trades[idx].outcomeKnown = true;
      m_trades[idx].isWin        = isWin;
      m_trades[idx].profit       = profit;
      m_trades[idx].rrObtained   = rrObtained;
      wasAuthorizedOut           = m_trades[idx].authorized;
      return(true);
     }

   int                GetLinkedTradeCount() const { return(ArraySize(m_trades)); }

   //---------------------------------------------------------------
   // GetReport - Population A uniquement (voir en-tete). La Population
   // B (verdicts sans trade reel) reste visible dans le rapport TSE
   // deja existant (V3.5) - non dupliquee ici.
   //---------------------------------------------------------------
   string             GetReport() const
     {
      int totalLinked = ArraySize(m_trades);
      int totalClosed = 0, authWin = 0, authLoss = 0, refWin = 0, refLoss = 0;
      double authProfitSum = 0.0, refProfitSum = 0.0;

      for(int i = 0; i < totalLinked; i++)
        {
         if(!m_trades[i].outcomeKnown)
            continue;
         totalClosed++;
         if(m_trades[i].authorized)
           {
            if(m_trades[i].isWin) authWin++; else authLoss++;
            authProfitSum += m_trades[i].profit;
           }
         else
           {
            if(m_trades[i].isWin) refWin++; else refLoss++;
            refProfitSum += m_trades[i].profit;
           }
        }

      int authTotal = authWin + authLoss;
      int refTotal  = refWin + refLoss;
      double authWinRate = (authTotal > 0) ? (100.0 * authWin / authTotal) : 0.0;
      double refWinRate  = (refTotal  > 0) ? (100.0 * refWin  / refTotal)  : 0.0;
      double authAvgProfit = (authTotal > 0) ? (authProfitSum / authTotal) : 0.0;
      double refAvgProfit  = (refTotal  > 0) ? (refProfitSum  / refTotal)  : 0.0;

      string criterionNames[4] = {"HTF", "Structure", "OrderBlock", "FVG"};
      string critLines = "";
      for(int c = 0; c < 4; c++)
        {
         int okWin, okLoss, koWin, koLoss;
         ComputeCriterionSplit(c, okWin, okLoss, koWin, koLoss);
         double okRate = (okWin + okLoss > 0) ? (100.0 * okWin / (okWin + okLoss)) : 0.0;
         double koRate = (koWin + koLoss > 0) ? (100.0 * koWin / (koWin + koLoss)) : 0.0;
         critLines += StringFormat("  %-11s : OK -> %.1f%% de reussite (n=%d) | KO -> %.1f%% de reussite (n=%d)\n",
                                    criterionNames[c], okRate, okWin + okLoss, koRate, koWin + koLoss);
        }

      return(StringFormat(
         "===== SHADOW ANALYTICS REPORT (V3.6 - Population A uniquement) =====\n"
         "--- Trades avec verdict Shadow relie : %d (clotures : %d) ---\n"
         "Authorized : %d (win rate reel = %.1f%%, profit moyen = %.2f)\n"
         "Refused    : %d (win rate reel = %.1f%%, profit moyen = %.2f)\n"
         "--- Impact individuel par critere (independant du ruleset ET) ---\n"
         "%s"
         "--- Population B (verdicts sans trade reel) : voir rapport TRADE SCENARIO ENGINE ci-dessus, non dupliquee ici ---\n"
         "=======================================================================",
         totalLinked, totalClosed,
         authTotal, authWinRate, authAvgProfit,
         refTotal, refWinRate, refAvgProfit,
         critLines));
     }
  };

#endif // SHADOWANALYTICS_MQH
//+------------------------------------------------------------------+