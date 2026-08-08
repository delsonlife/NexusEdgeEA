//+------------------------------------------------------------------+
//|                                        VirtualTradeFeed.mqh         |
//|                                      NexusEdgeEA - V4.1-P3.1bis    |
//|                                                                    |
//| PONT entre un verdict TSE (Authorized OU Refused - LES DEUX nous   |
//| intéressent, revue P3.1bis : "on veut aussi savoir si les refusés  |
//| auraient perdu") et CVirtualTradeTracker. Seule pièce du dispositif |
//| P3.1bis qui connaît CRiskManager - CVirtualTradeTracker lui-même   |
//| reste totalement isolé (invariant 16, ARCHITECTURE_LOCK.md).       |
//|                                                                    |
//| NE RECALCULE JAMAIS SL/TP : délègue intégralement à CRiskManager,  |
//| déjà utilisé par le Trading Engine réel pour les trades réels -    |
//| même source de vérité, jamais une formule dupliquée.               |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef VIRTUALTRADEFEED_MQH
#define VIRTUALTRADEFEED_MQH

#include "../VirtualTrade/VirtualTradeTracker.mqh"
#include "../Types.mqh"        // ENUM_SIGNAL_TYPE - requis par la signature de CRiskManager (même remarque que VirtualTradeFeed vis-a-vis de TradeScenarioEngine.mqh, voir OpportunityPipeline.mqh)
#include "../RiskManager.mqh"

class CVirtualTradeFeed
  {
public:
   //---------------------------------------------------------------
   // OnVerdict - à appeler par l'orchestrateur (ou COpportunityPipeline)
   // pour CHAQUE candidat dispatché au TSE, que le verdict soit
   // Authorized ou Refused. Calcule entry/SL/TP via CRiskManager (SEULE
   // source de vérité, jamais recalculée ici) à partir de
   // candidate.triggerPrice (P1 Revision 3), puis enregistre un trade
   // virtuel. entryScore = verdict.confidence, transmis tel quel
   // (Groupe B, préparation - voir VirtualTradeTypes.mqh).
   //
   // CORRECTIF (auto-relecture avant livraison) : currentBarIndex est
   // REÇU EN PARAMÈTRE, jamais déduit de candidate.createdBarIndex -
   // ce dernier est la bougie de CRÉATION de l'Opportunity, pas celle
   // de son DÉCLENCHEMENT (une Opportunity peut être créée bougie 100
   // et déclenchée bougie 103 - utiliser createdBarIndex aurait biaisé
   // silencieusement le calcul d'âge du trade virtuel et son MFE/MAE).
   //
   // shift=1 : même convention que le reste du Trading Engine pour
   // CRiskManager.Calculate*() (bougie précédente déjà close) - voir
   // NexusEdgeEA.mq5, bloc "Décision d'exécution".
   //---------------------------------------------------------------
   static string     OnVerdict(const SOpportunityCandidate &candidate, const SScenarioVerdict &verdict,
                               const int currentBarIndex, CRiskManager &riskManager, CVirtualTradeTracker &tracker,
                               const int shift = 1)
     {
      if(candidate.triggerPrice <= 0.0)
         return(""); // Garde-fou défensif - ne devrait jamais arriver pour un candidat TRIGGERED

      ENUM_SIGNAL_TYPE signalType = (candidate.direction == OPPORTUNITY_DIRECTION_BUY) ? SIGNAL_BUY : SIGNAL_SELL;

      double slPrice = riskManager.CalculateStopLoss(signalType, candidate.triggerPrice, shift);
      double tpPrice = riskManager.CalculateTakeProfit(signalType, candidate.triggerPrice, slPrice, shift);

      return(tracker.RegisterTrade(candidate.symbol, candidate.direction, candidate.triggerPrice,
                                   slPrice, tpPrice, currentBarIndex, verdict.confidence));
     }
  };

#endif // VIRTUALTRADEFEED_MQH
//+------------------------------------------------------------------+