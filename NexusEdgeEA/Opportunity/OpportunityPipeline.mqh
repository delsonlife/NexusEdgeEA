//+------------------------------------------------------------------+
//|                                       OpportunityPipeline.mqh       |
//|                                      NexusEdgeEA - V4.1-P2B        |
//|                                                                    |
//| Pipeline de traitement des opportunités TRIGGERED : dispatch vers  |
//| le TSE (Shadow uniquement), une fois par candidat.                 |
//|                                                                    |
//| RÔLE (destiné à grandir, revue P2B point 2) : aujourd'hui,          |
//| "éviter les doublons de dispatch" + "appeler EvaluateOpportunity". |
//| Demain (hors périmètre P2B, non implémenté ici) : filtre HTF,      |
//| priorisation, anti-conflit. La FORME du composant (un pipeline,    |
//| pas un simple distributeur à méthode unique) anticipe cette         |
//| croissance sans figer aujourd'hui une API qu'il faudrait défaire.  |
//|                                                                    |
//| INVARIANT 15 (ARCHITECTURE_LOCK.md) : c'est CE composant, et lui   |
//| seul, qui mémorise "quels id ont déjà été envoyés au TSE" -         |
//| COpportunityManager reste totalement idempotent (GetTriggeredAt()  |
//| ne consomme jamais). Le TSE, lui, reste totalement stateless        |
//| vis-à-vis de ce dispatch (EvaluateOpportunity() est une fonction    |
//| pure de son point de vue - seuls ses compteurs de diagnostic        |
//| internes évoluent, jamais une mémoire de "candidats déjà vus").     |
//|                                                                    |
//| AUCUNE DÉCISION DE TRADING : ce pipeline ne fait qu'appeler le TSE  |
//| en mode Shadow et retourner le résultat à l'appelant pour           |
//| traçabilité (log). Aucun ordre, aucune modification de position.   |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef OPPORTUNITYPIPELINE_MQH
#define OPPORTUNITYPIPELINE_MQH

#include "OpportunityManager.mqh"
#include "../Types.mqh"              // ENUM_SIGNAL_TYPE - TradeScenarioEngine.mqh en dépend sans le déclarer lui-même (dépendance d'ordre d'inclusion préexistante dans le projet) ; inclus ici explicitement pour que ce fichier compile seul, quel que soit l'ordre d'inclusion de l'appelant.
#include "../TradeScenarioEngine.mqh" // Révision 1 (P2B) - EvaluateOpportunity()

//+------------------------------------------------------------------+
//| Résultat d'un dispatch - retourné à l'appelant pour traçabilité   |
//| (log). Ce pipeline n'écrit jamais de log lui-même (délégué au      |
//| Trading Engine réel / CLogger, cohérent avec la séparation déjà    |
//| en place dans tout le projet).                                     |
//+------------------------------------------------------------------+
struct SOpportunityDispatchResult
  {
   SOpportunityCandidate candidate;
   SScenarioVerdict       verdict;
   SScenarioDecision      decision;
  };

class COpportunityPipeline
  {
private:
   string            m_dispatchedIds[]; // Mémoire "déjà envoyé au TSE" - appartient ICI (invariant 15), jamais à COpportunityManager

   bool              IsAlreadyDispatched(const string id) const
     {
      int total = ArraySize(m_dispatchedIds);
      for(int i = 0; i < total; i++)
         if(m_dispatchedIds[i] == id)
            return(true);
      return(false);
     }

   void              MarkDispatched(const string id)
     {
      int n = ArraySize(m_dispatchedIds);
      ArrayResize(m_dispatchedIds, n + 1);
      m_dispatchedIds[n] = id;
     }

public:
                     COpportunityPipeline() {}

   void              Init()
     {
      ArrayResize(m_dispatchedIds, 0);
     }

   int               GetDispatchedCount() const { return(ArraySize(m_dispatchedIds)); }

   //---------------------------------------------------------------
   // ProcessTick - À APPELER À CHAQUE TICK (revue P2B point 3 : un
   // déclenchement intra-bougie ne doit jamais attendre la prochaine
   // bougie H1, sous peine d'évaluer une opportunité qui n'existe
   // peut-être déjà plus).
   //
   // Parcourt le lot TRIGGERED de manager (consultation idempotente,
   // GetTriggeredCount/GetTriggeredAt - jamais de consommation côté
   // Manager), ignore tout id déjà dispatché, appelle
   // tse.EvaluateOpportunity() pour chaque candidat NOUVEAU, puis le
   // marque comme dispatché. resultsOut[] reçoit le détail complet
   // (candidat + verdict + décision) pour que l'appelant produise la
   // traçabilité de bout en bout (objectif P2B).
   //
   // Traduit ENUM_OPPORTUNITY_DIRECTION -> ENUM_SIGNAL_TYPE ICI - le
   // TSE ne connaît rien du module Opportunity (voir en-tête de
   // TradeScenarioEngine.mqh Révision 1).
   //
   // Retourne le nombre de candidats effectivement dispatchés lors de
   // cet appel (0 si rien de nouveau).
   //---------------------------------------------------------------
   int               ProcessTick(COpportunityManager &manager, CTradeScenarioEngine &tse,
                                 const SScenarioContext &ctx, SOpportunityDispatchResult &resultsOut[])
     {
      ArrayResize(resultsOut, 0);
      int dispatchedThisTick = 0;

      int total = manager.GetTriggeredCount();
      for(int i = 0; i < total; i++)
        {
         SOpportunityCandidate candidate;
         if(!manager.GetTriggeredAt(i, candidate))
            continue;
         if(IsAlreadyDispatched(candidate.id))
            continue;

         ENUM_SIGNAL_TYPE direction = (candidate.direction == OPPORTUNITY_DIRECTION_BUY) ? SIGNAL_BUY : SIGNAL_SELL;

         SScenarioVerdict  verdict;
         SScenarioDecision decision;
         tse.EvaluateOpportunity(ctx, direction, candidate.id, verdict, decision, candidate.creationReason);

         MarkDispatched(candidate.id);
         dispatchedThisTick++;

         int n = ArraySize(resultsOut);
         ArrayResize(resultsOut, n + 1);
         resultsOut[n].candidate = candidate;
         resultsOut[n].verdict   = verdict;
         resultsOut[n].decision  = decision;
        }

      return(dispatchedThisTick);
     }
  };

#endif // OPPORTUNITYPIPELINE_MQH
//+------------------------------------------------------------------+