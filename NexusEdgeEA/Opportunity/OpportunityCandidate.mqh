//+------------------------------------------------------------------+
//|                                      OpportunityCandidate.mqh       |
//|                                      NexusEdgeEA - V4.1-P1         |
//|                                                                    |
//| Fabrique de candidats + règles de transition d'état STRUCTURELLES  |
//| (pures, sans effet de bord, sans stockage). Ne connaît AUCUNE       |
//| politique métier (âge, doublon, sélection) - cette classe répond   |
//| uniquement à la question "cette transition est-elle possible du    |
//| point de vue de la forme du cycle de vie ?", jamais "est-ce que    |
//| CE candidat doit expirer maintenant ?" (ça, c'est le rôle de       |
//| COpportunityManager, voir OpportunityManager.mqh).                 |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef OPPORTUNITYCANDIDATE_MQH
#define OPPORTUNITYCANDIDATE_MQH

#include "OpportunityTypes.mqh"

class COpportunityCandidateFactory
  {
private:
   static long       s_nextSeq;

public:
   //---------------------------------------------------------------
   // Construit un candidat CREATED. zoneLow/zoneHigh sont normalisés
   // (min/max) pour ne jamais dépendre de l'ordre d'appel.
   // P1 Révision 1 : createdBarIndex remplace createdTime.
   //---------------------------------------------------------------
   static SOpportunityCandidate Create(const string symbol, const ENUM_OPPORTUNITY_DIRECTION direction,
                                       const string sourceType, const string creationReason,
                                       const double zoneLow, const double zoneHigh,
                                       const int createdBarIndex)
     {
      SOpportunityCandidate c;
      s_nextSeq++;
      c.id              = StringFormat("OP-%I64d", s_nextSeq);
      c.symbol          = symbol;
      c.direction       = direction;
      c.createdBarIndex = createdBarIndex;
      c.state           = OPPORTUNITY_STATE_CREATED;
      c.sourceType      = sourceType;
      c.creationReason  = creationReason;
      c.zoneLow         = MathMin(zoneLow, zoneHigh);
      c.zoneHigh        = MathMax(zoneLow, zoneHigh);
      c.triggerPrice    = 0.0; // P1 Révision 3 - non déclenché à la création
      return(c);
     }

   //---------------------------------------------------------------
   // Un état est TERMINAL s'il ne peut plus jamais transitionner.
   // Seul CREATED est non terminal dans ce cycle de vie à 4 états.
   //---------------------------------------------------------------
   static bool       IsTerminal(const ENUM_OPPORTUNITY_STATE state)
     {
      return(state == OPPORTUNITY_STATE_TRIGGERED ||
             state == OPPORTUNITY_STATE_REJECTED   ||
             state == OPPORTUNITY_STATE_EXPIRED);
     }

   //---------------------------------------------------------------
   // Règle structurelle unique du cycle de vie : la SEULE transition
   // valide est CREATED -> un état terminal. Aucun retour en arrière,
   // aucune transition terminal -> terminal, aucune transition
   // terminal -> CREATED.
   //---------------------------------------------------------------
   static bool       CanTransition(const ENUM_OPPORTUNITY_STATE from, const ENUM_OPPORTUNITY_STATE to)
     {
      if(from != OPPORTUNITY_STATE_CREATED)
         return(false);
      return(to == OPPORTUNITY_STATE_TRIGGERED ||
             to == OPPORTUNITY_STATE_REJECTED   ||
             to == OPPORTUNITY_STATE_EXPIRED);
     }

   //---------------------------------------------------------------
   // Test géométrique pur : le prix est-il dans la zone du candidat ?
   // Utilisé par COpportunityManager::EvaluatePrice() pour le
   // déclenchement tick-par-tick basé sur la zone (jamais sur un id).
   //---------------------------------------------------------------
   static bool       PriceInZone(const SOpportunityCandidate &c, const double price)
     {
      return(price >= c.zoneLow && price <= c.zoneHigh);
     }
  };
long COpportunityCandidateFactory::s_nextSeq = 0;

#endif // OPPORTUNITYCANDIDATE_MQH
//+------------------------------------------------------------------+