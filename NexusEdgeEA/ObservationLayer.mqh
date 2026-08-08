//+------------------------------------------------------------------+
//|                                            ObservationLayer.mqh    |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.9.2 - Incrément I2 : Capture réelle Décision + Exécution. |
//|                                                                    |
//| RÔLE UNIQUE, STRICTEMENT BORNÉ (voir mission V3.9.2 §4) :           |
//| transformer un fait déjà produit par le Trading Engine             |
//| (SScenarioVerdict, ou les paramètres d'une exécution réelle) en un  |
//| SResearchEvent (contrat I1, non modifié), puis le transmettre à     |
//| CResearchDataLayer. AUCUN calcul de score, AUCUNE statistique,      |
//| AUCUNE interprétation du verdict, AUCUN stockage interne permanent -|
//| voir la seule exception documentée ci-dessous (pont de             |
//| corrélation, transitoire, pas un état métier).                      |
//|                                                                    |
//| PÉRIMÈTRE : cinq familles à ce stade - DECISION et EXECUTION_OPEN/  |
//| EXECUTION_CLOSE (Incrément I2, Sprint V3.9.2), CONTEXT (Incrément   |
//| I3, Sprint V3.9.3.3), PROTECTION (Incrément I4, Sprint V3.9.4), et   |
//| OUTCOME (Incrément I5, Sprint V3.9.4 - ajout additif, aucune        |
//| méthode I2/I3/I4 supprimée). OUTCOME est désormais le DERNIER        |
//| événement de la séquence d'un trade - voir l'ajustement du pont      |
//| documenté sur CaptureExecutionClose()/CaptureOutcome() ci-dessous.   |
//|                                                                    |
//| GESTION DES IDENTIFIANTS (V3.8.3 §6, tranché explicitement ici) :   |
//|   - correlationId = un "opportunityId" généré localement à chaque   |
//|     décision (ex: "OPP-42") - identique entre l'événement DECISION  |
//|     et l'événement EXECUTION_OPEN qui en découle, si un trade       |
//|     s'ouvre réellement. Généré même si la couche est désactivée     |
//|     (coût nul, garde la signature d'appel stable).                  |
//|   - tradeId (le ticket broker) n'est PAS un champ de SResearchEvent |
//|     (I1 validé, non modifié) - il est porté dans le "payload" de    |
//|     EXECUTION_OPEN/EXECUTION_CLOSE, conformément à la généricité de |
//|     ce champ déjà actée en I1.                                      |
//|                                                                    |
//| PONT DE CORRÉLATION OUVERTURE -> CLÔTURE, SEULE EXCEPTION AU        |
//| "AUCUN STOCKAGE INTERNE" : une petite table transitoire             |
//| (ticket -> opportunityId), alimentée à CaptureExecutionOpen() et    |
//| VIDÉE (l'entrée est retirée) dès sa consommation par                |
//| CaptureExecutionClose(). Ce n'est pas un état métier ni une         |
//| donnée permanente - c'est exactement le même patron déjà validé et  |
//| accepté pour CShadowAnalytics (Sprint V3.6), appliqué ici au même   |
//| besoin structurel (relier une ouverture à sa clôture, sans          |
//| dépendre du chantier gelé CTradeLifecycleTracker).                  |
//|                                                                    |
//| DÉSACTIVATION (Test 4, V3.9.2) : un simple indicateur booléen        |
//| (m_enabled), jamais un Feature Flag gouvernant une décision - ce     |
//| module n'influence aucune décision, la règle "pas de nouveau        |
//| Feature Flag" (V3.0) ne s'applique donc pas ici de la même façon ;   |
//| il s'agit uniquement d'un interrupteur d'observation. Quand         |
//| désactivé, AUCUNE écriture n'a lieu, mais CaptureDecision() continue|
//| de retourner un opportunityId valide (calcul local, sans coût,      |
//| pour que le site d'appel n'ait jamais à changer de comportement     |
//| selon l'état du flag).                                               |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef OBSERVATIONLAYER_MQH
#define OBSERVATIONLAYER_MQH

#include "ResearchDataLayer.mqh"
#include "V3Types.mqh"
#include "Utilities.mqh"

class CObservationLayer
  {
private:
   CResearchDataLayer *m_rdl;          // Reference non proprietaire - possedee par l'orchestrateur, meme convention que tous les modules V3
   bool                m_enabled;
   string              m_strategyId;
   string              m_accountId;
   ulong               m_opportunityCounter;

   // Pont transitoire ouverture -> cloture (voir en-tete) - jamais persistant, jamais un etat metier
   ulong               m_bridgeTicket[];
   string              m_bridgeCorrelationId[];

   string            GenerateOpportunityId()
     {
      m_opportunityCounter++;
      return(StringFormat("OPP-%I64u", m_opportunityCounter));
     }

   int               FindBridgeIndex(const ulong ticket) const
     {
      for(int i = 0; i < ArraySize(m_bridgeTicket); i++)
         if(m_bridgeTicket[i] == ticket)
            return(i);
      return(-1);
     }

   void              RemoveBridgeIndex(const int idx)
     {
      int last = ArraySize(m_bridgeTicket) - 1;
      if(idx < 0 || idx > last)
         return;
      m_bridgeTicket[idx]        = m_bridgeTicket[last];
      m_bridgeCorrelationId[idx] = m_bridgeCorrelationId[last];
      ArrayResize(m_bridgeTicket, last);
      ArrayResize(m_bridgeCorrelationId, last);
     }

   //---------------------------------------------------------------
   // PeekBridgeCorrelationId - SPRINT V3.9.4, Incrément I4. Lecture SANS
   // suppression du pont deja construit pour I2 - une position peut
   // recevoir plusieurs evenements PROTECTION au fil de sa vie, bien
   // avant sa cloture (qui, elle, consomme et retire l'entree via
   // CaptureExecutionClose deja existant, inchange). Reutilisation
   // stricte du meme pont, pas un nouveau mecanisme de correlation.
   //---------------------------------------------------------------
   string            PeekBridgeCorrelationId(const ulong ticket) const
     {
      int idx = FindBridgeIndex(ticket);
      return(idx >= 0 ? m_bridgeCorrelationId[idx] : "");
     }

public:
                     CObservationLayer()
     {
      m_rdl               = NULL;
      m_enabled           = false;
      m_strategyId        = "";
      m_accountId         = "";
      m_opportunityCounter = 0;
     }

   bool              Init(CResearchDataLayer *rdl, const bool enabled, const string strategyId, const string accountId)
     {
      m_rdl        = rdl;
      m_enabled    = enabled;
      m_strategyId = strategyId;
      m_accountId  = accountId;
      return(true);
     }

   bool              IsEnabled() const { return(m_enabled); }

   //---------------------------------------------------------------
   // CaptureDecision - traduit un SScenarioVerdict deja produit par
   // CTradeScenarioEngine::EvaluateEntry() en un evenement DECISION.
   // Retourne l'opportunityId genere - a reutiliser IMMEDIATEMENT,
   // dans le meme tick, par l'appelant si un trade s'ouvre reellement
   // (voir CaptureExecutionOpen). Ne recalcule rien : chaque champ du
   // payload provient directement de "verdict", deja calcule.
   //---------------------------------------------------------------
   string            CaptureDecision(const SScenarioVerdict &verdict, const ENUM_SIGNAL_TYPE direction, const string symbolId)
     {
      string opportunityId = GenerateOpportunityId(); // Genere que le flag soit actif ou non - cout nul, signature d'appel stable

      if(!m_enabled || m_rdl == NULL)
         return(opportunityId);

      string payload = StringFormat(
         "direction=%s;authorized=%s;confidence=%.4f;scenarioStrength=%s;htfOk=%s;structureOk=%s;orderBlockOk=%s;fvgOk=%s;reason=%s",
         CUtilities::SignalTypeToString(direction),
         verdict.authorized ? "true" : "false",
         verdict.confidence,
         verdict.scenarioStrength,
         verdict.htfOk ? "true" : "false",
         verdict.structureOk ? "true" : "false",
         verdict.orderBlockOk ? "true" : "false",
         verdict.fvgOk ? "true" : "false",
         verdict.reason);

      SResearchEvent ev;
      m_rdl.WriteEvent("DECISION", m_strategyId, m_accountId, symbolId, opportunityId, payload, ev);
      return(opportunityId);
     }

   //---------------------------------------------------------------
   // CaptureExecutionOpen - a appeler UNIQUEMENT si une position a
   // ete reellement ouverte (ticket obtenu apres succes broker) -
   // jamais appelee en cas de refus (Validator/TradeManager), ce qui
   // garantit naturellement la distinction du Cas B (verdict autorise
   // + ordre refuse => aucun evenement EXECUTION_OPEN, aucune erreur).
   //---------------------------------------------------------------
   void              CaptureExecutionOpen(const string opportunityId, const ulong ticket, const string symbolId,
                                          const double volume, const double entryPrice, const double slInitial,
                                          const double tpInitial, const ENUM_SIGNAL_TYPE direction)
     {
      if(!m_enabled || m_rdl == NULL)
         return;

      // Pont ouverture -> cloture : uniquement alimente si la couche est active
      int n = ArraySize(m_bridgeTicket);
      ArrayResize(m_bridgeTicket, n + 1);
      ArrayResize(m_bridgeCorrelationId, n + 1);
      m_bridgeTicket[n]        = ticket;
      m_bridgeCorrelationId[n] = opportunityId;

      string payload = StringFormat(
         "ticket=%I64u;symbol=%s;volume=%.2f;entryPrice=%.5f;slInitial=%.5f;tpInitial=%.5f;direction=%s",
         ticket, symbolId, volume, entryPrice, slInitial, tpInitial, CUtilities::SignalTypeToString(direction));

      SResearchEvent ev;
      m_rdl.WriteEvent("EXECUTION_OPEN", m_strategyId, m_accountId, symbolId, opportunityId, payload, ev);
     }

   //---------------------------------------------------------------
   // CaptureExecutionClose - reprend le correlationId (opportunityId)
   // depose au pont a l'ouverture, pour que DECISION/EXECUTION_OPEN/
   // EXECUTION_CLOSE partagent le meme correlationId de bout en bout
   // (exigence explicite du Cas A, V3.9.2). Si aucun pont n'existe
   // (position ouverte par une session anterieure, par exemple),
   // correlationId reste vide - honnete, pas invente.
   //---------------------------------------------------------------
   void              CaptureExecutionClose(const ulong ticket, const string symbolId, const double exitPrice,
                                           const bool isWin, const double profit, const string closeReason)
     {
      if(!m_enabled || m_rdl == NULL)
         return;

      // AJUSTEMENT SPRINT V3.9.4 (Incrément I5) : ce n'est plus
      // EXECUTION_CLOSE qui consomme (retire) l'entree du pont -
      // OUTCOME devient desormais le veritable dernier evenement d'un
      // trade (sequence DECISION -> CONTEXT -> EXECUTION_OPEN ->
      // PROTECTION(0..N) -> EXECUTION_CLOSE -> OUTCOME). Lecture SANS
      // suppression ici - voir CaptureOutcome() plus bas, seul
      // point qui retire desormais l'entree.
      string correlationId = PeekBridgeCorrelationId(ticket);

      string payload = StringFormat(
         "ticket=%I64u;exitPrice=%.5f;isWin=%s;profit=%.2f;closeReason=%s",
         ticket, exitPrice, isWin ? "true" : "false", profit, closeReason);

      SResearchEvent ev;
      m_rdl.WriteEvent("EXECUTION_CLOSE", m_strategyId, m_accountId, symbolId, correlationId, payload, ev);
     }

   //---------------------------------------------------------------
   // CaptureContext - SPRINT V3.9.3.3, Incrément I3. Traduit un
   // SMarketContext deja calcule (CMarketContext::GetContext(), aucun
   // recalcul) en un evenement CONTEXTE, partage le MEME opportunityId
   // que l'evenement DECISION correspondant (meme instant de capture,
   // meme tick - voir NexusEdgeEA.mq5) - pas un nouveau mecanisme de
   // correlation, reutilisation directe de celui deja construit pour
   // I2.
   //
   // "tokyoActive"/"londonActive"/"newyorkActive" : deja calcules par
   // CSessions (CFilters les consulte deja au meme instant) - transmis
   // en valeur, jamais recalcules ici. La construction du libelle de
   // session est un formatage de texte, pas un calcul de marche - au
   // meme titre que le formatage deja present dans CaptureDecision().
   //---------------------------------------------------------------
   void              CaptureContext(const string opportunityId, const SMarketContext &context, const double spreadPoints,
                                    const bool tokyoActive, const bool londonActive, const bool newyorkActive,
                                    const string symbolId)
     {
      if(!m_enabled || m_rdl == NULL)
         return;

      string sessionLabel = "";
      if(tokyoActive)
         sessionLabel += "Tokyo";
      if(londonActive)
         sessionLabel += (sessionLabel != "" ? "+" : "") + "London";
      if(newyorkActive)
         sessionLabel += (sessionLabel != "" ? "+" : "") + "NewYork";
      if(sessionLabel == "")
         sessionLabel = "None";

      string payload = StringFormat(
         "trend=%s;volatility=%s;momentum=%.2f;atr=%.5f;spread=%.1f;session=%s",
         CUtilities::TrendStateToString(context.trend),
         CUtilities::VolatilityStateToString(context.volatility),
         context.momentum,
         context.atrValue,
         spreadPoints,
         sessionLabel);

      SResearchEvent ev;
      m_rdl.WriteEvent("CONTEXT", m_strategyId, m_accountId, symbolId, opportunityId, payload, ev);
     }

   //---------------------------------------------------------------
   // CaptureProtection - SPRINT V3.9.4, Incrément I4. Traduit un
   // événement de gestion de position déjà décidé et déjà appliqué
   // (modification SL, fermeture forcée, clôture partielle) en un
   // événement PROTECTION - aucun recalcul, aucune interprétation du
   // mécanisme gagnant (déjà déterminé par ComputeFinalStopLevel() ou
   // la logique de clôture partielle, hors de cette couche).
   //
   // "actionType" : distingue explicitement les trois cas demandés -
   // "SL_MODIFIED" (BreakEven/Trailing/Structure/PeakPercent, le
   // mécanisme précis reste dans "mechanismSource"), "FORCED_CLOSE"
   // (Emergency), "PARTIAL_CLOSE". Une seule méthode, un seul contrat -
   // pas trois méthodes différentes pour trois variantes du même
   // événement de gestion.
   //
   // correlationId : retrouvé via PeekBridgeCorrelationId() (lecture
   // SANS suppression - une position peut recevoir plusieurs
   // événements PROTECTION avant sa clôture). Si aucune entrée n'existe
   // au pont (position survivante à un redémarrage), correlationId
   // reste vide - honnête, pas inventé, même convention déjà appliquée
   // à CaptureExecutionClose().
   //---------------------------------------------------------------
   void              CaptureProtection(const ulong ticket, const string symbolId, const string actionType,
                                       const string mechanismSource, const double oldSL, const double newSL,
                                       const double currentProfitMoney, const string decisionNote)
     {
      if(!m_enabled || m_rdl == NULL)
         return;

      string correlationId = PeekBridgeCorrelationId(ticket);

      string payload = StringFormat(
         "ticket=%I64u;actionType=%s;mechanism=%s;oldSL=%.5f;newSL=%.5f;profitAtDecision=%.2f;note=%s",
         ticket, actionType, mechanismSource, oldSL, newSL, currentProfitMoney, decisionNote);

      SResearchEvent ev;
      m_rdl.WriteEvent("PROTECTION", m_strategyId, m_accountId, symbolId, correlationId, payload, ev);
     }

   //---------------------------------------------------------------
   // CaptureOutcome - SPRINT V3.9.4, Incrément I5. Le DERNIER
   // événement d'un trade (voir en-tête, séquence attendue) - traduit
   // le bilan final déjà entièrement déterminé (broker confirmé,
   // statistiques internes terminées) en un événement OUTCOME. Aucun
   // recalcul : chaque valeur est transmise telle quelle par
   // l'appelant, qui les lit dans SPositionRecord et l'historique
   // broker déjà consolidés.
   //
   // "result" : "WIN" (profit net > 0), "LOSS" (profit net < 0), "BE"
   // (profit net exactement égal à 0 - convention explicite, pas une
   // bande de tolérance inventée) - la classification elle-même est
   // effectuée par l'appelant, cette méthode se contente de transmettre
   // l'étiquette déjà décidée.
   //
   // correlationId : SEUL point qui consomme désormais (retire)
   // l'entrée du pont - EXECUTION_CLOSE, depuis cet incrément, se
   // contente de la lire sans la retirer (voir CaptureExecutionClose
   // ci-dessus). Si aucune entrée n'existe (position survivante à un
   // redémarrage), correlationId reste vide - honnête, pas inventé.
   //---------------------------------------------------------------
   void              CaptureOutcome(const ulong ticket, const string symbolId, const string result,
                                    const double grossProfit, const double netProfit, const double swap,
                                    const double commission, const int durationSeconds, const double mfe,
                                    const double mae, const double rrRealized, const string finalReason,
                                    const datetime openTime, const datetime closeTime)
     {
      if(!m_enabled || m_rdl == NULL)
         return;

      string correlationId = "";
      int    idx           = FindBridgeIndex(ticket);
      if(idx >= 0)
        {
         correlationId = m_bridgeCorrelationId[idx];
         RemoveBridgeIndex(idx); // OUTCOME est le dernier evenement du trade - le pont ne sert plus apres lui
        }

      string payload = StringFormat(
         "ticket=%I64u;result=%s;grossProfit=%.2f;netProfit=%.2f;swap=%.2f;commission=%.2f;durationSeconds=%d;mfe=%.5f;mae=%.5f;rrRealized=%.4f;finalReason=%s;openTime=%s;closeTime=%s",
         ticket, result, grossProfit, netProfit, swap, commission, durationSeconds, mfe, mae, rrRealized,
         finalReason, TimeToString(openTime, TIME_DATE | TIME_SECONDS), TimeToString(closeTime, TIME_DATE | TIME_SECONDS));

      SResearchEvent ev;
      m_rdl.WriteEvent("OUTCOME", m_strategyId, m_accountId, symbolId, correlationId, payload, ev);
     }
  };

#endif // OBSERVATIONLAYER_MQH
//+------------------------------------------------------------------+