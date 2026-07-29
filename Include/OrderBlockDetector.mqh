//+------------------------------------------------------------------+
//|                                        OrderBlockDetector.mqh      |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.2A - Détecteur d'Order Block.                             |
//|                                                                    |
//| RÈGLE ARCHITECTURALE (gravée, voir ARCHITECTURE_V3.md, précision   |
//| Sprint V3.2A) : ce module ne recalcule JAMAIS la structure de       |
//| marché - il consomme exclusivement l'état déjà produit par         |
//| CMarketStructure (GetLastEventDescription, GetPrevSwingHighPrice/   |
//| LowPrice). Il ne détermine jamais lui-même si un BOS/CHOCH a eu     |
//| lieu ni dans quel sens - il se contente de localiser la bougie      |
//| d'origine une fois qu'un BOS est déjà connu. Lire des prix bruts    |
//| (iOpen/iClose) pour cette localisation n'est pas "recalculer la     |
//| structure" - c'est une lecture de données de marché, au même titre |
//| que CMarketStructure::DetectSweep() le fait déjà en interne.        |
//|                                                                    |
//| SÉPARATION Observer → Décrire → Décider (voir ARCHITECTURE_V3.md)  |
//| STRICTEMENT RESPECTÉE : orderBlockValid est une CONSTATATION de     |
//| marché (une clôture a franchi la borne opposée), jamais une         |
//| décision. Ce module ne juge jamais si cette invalidation doit       |
//| clore un scénario - seul le Trade Scenario Engine le fera, une      |
//| fois l'autorité réelle acquise (Sprint V3.6/V3.7).                  |
//|                                                                    |
//| CE QUE CE MODULE NE FAIT JAMAIS : ne modifie aucun module existant, |
//| ne prend aucune décision, n'est pas raccordé au Trade Scenario      |
//| Engine (qui reçoit SScenarioContext dans sa signature depuis le      |
//| Sprint V3.1 mais l'ignore totalement).                              |
//|                                                                    |
//| POSITION DANS LA HIÉRARCHIE : couche d'observation (§3.1/§3.3bis) - |
//| a donc le droit de détenir un pointeur vers CMarketStructure,        |
//| contrairement au TSE lui-même.                                      |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef ORDERBLOCKDETECTOR_MQH
#define ORDERBLOCKDETECTOR_MQH

#include "V3Types.mqh"
#include "MarketStructure.mqh"

class COrderBlockDetector
  {
private:
   CMarketStructure *m_marketStructure; // Référence non propriétaire - autorisée ici (couche d'observation)
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   bool              m_initialized;

   // Mémorise le dernier événement BOS/CHOCH déjà traité, pour ne créer
   // un nouvel Order Block qu'à une transition réelle - même logique
   // que CStructureObserver::m_lastLoggedEventDescription.
   string            m_lastProcessedEventDescription;

   ulong             m_nextOrderBlockId; // Compteur monotone, jamais réinitialisé en cours de session

   //---------------------------------------------------------------
   // Localise la dernière bougie de couleur opposée à la direction du
   // BOS, entre la bougie de confirmation (shift) et le swing cassé
   // lui-même (GetPrevSwingHighPrice/LowPrice, déjà calculé par
   // CMarketStructure) - jamais au-delà. Conforme à la définition
   // institutionnelle retenue : "la dernière bougie opposée précédant
   // le swing cassé", pas une fenêtre de longueur arbitraire.
   //
   // AUCUN RECALCUL DE STRUCTURE : le prix du swing est intégralement
   // fourni par CMarketStructure (source de vérité unique) - ce module
   // se contente de retrouver l'INDEX de bougie correspondant à ce
   // prix déjà connu (lecture de prix bruts), puis de chercher la
   // dernière bougie opposée dans cet intervalle borné par un fait
   // structurel réel, pas par une constante inventée.
   //---------------------------------------------------------------
   bool              FindOriginCandle(const int shift, const bool bullishBOS,
                                      double &highOut, double &lowOut, datetime &timeOut) const
     {
      // Garde-fou TECHNIQUE uniquement (protection contre une boucle
      // sans fin si l'historique disponible est insuffisant) - ne
      // redéfinit jamais la fenêtre de recherche elle-même, qui reste
      // bornée par le swing cassé retrouvé ci-dessous.
      const int SAFETY_CAP = 500;

      // --- Étape 1 : récupérer le swing cassé (déjà calculé par CMarketStructure, aucun recalcul) ---
      double swingPrice = bullishBOS ? m_marketStructure.GetPrevSwingHighPrice() : m_marketStructure.GetPrevSwingLowPrice();
      if(swingPrice <= 0.0)
         return(false); // Aucun swing connu - rien a ancrer, pas d'Order Block cree

      // --- Étape 2 : localiser l'index de bougie de ce swing (lecture de prix bruts uniquement) ---
      int swingIndex = -1;
      for(int i = shift; i < shift + SAFETY_CAP; i++)
        {
         double refPrice = bullishBOS ? iHigh(m_symbol, m_timeframe, i) : iLow(m_symbol, m_timeframe, i);
         if(MathAbs(refPrice - swingPrice) <= _Point * 0.5)
           {
            swingIndex = i;
            break;
           }
        }
      if(swingIndex < 0)
         return(false); // Swing introuvable dans l'historique disponible - pas d'Order Block cree, rien d'invente

      // --- Étape 3 : dernière bougie opposée, entre le BOS (shift) et ce swing UNIQUEMENT ---
      for(int i = shift; i <= swingIndex; i++)
        {
         double o = iOpen(m_symbol, m_timeframe, i);
         double c = iClose(m_symbol, m_timeframe, i);
         bool   isBearishCandle = (c < o);
         bool   isBullishCandle = (c > o);

         if(bullishBOS && isBearishCandle)
           {
            highOut = iHigh(m_symbol, m_timeframe, i);
            lowOut  = iLow(m_symbol, m_timeframe, i);
            timeOut = iTime(m_symbol, m_timeframe, i);
            return(true);
           }
         if(!bullishBOS && isBullishCandle)
           {
            highOut = iHigh(m_symbol, m_timeframe, i);
            lowOut  = iLow(m_symbol, m_timeframe, i);
            timeOut = iTime(m_symbol, m_timeframe, i);
            return(true);
           }
        }
      return(false); // Aucune bougie opposee entre le BOS et le swing casse - pas d'Order Block cree, pas d'erreur
     }

public:
                     COrderBlockDetector()
     {
      m_marketStructure                = NULL;
      m_symbol                         = "";
      m_timeframe                      = PERIOD_CURRENT;
      m_initialized                    = false;
      m_lastProcessedEventDescription  = "";
      m_nextOrderBlockId                = 1;
     }

   bool              Init(CMarketStructure *marketStructure, const string symbol, const ENUM_TIMEFRAMES timeframe)
     {
      if(marketStructure == NULL)
        {
         Print("COrderBlockDetector::Init - marketStructure est NULL");
         return(false);
        }
      m_marketStructure                = marketStructure;
      m_symbol                         = symbol;
      m_timeframe                      = timeframe;
      m_lastProcessedEventDescription  = "";
      m_nextOrderBlockId                = 1;
      m_initialized                     = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Observe - à appeler à la même cadence que CStructureObserver::Observe()
   // (une fois par nouvelle bougie H1), juste après lui. Deux
   // responsabilités distinctes à chaque appel :
   //   1) Détecter un NOUVEAU BOS (transition) -> créer un Order Block
   //   2) Si un Order Block est déjà actif -> constater (pas décider)
   //      s'il reste valide au vu de la clôture de la bougie observée
   //---------------------------------------------------------------
   void              Observe(const int shift, SScenarioContext &contextInOut,
                             string &logTextOut, bool &hasNewEventOut)
     {
      logTextOut     = "";
      hasNewEventOut = false;

      if(!m_initialized || m_marketStructure == NULL)
         return;

      string eventDesc = m_marketStructure.GetLastEventDescription();
      bool   isBos      = (StringFind(eventDesc, "BOS_") == 0);
      bool   isNewEvent = (eventDesc != m_lastProcessedEventDescription);

      // --- 1) Nouveau BOS => nouvel Order Block ---
      if(isBos && isNewEvent)
        {
         bool bullishBOS = (StringFind(eventDesc, "BULLISH") >= 0);
         double obHigh, obLow; datetime obTime;

         if(FindOriginCandle(shift, bullishBOS, obHigh, obLow, obTime))
           {
            contextInOut.orderBlockId        = m_nextOrderBlockId++;
            contextInOut.orderBlockActive    = true;
            contextInOut.orderBlockValid     = true; // Constatation initiale : vient d'être créé, pas encore franchi
            contextInOut.orderBlockDirection = bullishBOS ? DIRECTION_BULLISH : DIRECTION_BEARISH;
            contextInOut.orderBlockHigh      = obHigh;
            contextInOut.orderBlockLow       = obLow;
            contextInOut.orderBlockCreatedAt = obTime;

            logTextOut += StringFormat(
               "[ORDERBLOCK]\nOrder Block detecte (id=%I64u)\nDirection : %s\nZone : %s - %s\nCree le : %s\n",
               contextInOut.orderBlockId, StructureDirectionToString(contextInOut.orderBlockDirection),
               DoubleToString(obLow, _Digits), DoubleToString(obHigh, _Digits),
               TimeToString(obTime, TIME_DATE | TIME_MINUTES));
            hasNewEventOut = true;
           }
         m_lastProcessedEventDescription = eventDesc;
        }

      // --- 2) Order Block deja actif => CONSTATATION de validite (jamais une decision) ---
      if(contextInOut.orderBlockActive && contextInOut.orderBlockValid)
        {
         double closePrice = iClose(m_symbol, m_timeframe, shift);
         bool   breached    = (contextInOut.orderBlockDirection == DIRECTION_BULLISH)
                              ? (closePrice < contextInOut.orderBlockLow)
                              : (closePrice > contextInOut.orderBlockHigh);
         if(breached)
           {
            contextInOut.orderBlockValid = false; // Fait de marche constate, aucune interpretation
            logTextOut += StringFormat(
               "[ORDERBLOCK]\nOrder Block invalide (id=%I64u)\nCloture au-dela de la zone : %s\nHeure : %s\n",
               contextInOut.orderBlockId, DoubleToString(closePrice, _Digits),
               TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
            hasNewEventOut = true;
           }
        }
     }
  };

#endif // ORDERBLOCKDETECTOR_MQH
//+------------------------------------------------------------------+
