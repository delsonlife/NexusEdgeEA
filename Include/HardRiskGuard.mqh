//+------------------------------------------------------------------+
//|                                             HardRiskGuard.mqh      |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.4 - Hard Risk Guard, mode observation parallèle.          |
//|                                                                    |
//| RÔLE FINAL (voir ARCHITECTURE_V3.md §3.5) : seule couche du        |
//| système dont l'existence part du principe que le Trade Scenario    |
//| Engine (ou le modèle en général) peut se tromper. Répond           |
//| UNIQUEMENT à "existe-t-il une situation où le risque global        |
//| dépasse une limite absolue ?" - ne répond jamais "que doit faire   |
//| le robot ?". N'est protégé par AUCUN Feature Flag : conçu pour     |
//| rester actif en permanence par construction, une fois qu'il aura   |
//| reçu l'autorité réelle (sprint ultérieur, pas celui-ci).           |
//|                                                                    |
//| INDÉPENDANCE STRICTE, VÉRIFIÉE AVANT IMPLÉMENTATION : ce module ne |
//| lit QUE des primitives MQL5 brutes (AccountInfoDouble,             |
//| PositionsTotal/PositionGetString/PositionGetInteger, HistorySelect/|
//| HistoryDealGetDouble) - JAMAIS CStatistics::GetMaxDrawdownPercent()|
//| ni CountRecentConsecutiveLosses() (déjà utilisées par le           |
//| disjoncteur réel dans NexusEdgeEA.mq5). Le drawdown et les pertes  |
//| consécutives sont recalculés ici DEPUIS ZÉRO, indépendamment de    |
//| tout autre module qui ferait le même calcul ailleurs - "le         |
//| mécanisme qui protège contre une erreur du modèle ne doit jamais   |
//| dépendre du modèle". Aucune dépendance vers CTradeScenarioEngine,  |
//| SignalManager, ProfitProtectionEngine, CMarketStructure.           |
//|                                                                    |
//| ÉTAT ACTUEL (Sprint V3.4) : ce module calcule réellement les 5     |
//| risques ci-dessous et les journalise, mais NE DÉCLENCHE TOUJOURS   |
//| RIEN - aucun appel à CloseAllPositions(), aucune modification de   |
//| SL/TP, aucun blocage d'entrée. Le site d'appel (NexusEdgeEA.mq5)   |
//| continue d'ignorer intégralement le résultat pour toute décision   |
//| réelle. Le transfert d'autorité reste un sprint ultérieur.         |
//|                                                                    |
//| MODÈLE ÉVÉNEMENTIEL (ajustement post-revue, avant implémentation) :|
//| Evaluate() ne retourne PAS un tableau fixe des 5 risques à chaque  |
//| appel - l'état complet est conservé en interne (m_state[]), et     |
//| seuls les risques dont le statut a RÉELLEMENT CHANGÉ depuis le     |
//| dernier appel sont retournés (tableau dynamique, 0 élément dans    |
//| l'immense majorité des cas). Prépare naturellement un futur modèle  |
//| event-driven, et évite le spam de journalisation à chaque bougie.  |
//|                                                                    |
//| SEUIL WARNING : WARNING_RATIO est une CONSTANTE INTERNE au module   |
//| (0.80 aujourd'hui), pas une règle métier universelle - ajustable   |
//| librement dans le futur sans changer l'architecture ni le contrat   |
//| SHardRiskEvent. Documenté comme tel, pas comme une vérité figée.    |
//|                                                                    |
//| SScenarioContext NON UTILISÉ, DÉLIBÉRÉMENT : le risque compte-     |
//| global n'est pas une information de marché - structure dédiée      |
//| (SHardRiskEvent, définie ici) plutôt que de polluer le contrat      |
//| partagé entre les couches d'observation.                            |
//|                                                                    |
//| LIMITES VOLONTAIREMENT EXCLUES CE SPRINT (voir proposition          |
//| validée) : anomalies de contraintes broker (aucun accesseur         |
//| exploitable sans toucher BrokerConstraints.mqh, non fait sans       |
//| validation préalable), cadence par tick (ce module reste à la      |
//| même cadence H1 que le disjoncteur réel actuel, pour une            |
//| comparaison fidèle avant tout transfert d'autorité), exposition en  |
//| lots (aucun seuil configuré n'existe aujourd'hui).                  |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef HARDRISKGUARD_MQH
#define HARDRISKGUARD_MQH

//+------------------------------------------------------------------+
//| ENUM_HARD_RISK_TYPE - identifiant stable par type de risque        |
//| (même logique que orderBlockId/fvgId : facilite les statistiques   |
//| et la consommation future par le Learning Engine).                  |
//+------------------------------------------------------------------+
enum ENUM_HARD_RISK_TYPE
  {
   RISK_NONE                = 0,
   RISK_DAILY_LOSS          = 1,
   RISK_DAILY_GAIN          = 2,
   RISK_GLOBAL_DRAWDOWN     = 3,
   RISK_CONSECUTIVE_LOSSES  = 4,
   RISK_MAX_POSITIONS       = 5
  };

enum ENUM_HARD_RISK_STATUS
  {
   RISK_STATUS_OK      = 0,
   RISK_STATUS_WARNING = 1,
   RISK_STATUS_BREACH  = 2
  };

struct SHardRiskEvent
  {
   ENUM_HARD_RISK_TYPE   type;
   ENUM_HARD_RISK_STATUS status;
   double                value;
   double                limit;
   string                reason;
   datetime              detectedAt;
  };

string HardRiskTypeToString(const ENUM_HARD_RISK_TYPE type)
  {
   switch(type)
     {
      case RISK_DAILY_LOSS:         return("DAILY_LOSS_LIMIT");
      case RISK_DAILY_GAIN:         return("DAILY_GAIN_LIMIT");
      case RISK_GLOBAL_DRAWDOWN:    return("GLOBAL_DRAWDOWN");
      case RISK_CONSECUTIVE_LOSSES: return("CONSECUTIVE_LOSSES");
      case RISK_MAX_POSITIONS:      return("MAX_POSITIONS_EXCEEDED");
      default:                      return("NONE");
     }
  }

string HardRiskStatusToString(const ENUM_HARD_RISK_STATUS status)
  {
   switch(status)
     {
      case RISK_STATUS_WARNING: return("WARNING");
      case RISK_STATUS_BREACH:  return("BREACH");
      default:                  return("OK");
     }
  }

class CHardRiskGuard
  {
private:
   bool           m_initialized;
   double         m_peakEquity; // Suivi interne, indépendant de CStatistics

   // Etat complet conserve en interne (indexe par type-1, 0..4) -
   // seule la TRANSITION est remontee par Evaluate(), jamais l'etat
   // complet a chaque appel (voir ajustement post-revue en en-tete).
   SHardRiskEvent m_state[5];

   int            m_shadowEvaluations;
   int            m_shadowTransitions;

   // Seuil d'alerte - constante interne, pas une regle metier figee
   // (voir en-tete). Ajustable ici sans impact sur le contrat
   // SHardRiskEvent ni sur l'appelant.
   const double   WARNING_RATIO;

   ENUM_HARD_RISK_STATUS ClassifyUsageRatio(const double usedRatio) const
     {
      if(usedRatio >= 1.0)
         return(RISK_STATUS_BREACH);
      if(usedRatio >= WARNING_RATIO)
         return(RISK_STATUS_WARNING);
      return(RISK_STATUS_OK);
     }

   //---------------------------------------------------------------
   // Pertes consecutives - recalculees DEPUIS ZERO a partir de
   // l'historique brut des deals de cloture (symbole+magic), jamais
   // via CountRecentConsecutiveLosses() (voir en-tete, independance
   // stricte). Remonte les deals les plus recents jusqu'au premier
   // gain, borne a maxToCheck+1 pour rester peu couteux.
   //---------------------------------------------------------------
   int            CountConsecutiveLossesIndependently(const string symbol, const long magicNumber, const int maxToCheck) const
     {
      if(!HistorySelect(0, TimeCurrent()))
         return(0);

      int total = HistoryDealsTotal();
      int consecutive = 0;

      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0)
            continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != symbol)
            continue;
         if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != magicNumber)
            continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
            continue; // Seules les clotures comptent, pas les ouvertures

         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         if(profit < 0.0)
           {
            consecutive++;
            if(consecutive > maxToCheck)
               break; // Deja au-dela de la limite, inutile de continuer a compter precisement
           }
         else
            break; // Premier gain rencontre en remontant - la serie s'arrete ici
        }
      return(consecutive);
     }

   int            CountOpenPositions(const string symbol, const long magicNumber) const
     {
      int count = 0;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol)
            continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != magicNumber)
            continue;
         count++;
        }
      return(count);
     }

   //---------------------------------------------------------------
   // Compare le nouvel etat calcule a m_state[idx] ; si le statut a
   // change, met a jour eventsOut (ArrayResize + append) et
   // m_state[idx]. Ne journalise jamais rien lui-meme - c'est
   // l'appelant (NexusEdgeEA.mq5) qui decide du format de log, comme
   // pour tous les autres observateurs V3.
   //---------------------------------------------------------------
   void           UpdateAndCollect(const int idx, const ENUM_HARD_RISK_TYPE type,
                                   const ENUM_HARD_RISK_STATUS newStatus, const double value, const double limit,
                                   SHardRiskEvent &eventsOut[])
     {
      if(newStatus == m_state[idx].status)
        {
         // Pas de transition - on rafraichit silencieusement value/limit
         // (utile pour GetShadowReport()) sans emettre d'evenement.
         m_state[idx].value = value;
         m_state[idx].limit = limit;
         return;
        }

      m_state[idx].type       = type;
      m_state[idx].status     = newStatus;
      m_state[idx].value      = value;
      m_state[idx].limit      = limit;
      m_state[idx].reason     = StringFormat("%s : %s -> %s", HardRiskTypeToString(type),
                                              HardRiskStatusToString(m_state[idx].status), HardRiskStatusToString(newStatus));
      m_state[idx].detectedAt = TimeCurrent();

      int n = ArraySize(eventsOut);
      ArrayResize(eventsOut, n + 1);
      eventsOut[n] = m_state[idx];

      m_shadowTransitions++;
     }

public:
                  CHardRiskGuard() : WARNING_RATIO(0.80)
     {
      m_initialized        = false;
      m_peakEquity         = 0.0;
      m_shadowEvaluations  = 0;
      m_shadowTransitions  = 0;
      for(int i = 0; i < 5; i++)
        {
         m_state[i].type       = (ENUM_HARD_RISK_TYPE)(i + 1);
         m_state[i].status     = RISK_STATUS_OK;
         m_state[i].value      = 0.0;
         m_state[i].limit      = 0.0;
         m_state[i].reason     = "";
         m_state[i].detectedAt = 0;
        }
     }

   bool           Init()
     {
      m_peakEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      m_initialized = true;
      return(true);
     }

   bool           IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Evaluate - SPRINT V3.4 : calcule reellement les 5 risques,
   // recalcules integralement depuis des primitives brutes (voir
   // en-tete). Retourne UNIQUEMENT les transitions de statut depuis le
   // dernier appel (tableau dynamique, generalement vide). Ne
   // declenche jamais rien - aucune fermeture, aucune modification de
   // SL/TP, aucun blocage d'entree.
   //---------------------------------------------------------------
   void           Evaluate(const double dailyProfitPercent, const double maxDailyLossPercent, const double maxDailyGainPercent,
                           const double maxDrawdownPercent, const int maxConsecutiveLosses, const int maxPositions,
                           const string symbol, const long magicNumber,
                           SHardRiskEvent &eventsOut[])
     {
      ArrayResize(eventsOut, 0);
      if(!m_initialized)
         return;
      m_shadowEvaluations++;

      // --- 1) Perte journaliere ---
      double lossRatio = (maxDailyLossPercent > 0.0) ? MathMax(0.0, -dailyProfitPercent) / maxDailyLossPercent : 0.0;
      UpdateAndCollect(0, RISK_DAILY_LOSS, ClassifyUsageRatio(lossRatio), dailyProfitPercent, -maxDailyLossPercent, eventsOut);

      // --- 2) Gain journalier ---
      double gainRatio = (maxDailyGainPercent > 0.0) ? MathMax(0.0, dailyProfitPercent) / maxDailyGainPercent : 0.0;
      UpdateAndCollect(1, RISK_DAILY_GAIN, ClassifyUsageRatio(gainRatio), dailyProfitPercent, maxDailyGainPercent, eventsOut);

      // --- 3) Drawdown global (pic d'equite suivi en interne, independant de CStatistics) ---
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(currentEquity > m_peakEquity)
         m_peakEquity = currentEquity;
      double drawdownPercent = (m_peakEquity > 0.0) ? (m_peakEquity - currentEquity) / m_peakEquity * 100.0 : 0.0;
      double drawdownRatio   = (maxDrawdownPercent > 0.0) ? drawdownPercent / maxDrawdownPercent : 0.0;
      UpdateAndCollect(2, RISK_GLOBAL_DRAWDOWN, ClassifyUsageRatio(drawdownRatio), drawdownPercent, maxDrawdownPercent, eventsOut);

      // --- 4) Pertes consecutives (recalculees depuis zero) ---
      int consecutiveLosses = CountConsecutiveLossesIndependently(symbol, magicNumber, maxConsecutiveLosses + 1);
      double consecutiveRatio = (maxConsecutiveLosses > 0) ? (double)consecutiveLosses / (double)maxConsecutiveLosses : 0.0;
      UpdateAndCollect(3, RISK_CONSECUTIVE_LOSSES, ClassifyUsageRatio(consecutiveRatio), (double)consecutiveLosses, (double)maxConsecutiveLosses, eventsOut);

      // --- 5) Positions simultanees (comptees directement, pas via g_positionManager) ---
      int openPositions = CountOpenPositions(symbol, magicNumber);
      double positionsRatio = (maxPositions > 0) ? (double)openPositions / (double)maxPositions : 0.0;
      UpdateAndCollect(4, RISK_MAX_POSITIONS, ClassifyUsageRatio(positionsRatio), (double)openPositions, (double)maxPositions, eventsOut);
     }

   string         GetShadowReport() const
     {
      string s = "===== HARD RISK GUARD (V3.4 - observation, aucune autorite) =====\n";
      s += StringFormat("Evaluations : %d | Transitions detectees : %d\n", m_shadowEvaluations, m_shadowTransitions);
      for(int i = 0; i < 5; i++)
        {
         s += StringFormat("%-22s : %-7s (valeur=%.2f, limite=%.2f)\n",
                            HardRiskTypeToString(m_state[i].type), HardRiskStatusToString(m_state[i].status),
                            m_state[i].value, m_state[i].limit);
        }
      s += "Statut : INACTIF (aucune autorite reelle - observation seule)\n";
      s += "===================================================================";
      return(s);
     }
  };

#endif // HARDRISKGUARD_MQH
//+------------------------------------------------------------------+