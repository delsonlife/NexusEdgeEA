//+------------------------------------------------------------------+
//|                                       VirtualTradeTypes.mqh         |
//|                                      NexusEdgeEA - V4.1-P3.1bis    |
//|                                                                    |
//| ISOLATION TOTALE (même discipline que le module Opportunity) :    |
//| ce fichier ne dépend d'AUCUN module du Trading Engine. Réutilise   |
//| uniquement ENUM_OPPORTUNITY_DIRECTION (décision de revue          |
//| explicite : éviter un 3e type de direction redondant).             |
//|                                                                    |
//| GROUPES DE MÉTRIQUES (revue P3.1bis) :                             |
//|   Groupe A (alimenté dès Niveau 1)   : exitReason, mfe, mae         |
//|   Groupe B (API préparée, Niveau 2)  : entryScore, exitScore,       |
//|     peakScoreAfterEntry (= "MaximumScoreAfterEntry"),               |
//|     lowestScoreAfterEntry, scoreEvolution[] - champs présents et    |
//|     fonctionnels dès Niveau 1, mais non alimentés tant que          |
//|     VirtualTradeFeed n'appelle pas UpdateBar() avec un score réel.  |
//|   Groupe C (réservé, NON DÉFINI)     : tradeHealth,                 |
//|     protectionRecommendation - chaînes vides tant que ces           |
//|     concepts n'auront pas été spécifiés explicitement (V4.2/V4.3   |
//|     probablement). AUCUN calcul fictif.                             |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef VIRTUALTRADETYPES_MQH
#define VIRTUALTRADETYPES_MQH

#include "../Opportunity/OpportunityTypes.mqh" // ENUM_OPPORTUNITY_DIRECTION uniquement (réutilisation décidée en revue)

//+------------------------------------------------------------------+
//| Cycle de vie - même discipline que ENUM_OPPORTUNITY_STATE : un    |
//| seul état non terminal (OPEN), aucun retour en arrière.            |
//|                                                                    |
//|   OPEN ──┬──► WIN       (terminal, TP touché)                      |
//|          ├──► LOSS      (terminal, SL touché - ou ambiguïté        |
//|          │               intra-bougie, voir Worst Case Principle)  |
//|          └──► TIMEOUT   (terminal, âge max dépassé sans TP/SL)     |
//+------------------------------------------------------------------+
enum ENUM_VIRTUAL_TRADE_STATE
  {
   VIRTUAL_TRADE_OPEN,
   VIRTUAL_TRADE_WIN,
   VIRTUAL_TRADE_LOSS,
   VIRTUAL_TRADE_TIMEOUT
  };

//+------------------------------------------------------------------+
//| Trade virtuel - objet passif, observé par CVirtualTradeTracker,   |
//| jamais par lui-même. Ne connaît aucune politique (timeout,         |
//| ambiguïté intra-bougie) - ces responsabilités appartiennent au     |
//| Tracker, même principe que SOpportunityCandidate/OpportunityManager.|
//+------------------------------------------------------------------+
struct SVirtualTrade
  {
   string                     id;              // "VT-<n>"
   string                     symbol;
   ENUM_OPPORTUNITY_DIRECTION direction;
   double                     entryPrice;
   double                     slPrice;
   double                     tpPrice;
   int                        openBarIndex;
   ENUM_VIRTUAL_TRADE_STATE   state;

   // --- Groupe A (Niveau 1, alimenté) ---
   string                     exitReason;      // "WIN (TP)", "LOSS (SL)", "LOSS (ambiguite intra-bougie, Worst Case)", "TIMEOUT", "" tant qu'OPEN
   double                     mfe;             // distance de prix favorable maximale depuis l'entrée
   double                     mae;             // distance de prix adverse maximale depuis l'entrée
   int                        closeBarIndex;   // -1 tant qu'OPEN

   // --- Champs internes de calcul MFE/MAE (bornes courantes, mises à
   // jour à chaque UpdateBar - jamais exposées comme "la" donnée, mfe/mae
   // ci-dessus sont les distances dérivées, déjà prêtes à consommer) ---
   double                     bestFavorablePrice;
   double                     worstAdversePrice;

   // --- Groupe B (API préparée dès Niveau 1, NON alimentée tant que
   // VirtualTradeFeed n'envoie pas de score réel à UpdateBar()) ---
   double                     entryScore;             // confidence TSE au déclenchement (EMPTY_VALUE si non fourni)
   double                     exitScore;              // confidence TSE au moment de la clôture (EMPTY_VALUE si non fourni)
   double                     peakScoreAfterEntry;     // = "MaximumScoreAfterEntry" (revue P3.1bis - fusion volontaire, même donnée)
   double                     lowestScoreAfterEntry;
   double                     scoreEvolution[];        // historique des scores fournis à chaque UpdateBar - vide si jamais alimenté

   // --- Groupe C (réservé, NON DÉFINI - aucun calcul fictif) ---
   string                     tradeHealthReserved;             // toujours "" en Niveau 1/2 - concept non spécifié
   string                     protectionRecommendationReserved; // toujours "" en Niveau 1/2 - concept non spécifié
  };

string VirtualTradeStateToString(const ENUM_VIRTUAL_TRADE_STATE state)
  {
   switch(state)
     {
      case VIRTUAL_TRADE_OPEN:    return("OPEN");
      case VIRTUAL_TRADE_WIN:     return("WIN");
      case VIRTUAL_TRADE_LOSS:    return("LOSS");
      case VIRTUAL_TRADE_TIMEOUT: return("TIMEOUT");
      default:                    return("UNKNOWN");
     }
  }

#endif // VIRTUALTRADETYPES_MQH
//+------------------------------------------------------------------+