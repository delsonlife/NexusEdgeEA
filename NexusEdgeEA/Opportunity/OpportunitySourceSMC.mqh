//+------------------------------------------------------------------+
//|                                    OpportunitySourceSMC.mqh         |
//|                                      NexusEdgeEA - V4.1-P2A        |
//|                                                                    |
//| PONT entre les couches d'observation SMC (COrderBlockDetector,     |
//| CFVGDetector, via SScenarioContext déjà rempli) et                 |
//| COpportunityManager. C'est la SEULE pièce du module Opportunity    |
//| qui connaît l'existence du Trading Engine (V3Types.mqh) -          |
//| OpportunityManager.mqh et OpportunityTypes.mqh restent, eux,       |
//| totalement isolés (invariant P1 préservé même pendant P2).         |
//|                                                                    |
//| RÈGLE STRICTE (revue P2A validée) : ce pont ne recalcule JAMAIS    |
//| BOS/CHOCH/OrderBlock/FVG - il lit exclusivement les champs déjà    |
//| produits par COrderBlockDetector::Observe() / CFVGDetector::Observe()|
//| dans SScenarioContext (contrat déjà stable, V3Types.mqh). Aucune   |
//| interprétation causale : creationReason reflète un FAIT du code,   |
//| jamais une inférence (voir OpportunityTypes.mqh) :                 |
//|   - Order Block -> creationReason = "BOS"  (jamais CHOCH/SWEEP :   |
//|     COrderBlockDetector.mqh ne crée un OB QUE sur transition BOS)  |
//|   - FVG          -> creationReason = "FVG" (géométrie locale à 3   |
//|     bougies, indépendante de BOS/CHOCH/Sweep - CFVGDetector ne     |
//|     consulte JAMAIS CMarketStructure ; associer un événement       |
//|     structurel ici serait une CORRÉLATION présentée comme une      |
//|     CAUSALITÉ, explicitement écarté lors de la revue P2A)          |
//|                                                                    |
//| HORS PÉRIMÈTRE P2A (volontairement, à trancher plus tard) :        |
//| l'invalidation d'un Order Block/FVG (orderBlockValid/fvgValid      |
//| passant à false) ne provoque PAS aujourd'hui de Reject() du        |
//| candidat correspondant - ce pont ne fait qu'ALIMENTER, jamais      |
//| REJETER. Rien n'a été inventé sur ce point : l'absence de ce       |
//| comportement est un choix de périmètre explicite, pas un oubli.    |
//|                                                                    |
//| DÉDUPLICATION DE PRODUCTION (distincte de IsDuplicate() du         |
//| Manager) : ce pont ne réingère un Order Block/FVG que lorsque son  |
//| identifiant change (orderBlockId/fvgId, compteurs monotones déjà   |
//| gérés par les détecteurs) - évite d'appeler RegisterCandidate() à  |
//| chaque bougie tant que le MÊME Order Block/FVG reste actif. Ce     |
//| n'est PAS une violation de l'invariant 15 (un manager ne mémorise  |
//| jamais l'activité de ses CONSOMMATEURS) : ce pont est un           |
//| PRODUCTEUR vis-à-vis d'OpportunityManager, pas un consommateur -   |
//| invariant 15 non concerné.                                         |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef OPPORTUNITYSOURCESMC_MQH
#define OPPORTUNITYSOURCESMC_MQH

#include "OpportunityManager.mqh"
#include "../V3Types.mqh"

class COpportunitySourceSMC
  {
private:
   ulong             m_lastIngestedOrderBlockId; // 0 = aucun encore ingéré (cohérent avec la convention des détecteurs)
   ulong             m_lastIngestedFvgId;

public:
                     COpportunitySourceSMC()
     {
      m_lastIngestedOrderBlockId = 0;
      m_lastIngestedFvgId        = 0;
     }

   void              Init()
     {
      m_lastIngestedOrderBlockId = 0;
      m_lastIngestedFvgId        = 0;
     }

   //---------------------------------------------------------------
   // IngestOrderBlock - à appeler à chaque bougie, APRÈS
   // COrderBlockDetector::Observe(). N'enregistre un candidat QUE si
   // l'Order Block actif est NOUVEAU (orderBlockId différent du
   // dernier ingéré) - lit exclusivement ctx, aucun recalcul.
   // Retourne l'id du candidat créé, ou "" si rien de nouveau /
   // doublon détecté par le Manager lui-même.
   //---------------------------------------------------------------
   string            IngestOrderBlock(const SScenarioContext &ctx, const string symbol,
                                      const int currentBarIndex, COpportunityManager &manager)
     {
      if(!ctx.orderBlockActive || !ctx.orderBlockValid)
         return("");
      if(ctx.orderBlockDirection == DIRECTION_NONE)
         return(""); // Garde-fou défensif - ne devrait jamais arriver (voir COrderBlockDetector)
      if(ctx.orderBlockId == m_lastIngestedOrderBlockId)
         return(""); // Même Order Block que la dernière bougie observée - rien de nouveau à alimenter

      ENUM_OPPORTUNITY_DIRECTION direction = (ctx.orderBlockDirection == DIRECTION_BULLISH)
                                            ? OPPORTUNITY_DIRECTION_BUY : OPPORTUNITY_DIRECTION_SELL;

      string id = manager.RegisterCandidate(symbol, direction, "OrderBlock", "BOS",
                                            ctx.orderBlockLow, ctx.orderBlockHigh, currentBarIndex);

      m_lastIngestedOrderBlockId = ctx.orderBlockId; // Marqué "ingéré" que ce soit accepté ou rejeté comme doublon par le Manager
      return(id);
     }

   //---------------------------------------------------------------
   // IngestFVG - à appeler à chaque bougie, APRÈS CFVGDetector::Observe().
   // Même discipline que IngestOrderBlock ci-dessus. creationReason
   // reste "FVG" seul : voir la justification en tête de fichier
   // (aucune corrélation avec BOS/CHOCH/Sweep, décision de revue P2A).
   //---------------------------------------------------------------
   string            IngestFVG(const SScenarioContext &ctx, const string symbol,
                               const int currentBarIndex, COpportunityManager &manager)
     {
      if(!ctx.fvgActive || !ctx.fvgValid)
         return("");
      if(ctx.fvgDirection == DIRECTION_NONE)
         return(""); // Garde-fou défensif - ne devrait jamais arriver (voir CFVGDetector)
      if(ctx.fvgId == m_lastIngestedFvgId)
         return("");

      ENUM_OPPORTUNITY_DIRECTION direction = (ctx.fvgDirection == DIRECTION_BULLISH)
                                            ? OPPORTUNITY_DIRECTION_BUY : OPPORTUNITY_DIRECTION_SELL;

      string id = manager.RegisterCandidate(symbol, direction, "FVG", "FVG",
                                            ctx.fvgLow, ctx.fvgHigh, currentBarIndex);

      m_lastIngestedFvgId = ctx.fvgId;
      return(id);
     }
  };

#endif // OPPORTUNITYSOURCESMC_MQH
//+------------------------------------------------------------------+