//+------------------------------------------------------------------+
//|                                       OpportunityManager.mqh        |
//|                                      NexusEdgeEA - V4.1-P1         |
//|                                                                    |
//| PÉRIMÈTRE DU SPRINT (voir ARCHITECTURE_LOCK.md §5, phase P1) :     |
//| module ISOLÉ. Aucune dépendance vers CMarketStructure,             |
//| CSignalManager, CTradeScenarioEngine, CTradeManager, ou la Research|
//| Platform. Aucun branchement au Trading Engine à ce stade - ce      |
//| fichier doit pouvoir être compilé et testé seul.                   |
//|                                                                    |
//| PRINCIPE (déjà appliqué dans le projet avec                        |
//| IProtectionLevelCalculator/CProfitProtectionEngine et les          |
//| couches d'observation SMC/CTradeScenarioEngine) :                  |
//|   "les objets décrivent, les managers décident"                    |
//| SOpportunityCandidate ne connaît rien de ses propres règles de     |
//| vie. TOUTES les politiques sont ici :                              |
//|   - expiration    (UpdateExpiration)                               |
//|   - déduplication (IsDuplicate)                                    |
//|   - déclenchement (EvaluatePrice)                                  |
//|   - sélection      (SelectFromBatch, privée - jamais exposée)      |
//|                                                                    |
//| PAS DE LATENCE ARTIFICIELLE : ce module ne lit jamais lui-même le  |
//| marché ou l'horloge (pas de TimeCurrent() interne) - "maintenant"  |
//| et "le prix" sont TOUJOURS reçus en paramètre, exactement comme    |
//| CTradeScenarioEngine (invariant 4 de ARCHITECTURE_LOCK.md). Ceci   |
//| rend le module testable de façon déterministe avec une horloge     |
//| synthétique, sans dépendre du marché réel.                          |
//|                                                                    |
//| AUCUNE VUE D'ENSEMBLE BRUTE EXPOSÉE (voir spec validée §5) : pas   |
//| de GetActiveBatch() qui exposerait le tableau interne complet.     |
//| L'extérieur consulte via TryGetById() ou GetTriggeredCount()/      |
//| GetTriggeredAt() - jamais le tableau lui-même.                      |
//|                                                                    |
//| IDEMPOTENCE (CORRECTIF revue, voir SelectFromBatch/                |
//| GetTriggeredAt ci-dessous) : ce manager ne mémorise JAMAIS ce qui   |
//| a déjà été "livré" à un consommateur. Être lu par le TSE n'est pas |
//| un changement d'état métier - c'est un échange entre deux          |
//| composants. Cette mémoire ("j'ai déjà traité OP-154") appartient   |
//| exclusivement au futur pipeline consommateur (P2/TSE), jamais à ce |
//| manager - qui reste ainsi totalement déterministe et réentrant.    |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef OPPORTUNITYMANAGER_MQH
#define OPPORTUNITYMANAGER_MQH

#include "OpportunityTypes.mqh"
#include "OpportunityCandidate.mqh"

class COpportunityManager
  {
private:
   SOpportunityCandidate m_candidates[];

   // --- Politique d'expiration (§4 de la spec, P1 Révision 1) :
   // volontairement une simple durée fixe EN BOUGIES aujourd'hui - le
   // robot raisonne déjà en BOS/CHOCH/structures, jamais en secondes
   // (une durée réelle serait faussée par les week-ends et les ralentis
   // de marché). Pourra devenir une fonction de l'ATR ou de la
   // volatilité demain - SEULE UpdateExpiration() changera alors,
   // SOpportunityCandidate ne stocke jamais de champ "expiresAt". ---
   int                    m_maxAgeBars;

   int               FindIndexById(const string id) const
     {
      int total = ArraySize(m_candidates);
      for(int i = 0; i < total; i++)
         if(m_candidates[i].id == id)
            return(i);
      return(-1);
     }

   //---------------------------------------------------------------
   // Chevauchement géométrique pur - brique de base de IsDuplicate().
   //---------------------------------------------------------------
   bool              ZonesOverlap(const double lowA, const double highA, const double lowB, const double highB) const
     {
      return(lowA <= highB && lowB <= highA);
     }

   //---------------------------------------------------------------
   // SelectFromBatch - PRIVÉE, jamais exposée à l'extérieur (§5 de la
   // spec). Politique de SÉLECTION/ARBITRAGE entre plusieurs candidats
   // TRIGGERED - PUREMENT CALCULÉE à chaque appel, sans aucune mémoire
   // interne de ce qui a déjà été lu (CORRECTIF revue : un manager ne
   // mémorise jamais l'activité de ses consommateurs - "être livré au
   // TSE n'est pas un changement d'état métier, c'est un échange entre
   // deux composants" ; cette mémoire appartient au futur pipeline
   // consommateur, jamais à ce manager). Aujourd'hui : ordre de
   // création pur (le n-ième candidat TRIGGERED rencontré, dans
   // l'ordre du tableau). Demain : pourra arbitrer par score,
   // confiance, proximité de zone - seule cette méthode évoluera, les
   // signatures publiques GetTriggeredCount()/GetTriggeredAt() ne
   // changent pas.
   //---------------------------------------------------------------
   int               SelectFromBatch(const int position) const
     {
      int total = ArraySize(m_candidates);
      int found = 0;
      for(int i = 0; i < total; i++)
        {
         if(m_candidates[i].state != OPPORTUNITY_STATE_TRIGGERED)
            continue;
         if(found == position)
            return(i);
         found++;
        }
      return(-1);
     }

public:
                     COpportunityManager()
     {
      m_maxAgeBars = 0;
     }

   //---------------------------------------------------------------
   // maxAgeBars : politique d'expiration initiale, EN BOUGIES (P1
   // Révision 1). 0 = désactivée (aucun candidat n'expire jamais) -
   // permet aux tests de contrôler explicitement ce comportement
   // plutôt que de le subir.
   //---------------------------------------------------------------
   void              Init(const int maxAgeBars)
     {
      m_maxAgeBars = maxAgeBars;
      ArrayResize(m_candidates, 0);
     }

   int               GetCount() const { return(ArraySize(m_candidates)); }

   int               GetCountByState(const ENUM_OPPORTUNITY_STATE state) const
     {
      int total = ArraySize(m_candidates);
      int n = 0;
      for(int i = 0; i < total; i++)
         if(m_candidates[i].state == state)
            n++;
      return(n);
     }

   //---------------------------------------------------------------
   // IsDuplicate - EXPOSÉE PUBLIQUEMENT ET TESTABLE EN ISOLATION
   // (demande explicite §3 de la spec). Comparaison PURE entre deux
   // candidats, aucun effet de bord, aucune lecture d'état interne.
   // Politique volontairement minimale aujourd'hui (même symbole +
   // même direction + zones qui se chevauchent) : c'est cette méthode,
   // et uniquement elle, qui devra évoluer si la stratégie de
   // déduplication change - aucune structure de données n'en dépend.
   //---------------------------------------------------------------
   bool              IsDuplicate(const SOpportunityCandidate &a, const SOpportunityCandidate &b) const
     {
      if(a.symbol != b.symbol)
         return(false);
      if(a.direction != b.direction)
         return(false);
      return(ZonesOverlap(a.zoneLow, a.zoneHigh, b.zoneLow, b.zoneHigh));
     }

   //---------------------------------------------------------------
   // RegisterCandidate - point d'entrée UNIQUE de création. Applique
   // la déduplication AVANT toute insertion, contre les candidats
   // encore CREATED uniquement (un candidat déjà TRIGGERED/REJECTED/
   // EXPIRED ne bloque plus rien) : un doublon n'est JAMAIS inséré
   // dans le tableau interne - le candidat ne "sait" jamais qu'il a
   // été jugé doublon, conformément à "le candidat ne doit pas
   // connaître ces règles" (§2 de la spec).
   //
   // P1 Révision 1 : createdBarIndex remplace createdTime. creationReason
   // (P2A) décrit un fait du code, jamais une inférence (voir
   // OpportunityTypes.mqh pour les valeurs actuellement légitimes).
   //
   // Retourne "" si le candidat a été refusé comme doublon, sinon
   // retourne son id nouvellement créé.
   //---------------------------------------------------------------
   string            RegisterCandidate(const string symbol, const ENUM_OPPORTUNITY_DIRECTION direction,
                                       const string sourceType, const string creationReason,
                                       const double zoneLow, const double zoneHigh,
                                       const int createdBarIndex)
     {
      SOpportunityCandidate candidate = COpportunityCandidateFactory::Create(symbol, direction, sourceType,
                                                                              creationReason, zoneLow, zoneHigh,
                                                                              createdBarIndex);

      int total = ArraySize(m_candidates);
      for(int i = 0; i < total; i++)
        {
         if(m_candidates[i].state != OPPORTUNITY_STATE_CREATED)
            continue;
         if(IsDuplicate(candidate, m_candidates[i]))
            return(""); // doublon détecté - jamais inséré
        }

      ArrayResize(m_candidates, total + 1);
      m_candidates[total] = candidate;
      return(candidate.id);
     }

   //---------------------------------------------------------------
   // Transition générique - centralise TOUTES les transitions d'état
   // en s'appuyant sur COpportunityCandidateFactory::CanTransition()
   // (règle structurelle pure). Retourne false si la transition est
   // invalide (id inconnu, ou état déjà terminal - aucun retour en
   // arrière possible).
   //---------------------------------------------------------------
   bool              TransitionTo(const string id, const ENUM_OPPORTUNITY_STATE newState)
     {
      int idx = FindIndexById(id);
      if(idx < 0)
         return(false);
      if(!COpportunityCandidateFactory::CanTransition(m_candidates[idx].state, newState))
         return(false);
      m_candidates[idx].state = newState;
      return(true);
     }

   bool              Reject(const string id) { return(TransitionTo(id, OPPORTUNITY_STATE_REJECTED)); }
   bool              Trigger(const string id) { return(TransitionTo(id, OPPORTUNITY_STATE_TRIGGERED)); }

   //---------------------------------------------------------------
   // EvaluatePrice - déclenchement tick-par-tick basé sur la ZONE, pas
   // sur un identifiant (demande explicite §6 de la spec : "le futur
   // déclenchement tick-par-tick ne s'appuiera pas sur un identifiant,
   // il s'appuiera sur prix courant -> zone candidate"). Fait
   // transitionner en TRIGGERED tout candidat CREATED du symbole donné
   // dont la zone contient currentPrice. Ne lit jamais le marché
   // elle-même : symbol/currentPrice sont reçus en paramètre
   // (invariant 4). Retourne le nombre de candidats déclenchés par cet
   // appel.
   //---------------------------------------------------------------
   int               EvaluatePrice(const string symbol, const double currentPrice)
     {
      int triggeredCount = 0;
      int total = ArraySize(m_candidates);
      for(int i = 0; i < total; i++)
        {
         if(m_candidates[i].state != OPPORTUNITY_STATE_CREATED)
            continue;
         if(m_candidates[i].symbol != symbol)
            continue;
         if(!COpportunityCandidateFactory::PriceInZone(m_candidates[i], currentPrice))
            continue;

         m_candidates[i].state = OPPORTUNITY_STATE_TRIGGERED;
         triggeredCount++;
        }
      return(triggeredCount);
     }

   //---------------------------------------------------------------
   // UpdateExpiration - POLITIQUE D'EXPIRATION (§4 de la spec, P1
   // Révision 1). Reçoit currentBarIndex EN PARAMÈTRE - ce manager
   // n'appelle JAMAIS Bars()/iBars() lui-même (invariant 4 :
   // agnostique du marché, exactement comme CTradeScenarioEngine).
   // L'orchestrateur fournit currentBarIndex au même titre qu'il
   // fournit déjà le prix, le contexte, les événements.
   //
   // Aujourd'hui : durée fixe en bougies (m_maxAgeBars). Demain :
   // ATR/volatilité - seule cette méthode changera,
   // SOpportunityCandidate reste identique (createdBarIndex
   // uniquement, jamais expiresAt).
   //---------------------------------------------------------------
   int               UpdateExpiration(const int currentBarIndex)
     {
      if(m_maxAgeBars <= 0)
         return(0); // politique désactivée

      int expiredCount = 0;
      int total = ArraySize(m_candidates);
      for(int i = 0; i < total; i++)
        {
         if(m_candidates[i].state != OPPORTUNITY_STATE_CREATED)
            continue;
         int ageBars = currentBarIndex - m_candidates[i].createdBarIndex;
         if(ageBars >= m_maxAgeBars)
           {
            m_candidates[i].state = OPPORTUNITY_STATE_EXPIRED;
            expiredCount++;
           }
        }
      return(expiredCount);
     }

   //---------------------------------------------------------------
   // ACCÈS EXTERNE - un candidat à la fois, jamais une vue d'ensemble.
   //---------------------------------------------------------------
   bool              TryGetById(const string id, SOpportunityCandidate &out) const
     {
      int idx = FindIndexById(id);
      if(idx < 0)
         return(false);
      out = m_candidates[idx];
      return(true);
     }

   //---------------------------------------------------------------
   // GetTriggeredCount / GetTriggeredAt - consultation IDEMPOTENTE du
   // lot de candidats TRIGGERED, jamais consommatrice (CORRECTIF revue,
   // voir SelectFromBatch ci-dessus). Deux appels successifs sans
   // changement d'état intermédiaire retournent TOUJOURS le même
   // résultat - aucune notion de "déjà livré" n'existe dans ce manager.
   // Un futur pipeline consommateur (TSE en P2, Research en P3, un
   // éventuel Replay) peut donc relire librement le même lot sans effet
   // de bord ; c'est à CE pipeline, et lui seul, de mémoriser ce qu'il
   // a déjà traité (ex: "déjà traité OP-154") - jamais au manager.
   //
   // position est un index dans le SOUS-ENSEMBLE des candidats
   // TRIGGERED (pas un index dans le tableau interne complet), 0-based.
   //---------------------------------------------------------------
   int               GetTriggeredCount() const
     {
      return(GetCountByState(OPPORTUNITY_STATE_TRIGGERED));
     }

   bool              GetTriggeredAt(const int position, SOpportunityCandidate &out) const
     {
      int idx = SelectFromBatch(position);
      if(idx < 0)
         return(false);
      out = m_candidates[idx];
      return(true);
     }
  };

#endif // OPPORTUNITYMANAGER_MQH
//+------------------------------------------------------------------+