//+------------------------------------------------------------------+
//|                                             LearningEngine.mqh     |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.0 - Coquille du Learning Engine.                          |
//|                                                                    |
//| RÔLE FINAL (voir ARCHITECTURE_V3.md §3.6) : observe l'historique   |
//| des décisions et résultats, détecte des régularités, renvoie de la |
//| connaissance au Trade Scenario Engine - UNIQUEMENT entre les       |
//| sessions, jamais en direct pendant un trade en cours. Ne prend     |
//| aucune décision, n'influence rien pendant un trade en cours.       |
//|                                                                    |
//| ÉTAT ACTUEL (Sprint V3.0 UNIQUEMENT) : ce module n'écrit et ne lit |
//| encore rien. OnTradeClosed() est appelé au bon endroit du pipeline |
//| de clôture (site d'appel posé dès maintenant), mais ne fait rien   |
//| tant que le Feature Flag EnableLearningEngine est à false (valeur  |
//| par défaut).                                                        |
//|                                                                    |
//| DÉPENDANCE BLOQUANTE (voir ARCHITECTURE_V3.md §6) : ce module ne   |
//| pourra avoir un rôle réel qu'après réactivation du chantier de     |
//| persistance de CTradeLifecycleTracker (mis en pause volontairement |
//| pour privilégier l'analyse statistique) - observer une source de   |
//| vérité déjà prouvée incomplète produirait un apprentissage biaisé, |
//| pas une connaissance fiable. Prévu Sprint V3.8.                    |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef LEARNINGENGINE_MQH
#define LEARNINGENGINE_MQH

class CLearningEngine
  {
private:
   bool              m_initialized;
   bool              m_flagEnableLearningEngine;
   int               m_tradesObserved;

public:
                     CLearningEngine()
     {
      m_initialized              = false;
      m_flagEnableLearningEngine = false;
      m_tradesObserved           = 0;
     }

   bool              Init(const bool flagEnableLearningEngine)
     {
      m_flagEnableLearningEngine = flagEnableLearningEngine;
      m_initialized              = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // OnTradeClosed - SPRINT V3.0 : n'écrit rien, ne lit rien. Le site
   // d'appel existe (posé au bon endroit du pipeline de clôture) pour
   // que les sprints suivants n'aient qu'à remplir la logique, sans
   // retoucher l'orchestrateur principal. Prend volontairement très
   // peu de paramètres pour l'instant (positionId, résultat) - sera
   // étendu au Sprint V3.8 une fois la source de vérité persistante
   // réactivée, sans changer la signature de ce point d'entrée pour
   // les paramètres déjà présents (compatibilité ascendante).
   //---------------------------------------------------------------
   void              OnTradeClosed(const ulong positionId, const bool isWin)
     {
      if(!m_initialized || !m_flagEnableLearningEngine)
         return; // Comportement par defaut (flag OFF) : observateur totalement passif, meme pas de comptage

      m_tradesObserved++;
      // Aucune ecriture, aucune analyse - reserve au Sprint V3.8
     }

   string            GetShadowReport() const
     {
      return(StringFormat(
         "===== LEARNING ENGINE (V3.0 - mode squelette) =====\n"
         "Trades observes (si flag actif) : %d\n"
         "Statut                          : INACTIF (logique reelle Sprint V3.8, depend de la reactivation de la persistance TradeLifecycleTracker)\n"
         "=====================================================",
         m_tradesObserved));
     }
  };

#endif // LEARNINGENGINE_MQH
//+------------------------------------------------------------------+