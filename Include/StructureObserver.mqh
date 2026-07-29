//+------------------------------------------------------------------+
//|                                        StructureObserver.mqh       |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.1 - Première couche d'observation structurelle.           |
//|                                                                    |
//| RÔLE : lit l'état DÉJÀ CALCULÉ par CMarketStructure (aucun nouveau  |
//| calcul, aucun appel à Update() - reste la responsabilité de         |
//| l'orchestrateur, exactement à la cadence actuelle : une fois par    |
//| nouvelle bougie H1) et traduit cet état en champs de                |
//| SScenarioContext. Produit également le texte de log [STRUCTURE]    |
//| destiné à la traçabilité humaine.                                   |
//|                                                                    |
//| CE QUE CE MODULE NE FAIT JAMAIS :                                   |
//|   - Ne modifie jamais MarketStructure.mqh, ni aucun autre module    |
//|     existant.                                                       |
//|   - Ne prend AUCUNE décision à partir de ce qu'il observe - il ne   |
//|     fait qu'exposer des faits (bosDetected, chochDetected...),      |
//|     jamais une interprétation ("scénario valide/invalidé" reste     |
//|     l'exclusivité du Trade Scenario Engine, à partir du Sprint      |
//|     V3.3).                                                          |
//|   - N'est PAS le Trade Scenario Engine et n'y est pas raccordé ce   |
//|     sprint : CTradeScenarioEngine reçoit déjà un SScenarioContext   |
//|     dans sa signature (préparation actée), mais l'ignore            |
//|     totalement - voir TradeScenarioEngine.mqh.                      |
//|                                                                    |
//| POSITION DANS LA HIÉRARCHIE : ce module EST une couche              |
//| d'observation au sens de l'architecture V3 (§3.1/§3.3bis) - il a    |
//| donc le droit de détenir un pointeur vers CMarketStructure,          |
//| contrairement au TSE lui-même, qui ne doit jamais le faire.          |
//|                                                                    |
//| DETTE TECHNIQUE (voir aussi V3Types.mqh) : ce module parse le texte |
//| retourné par CMarketStructure::GetLastEventDescription() plutôt     |
//| que de consommer un type structuré dédié - accepté pour ce sprint,  |
//| CMarketStructure n'étant volontairement pas modifié. À migrer vers  |
//| un contrat typé au plus tard au Sprint V3.2.                        |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef STRUCTUREOBSERVER_MQH
#define STRUCTUREOBSERVER_MQH

#include "V3Types.mqh"
#include "MarketStructure.mqh"

class CStructureObserver
  {
private:
   CMarketStructure *m_marketStructure; // Référence non propriétaire - autorisée ici (couche d'observation), interdite dans le TSE
   bool              m_initialized;

   // Mémorise le dernier événement BOS/CHOCH déjà journalisé, pour ne
   // signaler qu'une TRANSITION (un nouvel événement), pas re-journaliser
   // le même état à chaque bougie tant qu'aucun nouveau BOS/CHOCH n'est
   // survenu. Le sweep, lui, est par nature propre à chaque bougie -
   // aucune mémorisation nécessaire pour lui.
   string            m_lastLoggedEventDescription;

   //---------------------------------------------------------------
   // Prix du swing cassé pertinent pour le log - Higher precedent pour
   // un événement haussier, Lower précédent pour un événement baissier.
   // Utilise uniquement des accesseurs déjà publics de CMarketStructure
   // (GetPrevSwingHighPrice/GetPrevSwingLowPrice) - aucun nouveau calcul.
   //---------------------------------------------------------------
   double            BrokenSwingPriceFor(const string direction) const
     {
      if(direction == "Bullish")
         return(m_marketStructure.GetPrevSwingHighPrice());
      if(direction == "Bearish")
         return(m_marketStructure.GetPrevSwingLowPrice());
      return(0.0);
     }

public:
                     CStructureObserver()
     {
      m_marketStructure             = NULL;
      m_initialized                 = false;
      m_lastLoggedEventDescription  = "";
     }

   bool              Init(CMarketStructure *marketStructure)
     {
      if(marketStructure == NULL)
        {
         Print("CStructureObserver::Init - marketStructure est NULL");
         return(false);
        }
      m_marketStructure            = marketStructure;
      m_lastLoggedEventDescription = "";
      m_initialized                = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Observe - à appeler à la MÊME cadence que g_marketStructure.Update()
   // (une fois par nouvelle bougie H1 aujourd'hui), juste après cet
   // appel. Renseigne contextInOut (BOS/CHOCH/Sweep) et construit un
   // texte de log [STRUCTURE] UNIQUEMENT si un événement nouveau est
   // détecté depuis le dernier appel - jamais de spam à chaque bougie
   // si rien n'a changé.
   //
   // shift : bougie observée (1 = dernière clôturée), même convention
   // que CMarketStructure::Update()/DetectSweep().
   //---------------------------------------------------------------
   void              Observe(const int shift, SScenarioContext &contextInOut,
                             string &logTextOut, bool &hasNewEventOut)
     {
      logTextOut     = "";
      hasNewEventOut = false;

      if(!m_initialized || m_marketStructure == NULL)
         return;

      // --- BOS / CHOCH (dette technique documentée : parsing texte) ---
      string eventDesc = m_marketStructure.GetLastEventDescription();

      bool   isBos   = (StringFind(eventDesc, "BOS_") == 0);
      bool   isChoch = (StringFind(eventDesc, "CHOCH_") == 0);
      string direction = "";
      if(StringFind(eventDesc, "BULLISH") >= 0)
         direction = "Bullish";
      else if(StringFind(eventDesc, "BEARISH") >= 0)
         direction = "Bearish";

      contextInOut.bosDetected    = isBos;
      contextInOut.bosDirection   = isBos ? direction : "";
      contextInOut.chochDetected  = isChoch;
      contextInOut.chochDirection = isChoch ? direction : "";

      // --- Sweep (événement propre à la bougie observée, pas d'état persistant) ---
      string sweepSide = m_marketStructure.DetectSweep(shift);
      contextInOut.sweepDetected  = (sweepSide != "Aucun");
      contextInOut.sweepDirection = contextInOut.sweepDetected ? sweepSide : "";

      contextInOut.structureEventTime = TimeCurrent();
      contextInOut.capturedAt         = TimeCurrent();

      // --- Journalisation : uniquement aux transitions BOS/CHOCH, et à
      //     chaque sweep detecte (deja transitoire par nature) ---
      if((isBos || isChoch) && eventDesc != m_lastLoggedEventDescription)
        {
         logTextOut += StringFormat(
            "[STRUCTURE]\n%s detecte\nDirection : %s\nSwing casse : %s\nHeure : %s\n",
            isBos ? "BOS" : "CHOCH", direction,
            DoubleToString(BrokenSwingPriceFor(direction), _Digits),
            TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
         m_lastLoggedEventDescription = eventDesc;
         hasNewEventOut = true;
        }

      if(contextInOut.sweepDetected)
        {
         logTextOut += StringFormat(
            "[STRUCTURE]\nSweep detecte\n%s\nHeure : %s\n",
            (sweepSide == "Resistance") ? "Au-dessus des derniers sommets" : "En dessous des derniers creux",
            TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
         hasNewEventOut = true;
        }
     }

   //---------------------------------------------------------------
   // Construit un "triggerReason" concis à partir du contexte le plus
   // récent, destiné à alimenter le paramètre triggerReason des
   // méthodes Evaluate*() du TSE (Sprint V3.0) - c'est ici, et
   // uniquement ici, que ce paramètre commence à être utilisé, comme
   // demandé.
   //---------------------------------------------------------------
   static string     BuildTriggerReason(const SScenarioContext &context, const bool hasNewEvent)
     {
      if(!hasNewEvent)
         return(""); // Rien de nouveau - comportement par défaut du TSE (V3.0), inchangé
      if(context.bosDetected)
         return(StringFormat("BOS confirme (%s)", context.bosDirection));
      if(context.chochDetected)
         return(StringFormat("CHOCH confirme (%s)", context.chochDirection));
      if(context.sweepDetected)
         return(StringFormat("Sweep detecte (%s)", context.sweepDirection));
      return("");
     }
  };

#endif // STRUCTUREOBSERVER_MQH
//+------------------------------------------------------------------+