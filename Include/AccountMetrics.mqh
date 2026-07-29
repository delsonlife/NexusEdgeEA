//+------------------------------------------------------------------+
//|                                             AccountMetrics.mqh     |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.6.5 - Account Metrics Layer (Option C validée).           |
//|                                                                    |
//| CONTEXTE DU CORRECTIF : l'audit a démontré que                      |
//| `CStatistics::GetMaxDrawdownPercent()` calcule correctement le      |
//| drawdown MAXIMAL HISTORIQUE (une grandeur monotone, jamais          |
//| décroissante) alors que `CFilters` l'utilisait comme s'il           |
//| s'agissait d'un drawdown COURANT (récupérable). Conséquence :        |
//| dès qu'un drawdown dépassait `InpMaxDrawdownPercent` une seule fois, |
//| plus aucune entrée n'était jamais autorisée pour le reste du test    |
//| (verrouillage permanent, démontré sur deux backtests indépendants). |
//|                                                                    |
//| RESPONSABILITÉ UNIQUE DE CE MODULE : suivre l'état COURANT du       |
//| compte (équité, pic d'équité, drawdown courant) - jamais une        |
//| statistique historique agrégée (ça reste l'exclusivité de           |
//| `CStatistics`, non modifiée), jamais une décision de trading.        |
//|                                                                    |
//| AUCUNE DÉPENDANCE vers `CTradeManager`, `CStatistics`, `CFilters`,   |
//| `CLearningEngine`, `CShadowAnalytics`, `CHardRiskGuard` - vérifié    |
//| ligne par ligne dans ce fichier. La seule dépendance externe est     |
//| `CUtilities::ReconstructPeakEquity()`, une fonction STATIQUE ET      |
//| PURE (aucun état, aucune connaissance d'aucune classe métier,        |
//| uniquement des primitives broker) - ce n'est pas un couplage vers    |
//| un composant métier vivant, au même titre qu'appeler                |
//| `CUtilities::SafeDivide()` n'en est pas un non plus.                 |
//|                                                                    |
//| COHÉRENCE AVEC `CHardRiskGuard` : ce module suit le même principe    |
//| d'indépendance déjà appliqué au Sprint V3.4 - mais avec un           |
//| perfectionnement que `CHardRiskGuard` n'a pas : la reconstruction    |
//| du pic au démarrage (voir Init() ci-dessous), pour ne jamais         |
//| perdre un drawdown réel en cours au moment d'un redémarrage de       |
//| l'EA. `CHardRiskGuard` n'est PAS modifié par ce sprint - il          |
//| continue son propre calcul interne, indépendant, exactement comme    |
//| avant.                                                                |
//|                                                                    |
//| CADENCE : Update() doit être appelée UNE FOIS PAR TICK, en tout      |
//| début d'OnTick(), avant toute autre logique - contrairement aux      |
//| couches d'observation V3 (Structure/Order Block/FVG/HTF), qui sont   |
//| volontairement cadencées à la bougie, l'équité du compte change       |
//| réellement à chaque tick dès qu'une position est ouverte : la         |
//| mettre à jour à cette cadence n'est pas du spam, c'est respecter la  |
//| cadence naturelle de la donnée elle-même.                            |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef ACCOUNTMETRICS_MQH
#define ACCOUNTMETRICS_MQH

#include "Utilities.mqh"

class CAccountMetrics
  {
private:
   bool   m_initialized;
   double m_peakEquity;

public:
                     CAccountMetrics()
     {
      m_initialized = false;
      m_peakEquity  = 0.0;
     }

   //---------------------------------------------------------------
   // Init - reconstruit le pic d'équité RÉEL depuis l'historique des
   // deals de clôture, via la primitive pure CUtilities::
   // ReconstructPeakEquity() - UNE SEULE lecture, ponctuelle, au
   // démarrage. Ensuite, ce composant devient totalement autonome :
   // aucun autre appel vers cette fonction ni vers aucune autre classe
   // n'a lieu après Init().
   //---------------------------------------------------------------
   bool              Init(const double initialBalance, const string symbol, const long magicNumber)
     {
      m_peakEquity  = CUtilities::ReconstructPeakEquity(initialBalance, symbol, magicNumber);

      // Garde-fou : l'équité réelle actuelle du compte peut déjà être
      // supérieure au pic reconstruit depuis l'historique clôturé
      // (ex. position flottante déjà en profit au démarrage) - le pic
      // ne doit jamais être inférieur à la réalité déjà observable.
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(currentEquity > m_peakEquity)
         m_peakEquity = currentEquity;

      m_initialized = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Update - à appeler une fois par tick, avant toute logique
   // métier. Une seule lecture d'équité, une seule comparaison -
   // aucun calcul coûteux, aucune lecture d'historique (contrairement
   // à Init(), qui ne s'exécute qu'une fois).
   //---------------------------------------------------------------
   void              Update()
     {
      if(!m_initialized)
         return;
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(currentEquity > m_peakEquity)
         m_peakEquity = currentEquity;
     }

   //---------------------------------------------------------------
   // GetCurrentDrawdownPercent - LA donnée réellement consommée par
   // CFilters (au point d'appel existant, sans modification de
   // CFilters lui-même). Recalculée à la demande, jamais mise en
   // cache au-delà d'un tick - par construction, aucune variable ne
   // peut rester "verrouillée" : si l'équité remonte, ce pourcentage
   // redescend mécaniquement au prochain appel.
   //---------------------------------------------------------------
   double            GetCurrentDrawdownPercent() const
     {
      if(!m_initialized || m_peakEquity <= 0.0)
         return(0.0);
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double drawdown      = (m_peakEquity - currentEquity) / m_peakEquity * 100.0;
      return(drawdown > 0.0 ? drawdown : 0.0);
     }
  };

#endif // ACCOUNTMETRICS_MQH
//+------------------------------------------------------------------+