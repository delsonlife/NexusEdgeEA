//+------------------------------------------------------------------+
//|                                       TradeScenarioEngine.mqh      |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.5 - Shadow Decision Engine (première logique réelle).    |
//|                                                                    |
//| RÔLE FINAL (voir ARCHITECTURE_V3.md §3.3) : l'autorité UNIQUE de   |
//| décision de tout le système V3. Répond à "le scénario est-il       |
//| toujours valide ?" puis décide de l'action à entreprendre - il ne  |
//| modifie jamais lui-même un ordre ni un SL.                          |
//|                                                                    |
//| ÉTAT ACTUEL (Sprint V3.5) : EvaluateEntry() produit désormais un   |
//| VRAI verdict déterministe (authorized/confidence/scenarioStrength/ |
//| 4 critères OK/KO) - mais reste STRICTEMENT en mode Shadow : ce      |
//| verdict est calculé, journalisé, comptabilisé, JAMAIS UTILISÉ.      |
//| L'appelant (NexusEdgeEA.mq5) continue de piloter les entrées        |
//| exclusivement via CSignalManager - le résultat de ce moteur n'est   |
//| lu par aucune décision réelle. EvaluateManagement() reste un       |
//| squelette neutre (hors périmètre de ce sprint, prévu V3.6/V3.7).   |
//|                                                                    |
//| RÈGLE DE SORTIE DU SPRINT (voir ARCHITECTURE_V3.md) : le TSE ne    |
//| pourra recevoir une autorité réelle sur les entrées (V3.6+) que si  |
//| ses verdicts Shadow ont été comparés statistiquement au système     |
//| actuel sur un échantillon suffisant et démontrent un avantage       |
//| mesurable - pas avant.                                              |
//|                                                                    |
//| LOGIQUE DE DÉCISION - déterministe, aucune pondération              |
//| statistique, aucun score IA, aucun apprentissage. Quatre critères,  |
//| chacun contribuant 25% à "confidence" (score Shadow INDÉPENDANT de  |
//| "authorized" - voir ci-dessous) :                                    |
//|   1) HTF aligné       : htfBiasAvailable && htfBiasDirection == direction candidate |
//|   2) Structure cohérente : BOS OU CHOCH aligné (ajustement validé - pas BOS seul) |
//|   3) Order Block valide : actif, valide, aligné                     |
//|   4) FVG valide         : actif, valide, aligné                      |
//| "authorized" = ET logique strict des 4 critères - pas un seuil de   |
//| confidence. "confidence" reste un score Shadow séparé, calculé même  |
//| quand authorized=false, pour permettre l'analyse statistique fine   |
//| (ex: un verdict refusé à 0.75 est plus proche d'une autorisation     |
//| qu'un verdict refusé à 0.0).                                        |
//|                                                                    |
//| "context" : le SScenarioContext déjà construit par les couches      |
//| d'observation - AUCUN accès direct à MarketStructure/                |
//| OrderBlockDetector/FVGDetector/HTFBiasObserver. Respecte             |
//| strictement le principe d'isolation du TSE (§3.3bis).                |
//|                                                                    |
//| "candidateDirection" (Sprint V3.5, nouveau paramètre) : la direction |
//| candidate (BUY/SELL/NONE), transmise en VALEUR par l'orchestrateur   |
//| - ce n'est pas une lecture de module (le TSE ne va rien chercher     |
//| lui-même), c'est une donnée déjà calculée transmise au même titre    |
//| que "context". Si SIGNAL_NONE, aucun verdict réel n'est produit      |
//| (pas de comptage, pas de log) - cohérent avec "pour chaque           |
//| opportunité d'entrée", pas à chaque bougie indistinctement.          |
//|                                                                    |
//| MODIFIÉ (ajustements post-revue V3.0, avant ouverture de V3.1) :    |
//|                                                                    |
//| 1. Paramètre "triggerReason" (chaîne, défaut vide) ajouté à         |
//|    EvaluateEntry() et EvaluateManagement(). N'existe que pour       |
//|    documenter, dans les futurs sprints event-driven, POURQUOI une   |
//|    évaluation a été déclenchée ("Sweep détecté", "CHOCH confirmé", |
//|    "BOS confirmé", "Entrée Order Block/FVG"...). Valeur par défaut  |
//|    vide => tous les appels existants continuent de compiler et de  |
//|    produire un texte de raison strictement identique à avant -      |
//|    aucun changement de comportement.                                |
//|                                                                    |
//| 2. SUPPRESSION du pointeur CMarketStructure qui existait dans la   |
//|    première version de ce fichier. Direction architecturale actée :|
//|    le TSE ne collecte JAMAIS lui-même les données de marché. Les   |
//|    couches d'observation construiront progressivement un objet de  |
//|    contexte (SScenarioContext, voir V3Types.mqh) que le TSE se      |
//|    contente de RECEVOIR en paramètre, jamais d'aller chercher       |
//|    lui-même via un pointeur stocké. Ce moteur ne stocke donc pas,   |
//|    et ne stockera jamais, de référence directe vers un module de   |
//|    marché - seuls les Feature Flags (configuration) restent en      |
//|    membre.                                                           |
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

   // --- Feature Flags (voir Config.mqh) - stockés ici en copie locale
   //     pour que le moteur reste auto-suffisant une fois initialisé.
   //     Ce sont des drapeaux de CONFIGURATION, pas des données de
   //     marché - leur présence ici ne contredit pas la règle "le TSE
   //     ne collecte jamais lui-même les données de marché" (voir
   //     en-tête, ajustement 2). ---
   bool              m_flagEnableTSE;
   bool              m_flagEnableHTFBias;
   bool              m_flagEnableStructuralManagement;

   // --- Compteurs de diagnostic (mode observation) ---
   int               m_shadowEvaluationsEntry;
   int               m_shadowEvaluationsManagement;

   // --- Statistiques Shadow (Sprint V3.5) - verdicts d'entree reels uniquement ---
   int               m_verdictsProduced;
   int               m_verdictsAuthorized;
   int               m_verdictsRefused;
   int               m_verdictsStrong;
   int               m_verdictsMedium;
   int               m_verdictsWeak;
   double            m_confidenceSum;

   // --- Frequence des motifs de refus, par critere (demande explicite) ---
   int               m_refusalCountHTF;
   int               m_refusalCountStructure;
   int               m_refusalCountOrderBlock;
   int               m_refusalCountFVG;

public:
                     CTradeScenarioEngine()
     {
      m_initialized                      = false;
      m_flagEnableTSE                    = false;
      m_flagEnableHTFBias                = false;
      m_flagEnableStructuralManagement   = false;
      m_shadowEvaluationsEntry           = 0;
      m_shadowEvaluationsManagement      = 0;
      m_verdictsProduced                 = 0;
      m_verdictsAuthorized               = 0;
      m_verdictsRefused                  = 0;
      m_verdictsStrong                   = 0;
      m_verdictsMedium                   = 0;
      m_verdictsWeak                     = 0;
      m_confidenceSum                    = 0.0;
      m_refusalCountHTF                  = 0;
      m_refusalCountStructure            = 0;
      m_refusalCountOrderBlock           = 0;
      m_refusalCountFVG                  = 0;
     }

   //---------------------------------------------------------------
   // Init - NE PREND VOLONTAIREMENT AUCUN POINTEUR vers un module de
   // marché (voir ajustement 2 en en-tête). Seuls les Feature Flags,
   // qui sont de la configuration et non des données de marché, sont
   // transmis. Les futurs sprints qui ont besoin d'informations de
   // marché devront les faire transiter par un SScenarioContext passé
   // en paramètre d'EvaluateEntry()/EvaluateManagement(), jamais par
   // un nouveau pointeur stocké ici.
   //---------------------------------------------------------------
   bool              Init(const bool flagEnableTSE, const bool flagEnableHTFBias,
                          const bool flagEnableStructuralManagement)
     {
      m_flagEnableTSE                  = flagEnableTSE;
      m_flagEnableHTFBias              = flagEnableHTFBias;
      m_flagEnableStructuralManagement = flagEnableStructuralManagement;
      m_initialized                    = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // EvaluateEntry - SPRINT V3.5 : première logique de décision réelle,
   // strictement Shadow (voir en-tête pour le détail complet de la
   // logique et des garanties de non-influence).
   //---------------------------------------------------------------
   void              EvaluateEntry(const SScenarioContext &context, const ENUM_SIGNAL_TYPE candidateDirection,
                                   SScenarioVerdict &verdictOut, SScenarioDecision &decisionOut,
                                   const string triggerReason = "")
     {
      decisionOut.action             = ACTION_NONE;
      decisionOut.targetLevel        = 0.0;
      decisionOut.partialExitPercent = 0.0;
      decisionOut.reason             = "Shadow uniquement (Sprint V3.5) - aucune decision executee, voir authorized dans le verdict";

      verdictOut.status      = SCENARIO_UNKNOWN; // Non pertinent pour l'entree - voir "authorized"
      verdictOut.evaluatedAt = TimeCurrent();

      m_shadowEvaluationsEntry++;

      // Pas de signal candidat ce tour-ci : pas de verdict reel, pas de
      // comptage, pas de log - coherent avec "pour chaque opportunite
      // d'entree", pas a chaque bougie indistinctement.
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
      string wantedStr = (candidateDirection == SIGNAL_BUY) ? "Bullish" : "Bearish"; // bosDirection/chochDirection (V3.1) restent en string, verrouilles - non modifies

      bool htfOk        = context.htfBiasAvailable && context.htfBiasDirection == wanted;
      bool structureOk  = (context.bosDetected   && context.bosDirection   == wantedStr) ||
                          (context.chochDetected && context.chochDirection == wantedStr); // Ajustement valide : BOS OU CHOCH, pas BOS seul
      bool orderBlockOk = context.orderBlockActive && context.orderBlockValid && context.orderBlockDirection == wanted;
      bool fvgOk        = context.fvgActive && context.fvgValid && context.fvgDirection == wanted;

      double confidence = (htfOk ? 0.25 : 0.0) + (structureOk ? 0.25 : 0.0) + (orderBlockOk ? 0.25 : 0.0) + (fvgOk ? 0.25 : 0.0);
      bool   authorized = htfOk && structureOk && orderBlockOk && fvgOk; // Porte ET stricte - pas un seuil de confidence

      string strength = (confidence >= 0.75) ? "STRONG" : ((confidence >= 0.5) ? "MEDIUM" : "WEAK");

      verdictOut.confidence      = confidence;
      verdictOut.authorized      = authorized;
      verdictOut.scenarioStrength = strength;
      verdictOut.htfOk           = htfOk;
      verdictOut.structureOk     = structureOk;
      verdictOut.orderBlockOk    = orderBlockOk;
      verdictOut.fvgOk           = fvgOk;
      verdictOut.reason          = authorized ? "4/4 criteres satisfaits" : "Au moins 1 critere non satisfait - voir details par critere";
      if(triggerReason != "")
         verdictOut.reason += " | Declenchement: " + triggerReason;

      // --- Statistiques Shadow ---
      m_verdictsProduced++;
      m_confidenceSum += confidence;
      if(authorized)
         m_verdictsAuthorized++;
      else
         m_verdictsRefused++;
      if(strength == "STRONG")
         m_verdictsStrong++;
      else if(strength == "MEDIUM")
         m_verdictsMedium++;
      else
         m_verdictsWeak++;

      // --- Frequence des motifs de refus, par critere (demande explicite) ---
      if(!authorized)
        {
         if(!htfOk)        m_refusalCountHTF++;
         if(!structureOk)  m_refusalCountStructure++;
         if(!orderBlockOk) m_refusalCountOrderBlock++;
         if(!fvgOk)        m_refusalCountFVG++;
        }
     }

   //---------------------------------------------------------------
   // EvaluateManagement - SPRINT V3.0/V3.1 : verdict neutre systématique,
   // même logique que EvaluateEntry(), mêmes paramètres "context"
   // (ignoré) et "triggerReason" (défaut ""), pour les mêmes raisons.
   //
   // Logique réelle prévue Sprint V3.6 (observation) puis V3.7
   // (autorité réelle sur les Action Engines, derrière
   // m_flagEnableStructuralManagement).
   //---------------------------------------------------------------
   void              EvaluateManagement(const ulong positionId, const SScenarioContext &context,
                                        SScenarioVerdict &verdictOut, SScenarioDecision &decisionOut,
                                        const string triggerReason = "")
     {
      verdictOut.status      = SCENARIO_UNKNOWN;
      verdictOut.confidence  = 0.0;
      verdictOut.reason      = "TSE non implemente (squelette Sprint V3.0/V3.1) - gestion de position pilotee exclusivement par ProfitProtectionEngine";
      if(triggerReason != "")
         verdictOut.reason += " | Declenchement: " + triggerReason;
      verdictOut.evaluatedAt = TimeCurrent();

      decisionOut.action             = ACTION_NONE;
      decisionOut.targetLevel        = 0.0;
      decisionOut.partialExitPercent = 0.0;
      decisionOut.reason             = "Squelette V3.0/V3.1 - aucune decision produite, contexte recu mais ignore";

      m_shadowEvaluationsManagement++;
     }

   //---------------------------------------------------------------
   // Vrai si ce moteur a le droit d'influencer réellement une
   // décision d'entrée. Centralise la vérification du Feature Flag -
   // les sprints futurs n'ont qu'à appeler cette méthode plutôt que de
   // relire le flag brut à plusieurs endroits.
   //---------------------------------------------------------------
   bool              HasEntryAuthority() const { return(m_flagEnableTSE && m_initialized); }
   bool              HasManagementAuthority() const { return(m_flagEnableStructuralManagement && m_initialized); }

   //---------------------------------------------------------------
   // Rapport de diagnostic (même esprit que GetActivationReport() du
   // Profit Protection Engine) - consultable à OnDeinit().
   //---------------------------------------------------------------
   string            GetShadowReport() const
     {
      double avgConfidence = (m_verdictsProduced > 0) ? (m_confidenceSum / m_verdictsProduced) : 0.0;
      return(StringFormat(
         "===== TRADE SCENARIO ENGINE (V3.0-V3.5 - Shadow uniquement, aucune autorite) =====\n"
         "Evaluations entree (observation) : %d\n"
         "Evaluations gestion (observation) : %d\n"
         "Autorite entree active            : %s\n"
         "Autorite gestion active           : %s\n"
         "----- SHADOW TSE REPORT -----\n"
         "Evaluations (verdicts reels)      : %d\n"
         "Authorized                        : %d\n"
         "Refused                           : %d\n"
         "Strong                            : %d\n"
         "Medium                            : %d\n"
         "Weak                              : %d\n"
         "Average confidence                : %.2f\n"
         "----- Frequence des motifs de refus (par critere) -----\n"
         "HTF non aligne                    : %d\n"
         "Structure non coherente           : %d\n"
         "Order Block non valide            : %d\n"
         "FVG non valide                    : %d\n"
         "=================================================================",
         m_shadowEvaluationsEntry, m_shadowEvaluationsManagement,
         HasEntryAuthority() ? "OUI" : "NON (Shadow uniquement)",
         HasManagementAuthority() ? "OUI" : "NON (squelette, hors perimetre V3.5)",
         m_verdictsProduced, m_verdictsAuthorized, m_verdictsRefused,
         m_verdictsStrong, m_verdictsMedium, m_verdictsWeak, avgConfidence,
         m_refusalCountHTF, m_refusalCountStructure, m_refusalCountOrderBlock, m_refusalCountFVG));
     }
  };

#endif // TRADESCENARIOENGINE_MQH
//+------------------------------------------------------------------+