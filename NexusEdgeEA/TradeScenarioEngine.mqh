//+------------------------------------------------------------------+
//| TradeScenarioEngine.mqh                                            |
//| NexusEdgeEA                                                        |
//|                                                                    |
//| RÉVISION 1 (V4.1-P2B) — À FUSIONNER PAR L'UTILISATEUR DANS SA      |
//| COPIE LOCALE, PAS APPLIQUÉE AUTOMATIQUEMENT. Voir                  |
//| ARCHITECTURE_LOCK.md §5bis pour la justification complète.         |
//|                                                                    |
//| CE QUI CHANGE PAR RAPPORT AU SPRINT V3.5 (comportement de          |
//| EvaluateEntry() STRICTEMENT INCHANGÉ, vérifié champ par champ) :   |
//|   1. La logique des 4 critères (auparavant inline dans             |
//|      EvaluateEntry) est extraite dans un cœur privé PUR,           |
//|      ComputeVerdict() - sans compteur, sans effet de bord. Ceci    |
//|      évite qu'un futur ajustement des critères ne soit appliqué    |
//|      à un seul des deux pipelines par erreur.                       |
//|   2. EvaluateEntry() appelle désormais ComputeVerdict() puis met   |
//|      à jour SES PROPRES compteurs (m_verdictsProduced, etc.) -     |
//|      comportement observable identique à avant.                    |
//|   3. NOUVEAU : EvaluateOpportunity() - second point d'entrée       |
//|      public, AJOUTÉ (jamais un remplacement de EvaluateEntry).     |
//|      Pipeline Shadow B, totalement indépendant du Pipeline Shadow  |
//|      A (compteurs séparés : m_opp*). Reçoit un opportunityId       |
//|      (string) pour la traçabilité de bout en bout (objectif P2B :  |
//|      "Opportunity #42 -> Verdict = ACCEPTED/REJECTED") - préfixé   |
//|      dans verdictOut.reason, même convention que triggerReason.    |
//|      Ne connaît RIEN du type SOpportunityCandidate (module         |
//|      Opportunity) - reçoit uniquement des valeurs déjà génériques  |
//|      (ENUM_SIGNAL_TYPE, string), exactement comme EvaluateEntry()  |
//|      ne connaît rien de SSignalResult (CSignalManager).             |
//|   4. NOUVEAU : GetOpportunityShadowReport() - même esprit que      |
//|      GetShadowReport(), pour le Pipeline B uniquement.              |
//|                                                                    |
//| RIEN D'AUTRE N'EST MODIFIÉ. EvaluateManagement(), HasEntryAuthority(),|
//| HasManagementAuthority(), Init() sont identiques au Sprint V3.5.   |
//|                                                                    |
//| ============= EN-TÊTE ORIGINALE (Sprint V3.5), CONSERVÉE ========= |
//|                                                                    |
//| SPRINT V3.5 - Shadow Decision Engine (première logique réelle).    |
//|                                                                    |
//| RÔLE FINAL (voir ARCHITECTURE_V3.md §3.3) : l'autorité UNIQUE de   |
//| décision de tout le système V3. Répond à "le scénario est-il      |
//| toujours valide ?" puis décide de l'action à entreprendre - il ne  |
//| modifie jamais lui-même un ordre ni un SL.                         |
//|                                                                    |
//| RÈGLE DE SORTIE DU SPRINT (voir ARCHITECTURE_V3.md) : le TSE ne    |
//| pourra recevoir une autorité réelle sur les entrées (V3.6+) que si |
//| ses verdicts Shadow ont été comparés statistiquement au système    |
//| actuel sur un échantillon suffisant et démontrent un avantage      |
//| mesurable - pas avant. Ceci s'applique identiquement aux DEUX      |
//| pipelines Shadow (A: SignalManager, B: OpportunityManager) - voir  |
//| revue P2B : "lorsqu'on aura suffisamment de statistiques, on       |
//| décidera lequel conserver".                                        |
//|                                                                    |
//| LOGIQUE DE DÉCISION - déterministe, aucune pondération             |
//| statistique, aucun score IA, aucun apprentissage. Quatre critères, |
//| chacun contribuant 25% à "confidence" (score Shadow INDÉPENDANT de |
//| "authorized" - voir ci-dessous) :                                  |
//| 1) HTF aligné : htfBiasAvailable && htfBiasDirection == direction candidate|
//| 2) Structure cohérente : BOS OU CHOCH aligné (ajustement validé - pas BOS seul)|
//| 3) Order Block valide : actif, valide, aligné                      |
//| 4) FVG valide : actif, valide, aligné                              |
//| "authorized" = ET logique strict des 4 critères - pas un seuil de  |
//| confidence.                                                         |
//|                                                                    |
//| "context" : le SScenarioContext déjà construit par les couches     |
//| d'observation - AUCUN accès direct à MarketStructure/              |
//| OrderBlockDetector/FVGDetector/HTFBiasObserver.                    |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef TRADESCENARIOENGINE_MQH
#define TRADESCENARIOENGINE_MQH

#include "V3Types.mqh"

class CTradeScenarioEngine
  {
private:
   bool              m_initialized;

   bool              m_flagEnableTSE;
   bool              m_flagEnableHTFBias;
   bool              m_flagEnableStructuralManagement;

   // --- Compteurs de diagnostic (mode observation) ---
   int               m_shadowEvaluationsEntry;
   int               m_shadowEvaluationsManagement;

   // --- Statistiques Shadow PIPELINE A (Sprint V3.5) - EvaluateEntry, verdicts d'entree reels uniquement ---
   int               m_verdictsProduced;
   int               m_verdictsAuthorized;
   int               m_verdictsRefused;
   int               m_verdictsStrong;
   int               m_verdictsMedium;
   int               m_verdictsWeak;
   double            m_confidenceSum;
   int               m_refusalCountHTF;
   int               m_refusalCountStructure;
   int               m_refusalCountOrderBlock;
   int               m_refusalCountFVG;

   // --- NOUVEAU (P2B) - Statistiques Shadow PIPELINE B, EvaluateOpportunity,
   // STRUCTURELLEMENT SÉPARÉES du Pipeline A (revue P2B : "les deux
   // produisent des verdicts totalement indépendants") ---
   int               m_oppEvaluations;
   int               m_oppVerdictsProduced;
   int               m_oppVerdictsAuthorized;
   int               m_oppVerdictsRefused;
   int               m_oppVerdictsStrong;
   int               m_oppVerdictsMedium;
   int               m_oppVerdictsWeak;
   double            m_oppConfidenceSum;
   int               m_oppRefusalCountHTF;
   int               m_oppRefusalCountStructure;
   int               m_oppRefusalCountOrderBlock;
   int               m_oppRefusalCountFVG;

   //---------------------------------------------------------------
   // ComputeVerdict - CŒUR PUR (P2B, extrait de l'ancien corps de
   // EvaluateEntry SANS AUCUN changement de logique - voir en-tête).
   // Ni compteur, ni effet de bord sur l'état du moteur : les DEUX
   // méthodes publiques (EvaluateEntry, EvaluateOpportunity) appellent
   // ce cœur puis mettent chacune à jour LEURS PROPRES compteurs.
   //---------------------------------------------------------------
   void              ComputeVerdict(const SScenarioContext &context, const ENUM_SIGNAL_TYPE candidateDirection,
                                    const string triggerReason, SScenarioVerdict &verdictOut, SScenarioDecision &decisionOut) const
     {
      decisionOut.action             = ACTION_NONE;
      decisionOut.targetLevel        = 0.0;
      decisionOut.partialExitPercent = 0.0;
      decisionOut.reason             = "Shadow uniquement - aucune decision executee, voir authorized dans le verdict";

      verdictOut.status      = SCENARIO_UNKNOWN; // Non pertinent pour l'entree - voir "authorized"
      verdictOut.evaluatedAt = TimeCurrent();

      if(candidateDirection != SIGNAL_BUY && candidateDirection != SIGNAL_SELL)
        {
         verdictOut.confidence      = 0.0;
         verdictOut.authorized      = false;
         verdictOut.scenarioStrength = "";
         verdictOut.htfOk           = false;
         verdictOut.structureOk     = false;
         verdictOut.orderBlockOk    = false;
         verdictOut.fvgOk           = false;
         verdictOut.reason          = "Aucun signal candidat ce tour-ci - pas d'evaluation reelle";
         return;
        }

      ENUM_STRUCTURE_DIRECTION wanted = (candidateDirection == SIGNAL_BUY) ? DIRECTION_BULLISH : DIRECTION_BEARISH;
      string wantedStr = (candidateDirection == SIGNAL_BUY) ? "Bullish" : "Bearish";

      bool htfOk = context.htfBiasAvailable && context.htfBiasDirection == wanted;
      bool structureOk = (context.bosDetected && context.bosDirection == wantedStr) ||
                         (context.chochDetected && context.chochDirection == wantedStr);
      bool orderBlockOk = context.orderBlockActive && context.orderBlockValid && context.orderBlockDirection == wanted;
      bool fvgOk = context.fvgActive && context.fvgValid && context.fvgDirection == wanted;

      double confidence = (htfOk ? 0.25 : 0.0) + (structureOk ? 0.25 : 0.0) + (orderBlockOk ? 0.25 : 0.0) + (fvgOk ? 0.25 : 0.0);
      bool   authorized  = htfOk && structureOk && orderBlockOk && fvgOk; // Porte ET stricte
      string strength    = (confidence >= 0.75) ? "STRONG" : ((confidence >= 0.5) ? "MEDIUM" : "WEAK");

      verdictOut.confidence       = confidence;
      verdictOut.authorized       = authorized;
      verdictOut.scenarioStrength = strength;
      verdictOut.htfOk            = htfOk;
      verdictOut.structureOk      = structureOk;
      verdictOut.orderBlockOk     = orderBlockOk;
      verdictOut.fvgOk            = fvgOk;
      verdictOut.reason           = authorized ? "4/4 criteres satisfaits" : "Au moins 1 critere non satisfait - voir details par critere";
      if(triggerReason != "")
         verdictOut.reason += " | Declenchement: " + triggerReason;
     }

public:
                     CTradeScenarioEngine()
     {
      m_initialized = false;
      m_flagEnableTSE = false;
      m_flagEnableHTFBias = false;
      m_flagEnableStructuralManagement = false;
      m_shadowEvaluationsEntry = 0;
      m_shadowEvaluationsManagement = 0;
      m_verdictsProduced = 0;
      m_verdictsAuthorized = 0;
      m_verdictsRefused = 0;
      m_verdictsStrong = 0;
      m_verdictsMedium = 0;
      m_verdictsWeak = 0;
      m_confidenceSum = 0.0;
      m_refusalCountHTF = 0;
      m_refusalCountStructure = 0;
      m_refusalCountOrderBlock = 0;
      m_refusalCountFVG = 0;
      // --- NOUVEAU (P2B) ---
      m_oppEvaluations = 0;
      m_oppVerdictsProduced = 0;
      m_oppVerdictsAuthorized = 0;
      m_oppVerdictsRefused = 0;
      m_oppVerdictsStrong = 0;
      m_oppVerdictsMedium = 0;
      m_oppVerdictsWeak = 0;
      m_oppConfidenceSum = 0.0;
      m_oppRefusalCountHTF = 0;
      m_oppRefusalCountStructure = 0;
      m_oppRefusalCountOrderBlock = 0;
      m_oppRefusalCountFVG = 0;
     }

   bool              Init(const bool flagEnableTSE, const bool flagEnableHTFBias,
                          const bool flagEnableStructuralManagement)
     {
      m_flagEnableTSE = flagEnableTSE;
      m_flagEnableHTFBias = flagEnableHTFBias;
      m_flagEnableStructuralManagement = flagEnableStructuralManagement;
      m_initialized = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // EvaluateEntry - INCHANGÉ dans son comportement observable (voir
   // en-tête). Appelle désormais ComputeVerdict() puis met à jour ses
   // propres compteurs, exactement comme avant la refactorisation.
   //---------------------------------------------------------------
   void              EvaluateEntry(const SScenarioContext &context, const ENUM_SIGNAL_TYPE candidateDirection,
                                   SScenarioVerdict &verdictOut, SScenarioDecision &decisionOut,
                                   const string triggerReason = "")
     {
      m_shadowEvaluationsEntry++;

      ComputeVerdict(context, candidateDirection, triggerReason, verdictOut, decisionOut);

      if(candidateDirection != SIGNAL_BUY && candidateDirection != SIGNAL_SELL)
         return; // Pas de verdict reel - pas de comptage (identique au comportement Sprint V3.5)

      m_verdictsProduced++;
      m_confidenceSum += verdictOut.confidence;
      if(verdictOut.authorized)
         m_verdictsAuthorized++;
      else
         m_verdictsRefused++;

      if(verdictOut.scenarioStrength == "STRONG")
         m_verdictsStrong++;
      else if(verdictOut.scenarioStrength == "MEDIUM")
         m_verdictsMedium++;
      else
         m_verdictsWeak++;

      if(!verdictOut.authorized)
        {
         if(!verdictOut.htfOk) m_refusalCountHTF++;
         if(!verdictOut.structureOk) m_refusalCountStructure++;
         if(!verdictOut.orderBlockOk) m_refusalCountOrderBlock++;
         if(!verdictOut.fvgOk) m_refusalCountFVG++;
        }
     }

   //---------------------------------------------------------------
   // NOUVEAU (P2B) - EvaluateOpportunity. Second point d'entrée public,
   // AJOUTÉ (jamais un remplacement de EvaluateEntry - revue P2B point
   // 1). Pipeline Shadow B, totalement indépendant du Pipeline A -
   // mêmes 4 critères (ComputeVerdict partagé), compteurs séparés.
   //
   // opportunityId : identifiant de traçabilité (ex: "OP-42"), reçu en
   // VALEUR (string) - ce moteur ne connaît RIEN du type
   // SOpportunityCandidate ni du module Opportunity, exactement comme
   // il ne connaît rien de SSignalResult pour EvaluateEntry. Préfixé
   // dans verdictOut.reason pour satisfaire l'objectif de traçabilité
   // P2B ("Opportunity #42 -> Verdict = ACCEPTED/REJECTED").
   //---------------------------------------------------------------
   void              EvaluateOpportunity(const SScenarioContext &context, const ENUM_SIGNAL_TYPE candidateDirection,
                                         const string opportunityId, SScenarioVerdict &verdictOut, SScenarioDecision &decisionOut,
                                         const string triggerReason = "")
     {
      m_oppEvaluations++;

      ComputeVerdict(context, candidateDirection, triggerReason, verdictOut, decisionOut);

      if(opportunityId != "")
         verdictOut.reason = "Opportunity=" + opportunityId + " | " + verdictOut.reason;

      if(candidateDirection != SIGNAL_BUY && candidateDirection != SIGNAL_SELL)
         return;

      m_oppVerdictsProduced++;
      m_oppConfidenceSum += verdictOut.confidence;
      if(verdictOut.authorized)
         m_oppVerdictsAuthorized++;
      else
         m_oppVerdictsRefused++;

      if(verdictOut.scenarioStrength == "STRONG")
         m_oppVerdictsStrong++;
      else if(verdictOut.scenarioStrength == "MEDIUM")
         m_oppVerdictsMedium++;
      else
         m_oppVerdictsWeak++;

      if(!verdictOut.authorized)
        {
         if(!verdictOut.htfOk) m_oppRefusalCountHTF++;
         if(!verdictOut.structureOk) m_oppRefusalCountStructure++;
         if(!verdictOut.orderBlockOk) m_oppRefusalCountOrderBlock++;
         if(!verdictOut.fvgOk) m_oppRefusalCountFVG++;
        }
     }

   //---------------------------------------------------------------
   // EvaluateManagement - INCHANGÉ (Sprint V3.0/V3.1, squelette neutre).
   //---------------------------------------------------------------
   void              EvaluateManagement(const ulong positionId, const SScenarioContext &context,
                                        SScenarioVerdict &verdictOut, SScenarioDecision &decisionOut,
                                        const string triggerReason = "")
     {
      verdictOut.status = SCENARIO_UNKNOWN;
      verdictOut.confidence = 0.0;
      verdictOut.reason = "TSE non implemente (squelette Sprint V3.0/V3.1) - gestion de position pilotee exclusivement par ProfitProtectionEngine";
      if(triggerReason != "")
         verdictOut.reason += " | Declenchement: " + triggerReason;
      verdictOut.evaluatedAt = TimeCurrent();

      decisionOut.action = ACTION_NONE;
      decisionOut.targetLevel = 0.0;
      decisionOut.partialExitPercent = 0.0;
      decisionOut.reason = "Squelette V3.0/V3.1 - aucune decision produite, contexte recu mais ignore";

      m_shadowEvaluationsManagement++;
     }

   bool              HasEntryAuthority() const { return(m_flagEnableTSE && m_initialized); }
   bool              HasManagementAuthority() const { return(m_flagEnableStructuralManagement && m_initialized); }

   //---------------------------------------------------------------
   // GetShadowReport - INCHANGÉ (Pipeline A uniquement).
   //---------------------------------------------------------------
   string            GetShadowReport() const
     {
      double avgConfidence = (m_verdictsProduced > 0) ? (m_confidenceSum / m_verdictsProduced) : 0.0;
      return(StringFormat(
         "===== TRADE SCENARIO ENGINE - PIPELINE A (SignalManager, V3.0-V3.5) =====\n"
         "Evaluations entree (observation) : %d\n"
         "Evaluations gestion (observation) : %d\n"
         "Autorite entree active : %s\n"
         "Autorite gestion active : %s\n"
         "----- SHADOW TSE REPORT -----\n"
         "Evaluations (verdicts reels) : %d\n"
         "Authorized : %d\n"
         "Refused : %d\n"
         "Strong : %d\n"
         "Medium : %d\n"
         "Weak : %d\n"
         "Average confidence : %.2f\n"
         "----- Frequence des motifs de refus (par critere) -----\n"
         "HTF non aligne : %d\n"
         "Structure non coherente : %d\n"
         "Order Block non valide : %d\n"
         "FVG non valide : %d\n"
         "=================================================================",
         m_shadowEvaluationsEntry, m_shadowEvaluationsManagement,
         HasEntryAuthority() ? "OUI" : "NON (Shadow uniquement)",
         HasManagementAuthority() ? "OUI" : "NON (squelette, hors perimetre V3.5)",
         m_verdictsProduced, m_verdictsAuthorized, m_verdictsRefused,
         m_verdictsStrong, m_verdictsMedium, m_verdictsWeak, avgConfidence,
         m_refusalCountHTF, m_refusalCountStructure, m_refusalCountOrderBlock, m_refusalCountFVG));
     }

   //---------------------------------------------------------------
   // NOUVEAU (P2B) - GetOpportunityShadowReport. Même esprit que
   // GetShadowReport(), pour le Pipeline B (OpportunityManager)
   // UNIQUEMENT - les deux rapports restent lisibles séparément,
   // conformément à "on continue à mesurer l'ancien moteur, on
   // commence à mesurer le nouveau" (revue P2B).
   //---------------------------------------------------------------
   string            GetOpportunityShadowReport() const
     {
      double avgConfidence = (m_oppVerdictsProduced > 0) ? (m_oppConfidenceSum / m_oppVerdictsProduced) : 0.0;
      return(StringFormat(
         "===== TRADE SCENARIO ENGINE - PIPELINE B (OpportunityManager, V4.1-P2B) =====\n"
         "Evaluations (via EvaluateOpportunity) : %d\n"
         "----- SHADOW TSE REPORT (Opportunity) -----\n"
         "Evaluations (verdicts reels) : %d\n"
         "Authorized : %d\n"
         "Refused : %d\n"
         "Strong : %d\n"
         "Medium : %d\n"
         "Weak : %d\n"
         "Average confidence : %.2f\n"
         "----- Frequence des motifs de refus (par critere) -----\n"
         "HTF non aligne : %d\n"
         "Structure non coherente : %d\n"
         "Order Block non valide : %d\n"
         "FVG non valide : %d\n"
         "=================================================================",
         m_oppEvaluations,
         m_oppVerdictsProduced, m_oppVerdictsAuthorized, m_oppVerdictsRefused,
         m_oppVerdictsStrong, m_oppVerdictsMedium, m_oppVerdictsWeak, avgConfidence,
         m_oppRefusalCountHTF, m_oppRefusalCountStructure, m_oppRefusalCountOrderBlock, m_oppRefusalCountFVG));
     }
  };

#endif // TRADESCENARIOENGINE_MQH
//+------------------------------------------------------------------+