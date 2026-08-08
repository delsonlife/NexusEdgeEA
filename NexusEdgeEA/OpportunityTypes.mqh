//+------------------------------------------------------------------+
//|                                          OpportunityTypes.mqh      |
//|                                      NexusEdgeEA - V4.1-P1         |
//|                                                                    |
//| ISOLATION TOTALE (exigence explicite du sprint, voir              |
//| ARCHITECTURE_LOCK.md §5, phase P1) : ce fichier ne dépend d'AUCUN  |
//| module du Trading Engine - ni Types.mqh, ni MarketStructure, ni    |
//| SignalManager, ni TSE, ni TradeManager, ni Research. Uniquement    |
//| des types MQL5 natifs.                                             |
//|                                                                    |
//| PRINCIPE : SOpportunityCandidate est un objet PASSIF. Il décrit    |
//| son identité, son origine et sa zone - il ne connaît AUCUNE        |
//| politique (expiration, déduplication, sélection, arbitrage). Ces   |
//| responsabilités appartiennent exclusivement à COpportunityManager  |
//| (OpportunityManager.mqh). Même principe déjà appliqué dans le      |
//| projet avec IProtectionLevelCalculator / CProfitProtectionEngine   |
//| et les couches d'observation SMC / CTradeScenarioEngine.           |
//|                                                                    |
//| Volontairement ABSENTS de ce fichier (voir spec validée) :         |
//|   - expiresAt   -> dérivé d'une politique, appartient au Manager   |
//|   - dedupKey     -> figerait une stratégie de déduplication         |
//|                     encore inconnue ; IsDuplicate() est une         |
//|                     méthode du Manager, pas une donnée du candidat |
//|                                                                    |
//| P1 RÉVISION 1 (avant tout branchement réel, voir                   |
//| ARCHITECTURE_LOCK.md) : createdTime (datetime) remplacé par        |
//| createdBarIndex (int). Le robot raisonne en bougies (BOS/CHOCH/    |
//| structures), jamais en secondes - une politique d'expiration en    |
//| durée réelle serait faussée par les week-ends et les ralentis de   |
//| marché. Ajout de creationReason (voir plus bas).                   |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef OPPORTUNITYTYPES_MQH
#define OPPORTUNITYTYPES_MQH

//+------------------------------------------------------------------+
//| Direction d'un candidat - type propre au module Opportunity,      |
//| volontairement PAS ENUM_SIGNAL_TYPE (Types.mqh) : le module ne     |
//| doit dépendre de rien du Trading Engine, même d'un simple enum.    |
//+------------------------------------------------------------------+
enum ENUM_OPPORTUNITY_DIRECTION
  {
   OPPORTUNITY_DIRECTION_BUY,
   OPPORTUNITY_DIRECTION_SELL
  };

//+------------------------------------------------------------------+
//| Cycle de vie - 4 états, chacun correspondant à un événement RÉEL. |
//| Aucun retour en arrière. CREATED est le seul état non terminal :   |
//| tout candidat créé est par définition déjà valide (les Observers   |
//| ne produisent que des candidats valides) - il n'existe donc aucun  |
//| état intermédiaire "en cours de validation".                       |
//|                                                                    |
//|   CREATED ──┬──► TRIGGERED   (terminal)                            |
//|             ├──► REJECTED    (terminal)                            |
//|             └──► EXPIRED     (terminal)                            |
//+------------------------------------------------------------------+
enum ENUM_OPPORTUNITY_STATE
  {
   OPPORTUNITY_STATE_CREATED,
   OPPORTUNITY_STATE_TRIGGERED,
   OPPORTUNITY_STATE_REJECTED,
   OPPORTUNITY_STATE_EXPIRED
  };

//+------------------------------------------------------------------+
//| Candidat d'opportunité - objet passif, sans comportement propre.  |
//| Contient uniquement ce qui appartient réellement au candidat :     |
//| son identité, son origine, sa zone. Rien de dérivé, rien de        |
//| politique.                                                          |
//|                                                                    |
//| creationReason (P2A) : décrit POURQUOI ce candidat a été créé,     |
//| jamais une interprétation causale au-delà de ce que le code fait   |
//| réellement. Valeurs actuelles, strictement alignées sur le         |
//| comportement RÉEL des détecteurs (rien d'inventé) :                 |
//|   sourceType="OrderBlock" -> creationReason="BOS"                  |
//|     (OrderBlockDetector.mqh ne crée JAMAIS un Order Block sur un   |
//|     CHOCH ou un Sweep - uniquement sur transition BOS)             |
//|   sourceType="FVG"        -> creationReason="FVG"                  |
//|     (le FVG est une géométrie locale à 3 bougies, indépendante de  |
//|     BOS/CHOCH/Sweep - CFVGDetector ne consulte JAMAIS              |
//|     CMarketStructure ; associer un événement structurel ici serait |
//|     une CORRÉLATION présentée à tort comme une CAUSALITÉ)          |
//+------------------------------------------------------------------+
struct SOpportunityCandidate
  {
   string                     id;             // "OP-<n>", généré par COpportunityCandidateFactory, jamais réutilisé
   string                     symbol;
   ENUM_OPPORTUNITY_DIRECTION direction;
   int                        createdBarIndex; // P1 Révision 1 - remplace createdTime (datetime)
   ENUM_OPPORTUNITY_STATE     state;
   string                     sourceType;      // ex: "OrderBlock", "FVG" - texte libre, aucun lien direct vers un module
   string                     creationReason;  // voir commentaire ci-dessus - jamais une inférence, toujours un fait du code
   double                     zoneLow;
   double                     zoneHigh;
  };

//+------------------------------------------------------------------+
//| Utilitaires de conversion texte (journalisation / tests)           |
//+------------------------------------------------------------------+
string OpportunityStateToString(const ENUM_OPPORTUNITY_STATE state)
  {
   switch(state)
     {
      case OPPORTUNITY_STATE_CREATED:   return("CREATED");
      case OPPORTUNITY_STATE_TRIGGERED: return("TRIGGERED");
      case OPPORTUNITY_STATE_REJECTED:  return("REJECTED");
      case OPPORTUNITY_STATE_EXPIRED:   return("EXPIRED");
      default:                          return("UNKNOWN");
     }
  }

string OpportunityDirectionToString(const ENUM_OPPORTUNITY_DIRECTION dir)
  {
   return(dir == OPPORTUNITY_DIRECTION_BUY ? "BUY" : "SELL");
  }

#endif // OPPORTUNITYTYPES_MQH
//+------------------------------------------------------------------+