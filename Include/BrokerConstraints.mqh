//+------------------------------------------------------------------+
//|                                          BrokerConstraints.mqh     |
//|                                              NexusEdgeEA           |
//|                                                                     |
//| NOUVEAU (Sprint 1 - Gestion intelligente des refus broker).        |
//|                                                                     |
//| CONTEXTE : l'analyse du backtest de validation puis des logs live  |
//| du 22/07 a montre des MILLIERS de tentatives de modification de SL |
//| rejetees par le broker (retcode=10016, "Invalid Stops"), parfois   |
//| plusieurs fois par seconde pendant plus d'une heure sur un seul    |
//| ticket - sans qu'aucun mecanisme ne comprenne POURQUOI, ni         |
//| n'adapte son comportement. Cause racine identifiee : aucun module  |
//| du projet ne verifiait la distance minimale (StopsLevel/          |
//| FreezeLevel) du broker AVANT de soumettre une modification, et     |
//| AUCUNE memoire n'empechait de retenter indefiniment la meme        |
//| demande deja refusee au tick precedent.                            |
//|                                                                     |
//| RESPONSABILITE DE CETTE CLASSE (et UNIQUEMENT celle-ci) :          |
//|   - Connaissance NOMINALE : ce que le broker declare lui-meme      |
//|     (SYMBOL_TRADE_STOPS_LEVEL, SYMBOL_TRADE_FREEZE_LEVEL).         |
//|   - Connaissance APPRISE : une marge de securite additionnelle,    |
//|     construite a partir des refus REELS observes (certains brokers |
//|     appliquent une contrainte plus stricte que celle annoncee dans |
//|     SymbolInfo). Ne decroit jamais automatiquement - anticipation  |
//|     deliberee pour une future persistance (voir echange dedie) :   |
//|     une marge apprise ne doit pas pouvoir "disparaitre par hasard".|
//|   - Memoire de refus PAR TICKET : evite de retenter inutilement la |
//|     meme demande tant que les conditions n'ont pas change.         |
//|                                                                     |
//| CETTE CLASSE NE FAIT JAMAIS APPEL A CTrade NI A CTradeManager - elle|
//| ne connait que SymbolInfo* et des faits qu'on lui transmet. C'est  |
//| CTradeManager (seul point de passage vers le broker dans tout le   |
//| projet) qui la possede et l'alimente - jamais l'inverse, et jamais |
//| ProfitProtectionEngine ou ses calculateurs, qui continuent a       |
//| ignorer totalement l'existence du broker.                          |
//|                                                                     |
//| ANTICIPATION ARCHITECTURALE (persistance, point 1 de l'echange     |
//| dedie) : cette classe ne connait AUCUN mecanisme de stockage. Le   |
//| jour ou l'apprentissage devra survivre a un redemarrage MT5/VPS,   |
//| il suffira d'ajouter Serialize()/Deserialize() ici (donnee pure),  |
//| sans toucher au reste de la classe ni a ses appelants.             |
//|                                                                     |
//| ANTICIPATION ARCHITECTURALE (contraintes vs habitudes, point 2 de  |
//| l'echange dedie) : cette classe ne porte QUE des contraintes       |
//| factuelles et ponctuelles (StopsLevel/FreezeLevel/marge apprise).  |
//| Le futur moteur d'HABITUDES du broker (spreads qui explosent a la  |
//| reouverture, refus plus frequents a certaines heures...) sera une  |
//| classe SOEUR distincte (ex: CBrokerBehaviorProfile), jamais         |
//| fusionnee ici - pour ne pas reproduire l'erreur d'une structure     |
//| fourre-tout qui merait des faits verifiables et des statistiques   |
//| comportementales.                                                   |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef BROKERCONSTRAINTS_MQH
#define BROKERCONSTRAINTS_MQH

#include "Types.mqh"

class CBrokerConstraintProfile
  {
private:
   string            m_symbol;
   bool              m_initialized;

   // --- Connaissance NOMINALE (relue periodiquement, pas a chaque tick) ---
   double            m_stopsLevelPoints;
   double            m_freezeLevelPoints;
   datetime          m_lastNominalRefresh;

   // --- Connaissance APPRISE (voir doc en-tete : ne decroit jamais seule) ---
   double            m_learnedMarginPoints;

   // --- Memoire de refus PAR TICKET ---
   ulong             m_ticket[];
   ENUM_BROKER_REJECTION_REASON m_lastReason[];
   double            m_lastRejectedLevel[];
   datetime          m_lastRejectionTime[];
   int               m_consecutiveRejections[];

   // --- Compteurs pour le rapport de diagnostic ---
   int               m_totalRejections;
   int               m_totalByReason[7]; // indexe par ENUM_BROKER_REJECTION_REASON (0..6)
   int               m_totalClampedAndAccepted; // tentatives sauvees par le clamp StopsLevel

   int               FindTicketIndex(const ulong ticket) const
     {
      int total = ArraySize(m_ticket);
      for(int i = 0; i < total; i++)
         if(m_ticket[i] == ticket)
            return(i);
      return(-1);
     }

   int               EnsureTicketIndex(const ulong ticket)
     {
      int idx = FindTicketIndex(ticket);
      if(idx >= 0)
         return(idx);
      int n = ArraySize(m_ticket);
      ArrayResize(m_ticket, n + 1);
      ArrayResize(m_lastReason, n + 1);
      ArrayResize(m_lastRejectedLevel, n + 1);
      ArrayResize(m_lastRejectionTime, n + 1);
      ArrayResize(m_consecutiveRejections, n + 1);
      m_ticket[n]                 = ticket;
      m_lastReason[n]             = REJECTION_NONE;
      m_lastRejectedLevel[n]      = 0.0;
      m_lastRejectionTime[n]      = 0;
      m_consecutiveRejections[n]  = 0;
      return(n);
     }

   //---------------------------------------------------------------
   // Relit les contraintes nominales du broker - au plus une fois par
   // minute (ces valeurs ne changent jamais tick par tick, inutile de
   // payer le cout d'un SymbolInfoInteger() a chaque appel).
   //---------------------------------------------------------------
   void              RefreshNominalIfNeeded()
     {
      if(!m_initialized)
         return;
      if(m_lastNominalRefresh != 0 && (TimeCurrent() - m_lastNominalRefresh) < 60)
         return;
      m_stopsLevelPoints   = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      m_freezeLevelPoints  = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      m_lastNominalRefresh = TimeCurrent();
     }

public:
                     CBrokerConstraintProfile()
     {
      m_symbol               = "";
      m_initialized           = false;
      m_stopsLevelPoints      = 0.0;
      m_freezeLevelPoints     = 0.0;
      m_lastNominalRefresh    = 0;
      m_learnedMarginPoints   = 0.0;
      m_totalRejections       = 0;
      m_totalClampedAndAccepted = 0;
      ArrayInitialize(m_totalByReason, 0);
     }

   void              Init(const string symbol)
     {
      m_symbol      = symbol;
      m_initialized = true;
      ArrayResize(m_ticket, 0);
      RefreshNominalIfNeeded();
     }

   //---------------------------------------------------------------
   // Distance minimale (en points) que doit respecter tout SL par
   // rapport au prix courant pour avoir une chance d'etre accepte -
   // connaissance nominale + marge apprise (jamais l'inverse : on ne
   // relache jamais une marge apprise automatiquement).
   //---------------------------------------------------------------
   double            GetEffectiveMinDistancePoints()
     {
      RefreshNominalIfNeeded();
      return(MathMax(m_stopsLevelPoints, m_freezeLevelPoints) + m_learnedMarginPoints);
     }

   double            GetFreezeLevelPoints()
     {
      RefreshNominalIfNeeded();
      return(m_freezeLevelPoints);
     }

   //---------------------------------------------------------------
   // Vrai si, pour CE ticket, un refus quasi identique (meme raison,
   // niveau demande a moins de 2 points du dernier niveau refuse) a eu
   // lieu il y a moins de minRepeatToleranceSeconds - dans ce cas,
   // retenter est inutile tant que le marche n'a pas suffisamment
   // bouge. Repond directement a la demande : "eviter de retenter
   // inutilement la meme demande tant que les conditions n'ont pas
   // change".
   //---------------------------------------------------------------
   bool              HasRecentIdenticalRejection(const ulong ticket, const double desiredLevel,
                                                 const int minRepeatToleranceSeconds = 5) const
     {
      int idx = FindTicketIndex(ticket);
      if(idx < 0)
         return(false);
      if(m_lastReason[idx] == REJECTION_NONE)
         return(false);
      if((TimeCurrent() - m_lastRejectionTime[idx]) >= minRepeatToleranceSeconds)
         return(false);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0.0)
         return(false);
      double distancePoints = MathAbs(desiredLevel - m_lastRejectedLevel[idx]) / point;
      return(distancePoints < 2.0);
     }

   ENUM_BROKER_REJECTION_REASON GetLastReason(const ulong ticket) const
     {
      int idx = FindTicketIndex(ticket);
      if(idx < 0)
         return(REJECTION_NONE);
      return(m_lastReason[idx]);
     }

   //---------------------------------------------------------------
   // Vrai si le SL ACTUEL est deja trop proche du prix courant pour
   // qu'AUCUNE modification ne puisse etre acceptee (FreezeLevel) -
   // dans ce cas, meme un niveau "clampe" ne servirait a rien : il
   // faut attendre que le prix s'ecarte, pas recalculer un niveau.
   //---------------------------------------------------------------
   bool              IsFrozen(const double currentPrice, const double currentSL)
     {
      RefreshNominalIfNeeded();
      if(m_freezeLevelPoints <= 0.0 || currentSL == 0.0)
         return(false);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0.0)
         return(false);
      double currentDistancePoints = MathAbs(currentPrice - currentSL) / point;
      return(currentDistancePoints <= m_freezeLevelPoints);
     }

   //---------------------------------------------------------------
   // A appeler juste apres un PositionModify() qui a REELLEMENT
   // ECHOUE, avec le vrai retcode broker. Classe la raison (au mieux -
   // "Invalid Stops" seul ne dit pas s'il s'agit de StopsLevel ou
   // FreezeLevel, d'ou l'heuristique basee sur la distance du SL
   // ACTUEL, distincte du niveau qui a ete refuse), met a jour la
   // memoire par ticket, et APPREND si le refus contredit ce que ce
   // profil croyait valide (marge cachee non documentee par SymbolInfo).
   //---------------------------------------------------------------
   void              RecordRejection(const ulong ticket, const uint retcode, const double attemptedLevel,
                                     const double currentPrice, const double currentSL)
     {
      ENUM_BROKER_REJECTION_REASON reason = ClassifyRetcode(retcode);

      // "Invalid Stops" est ambigu par nature (le broker ne precise pas
      // laquelle des deux contraintes a ete violee) - on affine via le
      // SL ACTUEL : s'il est deja dans la zone de gel, c'est un
      // FreezeLevel (aucun niveau n'aurait ete accepte). Sinon, c'est
      // un StopsLevel (un autre niveau, plus loin du prix, pourrait
      // convenir).
      if(reason == REJECTION_STOPS_LEVEL)
        {
         if(IsFrozen(currentPrice, currentSL))
            reason = REJECTION_FREEZE_LEVEL;

         double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
         if(point > 0.0)
           {
            double attemptedDistancePoints = MathAbs(currentPrice - attemptedLevel) / point;
            double believedMin = GetEffectiveMinDistancePoints();
            if(attemptedDistancePoints >= believedMin)
              {
               // Le refus contredit la connaissance actuelle : la vraie
               // contrainte broker est plus stricte que celle annoncee -
               // on augmente la marge apprise par petits pas, pour
               // converger sans sur-corriger sur un seul refus isole.
               m_learnedMarginPoints += 5.0;
              }
           }
        }

      m_totalRejections++;
      int ridx = (int)reason;
      if(ridx >= 0 && ridx < ArraySize(m_totalByReason))
         m_totalByReason[ridx]++;

      int idx = EnsureTicketIndex(ticket);
      m_lastReason[idx]            = reason;
      m_lastRejectedLevel[idx]     = attemptedLevel;
      m_lastRejectionTime[idx]     = TimeCurrent();
      m_consecutiveRejections[idx]++;
     }

   //---------------------------------------------------------------
   // A appeler apres un PositionModify() REUSSI - remet a zero le
   // compteur de refus consecutifs de ce ticket (les conditions ont
   // change, la memoire de refus n'a plus de raison d'etre gardee).
   //---------------------------------------------------------------
   void              RecordSuccess(const ulong ticket)
     {
      int idx = FindTicketIndex(ticket);
      if(idx >= 0)
        {
         m_consecutiveRejections[idx] = 0;
         m_lastReason[idx]            = REJECTION_NONE;
        }
     }

   void              RecordClampedAndAccepted() { m_totalClampedAndAccepted++; }

   static ENUM_BROKER_REJECTION_REASON ClassifyRetcode(const uint retcode)
     {
      switch(retcode)
        {
         case TRADE_RETCODE_INVALID_STOPS:
            return(REJECTION_STOPS_LEVEL); // Affine ensuite via IsFrozen() dans RecordRejection()
         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_CHANGED:
         case TRADE_RETCODE_PRICE_OFF:
            return(REJECTION_REQUOTE);
         case TRADE_RETCODE_TRADE_DISABLED:
         case TRADE_RETCODE_MARKET_CLOSED:
            return(REJECTION_MARKET_CLOSED_OR_DISABLED);
         case TRADE_RETCODE_CONNECTION:
         case TRADE_RETCODE_TIMEOUT:
         case TRADE_RETCODE_TOO_MANY_REQUESTS:
            return(REJECTION_TRADE_CONTEXT_BUSY_OR_NO_CONNECTION);
         default:
            return(REJECTION_OTHER);
        }
     }

   static string     ReasonToString(const ENUM_BROKER_REJECTION_REASON reason)
     {
      switch(reason)
        {
         case REJECTION_NONE:                                return("Aucun");
         case REJECTION_STOPS_LEVEL:                         return("StopsLevel (niveau trop proche du prix)");
         case REJECTION_FREEZE_LEVEL:                        return("FreezeLevel (SL actuel deja trop proche - gel total)");
         case REJECTION_REQUOTE:                              return("Requote/PrixChange");
         case REJECTION_TRADE_CONTEXT_BUSY_OR_NO_CONNECTION:  return("ContexteOccupe/PasDeConnexion");
         case REJECTION_MARKET_CLOSED_OR_DISABLED:            return("MarcheFerme/TradingDesactive");
         default:                                             return("Autre");
        }
     }

   //---------------------------------------------------------------
   // Rapport de diagnostic - meme esprit que GetActivationReport() du
   // Profit Protection Engine, consultable a OnDeinit().
   //---------------------------------------------------------------
   string            GetReport() const
     {
      string r = "===== BROKER CONSTRAINT PROFILE - " + m_symbol + " =====\n";
      r += StringFormat("StopsLevel nominal=%.0f pts | FreezeLevel nominal=%.0f pts | Marge apprise=%.0f pts (jamais decroissante)\n",
                        m_stopsLevelPoints, m_freezeLevelPoints, m_learnedMarginPoints);
      r += StringFormat("Refus totaux=%d | Tentatives evitees par clamp reussi=%d\n", m_totalRejections, m_totalClampedAndAccepted);
      for(int i = 0; i < ArraySize(m_totalByReason); i++)
        {
         if(m_totalByReason[i] > 0)
            r += StringFormat("   -> %s : %d fois\n", ReasonToString((ENUM_BROKER_REJECTION_REASON)i), m_totalByReason[i]);
        }
      r += "===================================================\n";
      return(r);
     }
  };

#endif