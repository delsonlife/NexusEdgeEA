//+------------------------------------------------------------------+
//|                                          HTFBiasObserver.mqh       |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.3 - Observateur du biais Higher Timeframe.                |
//|                                                                    |
//| DÉFINITION MÉCANIQUE RETENUE (voir ARCHITECTURE_V3.md, précision   |
//| Sprint V3.3) : le biais HTF EST `GetCurrentBias()` d'une instance   |
//| de CMarketStructure configurée sur InpTF_High - la même logique de  |
//| swings/BOS/CHOCH déjà validée en H1, jamais une seconde             |
//| implémentation ni une heuristique ad hoc ("au-dessus d'une          |
//| moyenne", etc.). Une seule source de vérité pour le concept de      |
//| biais structurel, réutilisée à une autre unité de temps - pas       |
//| dupliquée.                                                          |
//|                                                                    |
//| OPTION A RETENUE (vs Option B, détecteur HTF minimal maison) :      |
//| CMarketStructure ne contient aucun état statique (vérifié avant     |
//| implémentation) - deux instances indépendantes coexistent sans      |
//| conflit. CUtilities::IsNewBar() est déjà nativement multi-          |
//| timeframe. Écrire un second algorithme de swings aurait été la      |
//| duplication que ce sprint interdit explicitement.                   |
//|                                                                    |
//| CE MODULE NE DÉTIENT PAS l'instance CMarketStructure HTF - il la    |
//| REÇOIT en paramètre d'Init(), au même titre que COrderBlockDetector |
//| reçoit l'instance H1. L'orchestrateur (NexusEdgeEA.mq5) possède et  |
//| met à jour g_marketStructureHTF, à la cadence H4 uniquement (voir   |
//| ci-dessous) - ce module se contente de LIRE son état déjà calculé.  |
//|                                                                    |
//| CADENCE : Observe() ne doit être appelée QUE lorsqu'une nouvelle    |
//| bougie InpTF_High vient de clôturer (gated par                      |
//| CUtilities::IsNewBar(_Symbol, InpTF_High) côté orchestrateur) - le  |
//| biais HTF reste inchangé entre deux bougies HTF, jamais recalculé   |
//| à chaque tick ni à chaque bougie H1.                                 |
//|                                                                    |
//| htfBiasAvailable : distingue explicitement "pas encore de donnée"   |
//| (avant la toute première mise à jour du module HTF - démarrage,      |
//| historique insuffisant) de "biais neutre" (DIRECTION_NONE avec       |
//| htfBiasAvailable=true, un fait constaté, pas une absence de           |
//| réponse).                                                            |
//|                                                                    |
//| htfBiasStrength VOLONTAIREMENT ABSENT de SScenarioContext ce         |
//| sprint : CMarketStructure n'expose aucun score de confiance, en      |
//| inventer un serait exactement le "score arbitraire" que la V3        |
//| évite depuis le début. À documenter en backlog si un besoin réel     |
//| apparaît plus tard.                                                  |
//|                                                                    |
//| SÉPARATION Observer → Décrire → Décider : ce module répond           |
//| UNIQUEMENT à "quel est le biais HTF actuel", jamais à "faut-il        |
//| acheter ou vendre" - aucune interprétation directionnelle pour        |
//| l'entrée, réservée au Trade Scenario Engine (sprint ultérieur).       |
//|                                                                    |
//| POINT DE VIGILANCE RESPECTÉ : aucun accesseur n'a dû être ajouté à   |
//| MarketStructure.mqh pour ce sprint - GetCurrentBias() et             |
//| IsInitialized(), déjà publics, suffisent intégralement.               |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef HTFBIASOBSERVER_MQH
#define HTFBIASOBSERVER_MQH

#include "V3Types.mqh"
#include "MarketStructure.mqh"

class CHTFBiasObserver
  {
private:
   CMarketStructure *m_htfMarketStructure; // Référence non propriétaire vers l'instance HTF (possédée par l'orchestrateur)
   ENUM_TIMEFRAMES   m_htfTimeframe;
   bool              m_initialized;
   bool              m_hasObservedAtLeastOnce; // Devient true après le premier appel a Observe() - fonde htfBiasAvailable

   // Mémorise la dernière direction déjà journalisée, pour ne
   // journaliser qu'aux transitions - même logique que les détecteurs
   // précédents (CStructureObserver, COrderBlockDetector).
   ENUM_STRUCTURE_DIRECTION m_lastLoggedDirection;

   static ENUM_STRUCTURE_DIRECTION BiasToDirection(const ENUM_STRUCTURE_BIAS bias)
     {
      if(bias == STRUCTURE_BIAS_BULLISH)
         return(DIRECTION_BULLISH);
      if(bias == STRUCTURE_BIAS_BEARISH)
         return(DIRECTION_BEARISH);
      return(DIRECTION_NONE);
     }

public:
                     CHTFBiasObserver()
     {
      m_htfMarketStructure     = NULL;
      m_htfTimeframe           = PERIOD_CURRENT;
      m_initialized            = false;
      m_hasObservedAtLeastOnce = false;
      m_lastLoggedDirection    = DIRECTION_NONE;
     }

   bool              Init(CMarketStructure *htfMarketStructure, const ENUM_TIMEFRAMES htfTimeframe)
     {
      if(htfMarketStructure == NULL)
        {
         Print("CHTFBiasObserver::Init - htfMarketStructure est NULL");
         return(false);
        }
      m_htfMarketStructure     = htfMarketStructure;
      m_htfTimeframe           = htfTimeframe;
      m_hasObservedAtLeastOnce = false;
      m_lastLoggedDirection    = DIRECTION_NONE;
      m_initialized            = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Observe - à appeler UNIQUEMENT à la clôture d'une nouvelle bougie
   // InpTF_High (gated côté orchestrateur), jamais à chaque tick ni à
   // chaque bougie H1. Lit l'état déjà calculé par
   // m_htfMarketStructure (aucun nouveau calcul ici) et renseigne les
   // 4 champs htfBias* de contextInOut.
   //---------------------------------------------------------------
   void              Observe(SScenarioContext &contextInOut, string &logTextOut, bool &hasNewEventOut)
     {
      logTextOut     = "";
      hasNewEventOut = false;

      if(!m_initialized || m_htfMarketStructure == NULL)
         return;

      m_hasObservedAtLeastOnce = true;

      ENUM_STRUCTURE_DIRECTION direction = BiasToDirection(m_htfMarketStructure.GetCurrentBias());
      ENUM_STRUCTURE_DIRECTION previous  = contextInOut.htfBiasAvailable ? contextInOut.htfBiasDirection : DIRECTION_NONE;

      contextInOut.htfBiasAvailable = true; // Premiere mise a jour reussie - a partir d'ici, DIRECTION_NONE est un fait constate, pas une absence de donnee
      contextInOut.htfBiasTimeframe = m_htfTimeframe;

      if(direction != m_lastLoggedDirection)
        {
         contextInOut.htfBiasUpdatedAt = TimeCurrent();
         logTextOut += StringFormat(
            "[HTF_BIAS]\nTimeframe : %s\nDirection : %s\nPrevious : %s\nUpdated : %s\n",
            EnumToString(m_htfTimeframe),
            direction == DIRECTION_BULLISH ? "BULLISH" : (direction == DIRECTION_BEARISH ? "BEARISH" : "NEUTRAL"),
            previous == DIRECTION_BULLISH ? "BULLISH" : (previous == DIRECTION_BEARISH ? "BEARISH" : "NEUTRAL"),
            TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
         m_lastLoggedDirection = direction;
         hasNewEventOut = true;
        }

      contextInOut.htfBiasDirection = direction;
     }
  };

#endif // HTFBIASOBSERVER_MQH
//+------------------------------------------------------------------+
