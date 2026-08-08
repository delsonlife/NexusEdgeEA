//+------------------------------------------------------------------+
//|                                               FVGDetector.mqh      |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.2B - Détecteur de Fair Value Gap.                         |
//|                                                                    |
//| DÉFINITION RETENUE (délibérément non ambiguë, voir                  |
//| ARCHITECTURE_V3.md, précision Sprint V3.2B) - déséquilibre à 3      |
//| bougies consécutives (1 = plus ancienne, 2 = bougie de              |
//| déplacement, 3 = plus récente) :                                    |
//|   FVG haussier : Low(3) > High(1)  - zone = [High(1), Low(3)]        |
//|   FVG baissier : High(3) < Low(1)  - zone = [High(3), Low(1)]        |
//| Aucune autre variante (imbalance sur corps, FVG à 2 bougies,        |
//| filtrage par taille minimale) n'est implémentée ce sprint.           |
//|                                                                    |
//| INDÉPENDANCE DE CMarketStructure, ASSUMÉE ET DOCUMENTÉE : un FVG    |
//| est une propriété LOCALE des prix, indépendante de tout état        |
//| structurel (BOS/CHOCH/Sweep). Ce module ne détient donc AUCUN       |
//| pointeur vers CMarketStructure, contrairement à COrderBlockDetector |
//| (Sprint V3.2A) dont l'existence dépend, elle, d'un BOS déjà          |
//| confirmé. Le rattacher artificiellement à la structure créerait un  |
//| couplage inutile - ce n'est pas une incohérence avec V3.2A, c'est   |
//| une application cohérente du même principe ("ne dépendre que de ce  |
//| dont on a réellement besoin").                                      |
//|                                                                    |
//| SIMPLIFICATION VOLONTAIRE (voir V3Types.mqh) : un seul FVG suivi à  |
//| la fois - documentée comme limitation assumée, pas comme une        |
//| définition du concept de FVG lui-même.                              |
//|                                                                    |
//| CONVENTION INTERNE AU PROJET (voir V3Types.mqh) : un FVG est        |
//| constaté comblé dès qu'une bougie CLÔTURE au-delà de sa borne        |
//| opposée - comblement complet, pas une mitigation au simple contact. |
//| Ce choix est défendable mais N'EST PAS un consensus universel de la |
//| littérature SMC - il ne doit être changé qu'à la suite d'une        |
//| décision explicite, jamais silencieusement "pour suivre une autre   |
//| école".                                                              |
//|                                                                    |
//| SÉPARATION Observer → Décrire → Décider STRICTEMENT RESPECTÉE :     |
//| fvgValid est une CONSTATATION de marché, jamais une décision - ce   |
//| module ne juge jamais si un comblement doit clore un scénario.       |
//|                                                                    |
//| CE QUE CE MODULE NE FAIT JAMAIS : ne modifie aucun module existant, |
//| ne prend aucune décision, n'est pas raccordé au Trade Scenario      |
//| Engine (qui reçoit SScenarioContext depuis le Sprint V3.1 mais       |
//| l'ignore totalement).                                                |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef FVGDETECTOR_MQH
#define FVGDETECTOR_MQH

#include "V3Types.mqh"

class CFVGDetector
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   bool              m_initialized;
   ulong             m_nextFvgId; // Compteur monotone, jamais réinitialisé en cours de session

public:
                     CFVGDetector()
     {
      m_symbol       = "";
      m_timeframe    = PERIOD_CURRENT;
      m_initialized  = false;
      m_nextFvgId    = 1;
     }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES timeframe)
     {
      m_symbol      = symbol;
      m_timeframe   = timeframe;
      m_nextFvgId   = 1;
      m_initialized = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Observe - à appeler à la même cadence que les autres couches
   // d'observation (une fois par nouvelle bougie H1), après
   // CStructureObserver et COrderBlockDetector. Deux responsabilités
   // distinctes à chaque appel :
   //   1) Détecter un NOUVEAU déséquilibre à 3 bougies -> créer un FVG
   //      (remplace le FVG précédemment suivi, s'il y en avait un -
   //      simplification assumée, voir en-tête)
   //   2) Si un FVG est déjà actif -> constater (pas décider) s'il
   //      reste valide au vu de la clôture de la bougie observée
   //
   // shift : bougie la plus récente des 3 bougies évaluées (1 = dernière
   // clôturée), même convention que les autres détecteurs V3.
   //---------------------------------------------------------------
   void              Observe(const int shift, SScenarioContext &contextInOut,
                             string &logTextOut, bool &hasNewEventOut)
     {
      logTextOut     = "";
      hasNewEventOut = false;

      if(!m_initialized)
         return;

      // --- 1) Recherche d'un nouveau FVG sur les 3 dernières bougies closes ---
      // bougie 1 = la plus ancienne (shift+2), bougie 3 = la plus recente (shift)
      double high1 = iHigh(m_symbol, m_timeframe, shift + 2);
      double low1  = iLow(m_symbol, m_timeframe, shift + 2);
      double high3 = iHigh(m_symbol, m_timeframe, shift);
      double low3  = iLow(m_symbol, m_timeframe, shift);

      bool bullishGap = (low3 > high1);
      bool bearishGap = (high3 < low1);

      if(bullishGap || bearishGap)
        {
         contextInOut.fvgId          = m_nextFvgId++;
         contextInOut.fvgActive      = true;
         contextInOut.fvgValid       = true; // Constatation initiale : vient d'être créé, pas encore comblé
         contextInOut.fvgDirection   = bullishGap ? DIRECTION_BULLISH : DIRECTION_BEARISH;
         contextInOut.fvgHigh        = bullishGap ? low3  : high3;
         contextInOut.fvgLow         = bullishGap ? high1 : low1;
         contextInOut.fvgCreatedAt   = iTime(m_symbol, m_timeframe, shift);
         contextInOut.fvgFillRatio   = 0.0; // Réservé, non calculé ce sprint (voir V3Types.mqh)

         logTextOut += StringFormat(
            "[FVG]\nFVG detecte (id=%I64u)\nDirection : %s\nZone : %s - %s\nCree le : %s\n",
            contextInOut.fvgId, StructureDirectionToString(contextInOut.fvgDirection),
            DoubleToString(contextInOut.fvgLow, _Digits), DoubleToString(contextInOut.fvgHigh, _Digits),
            TimeToString(contextInOut.fvgCreatedAt, TIME_DATE | TIME_MINUTES));
         hasNewEventOut = true;
         return; // Un FVG vient d'être créé sur cette bougie - pas de vérification de comblement au même appel
        }

      // --- 2) FVG deja actif => CONSTATATION de validite (jamais une decision) ---
      if(contextInOut.fvgActive && contextInOut.fvgValid)
        {
         double closePrice = iClose(m_symbol, m_timeframe, shift);
         bool   filled      = (contextInOut.fvgDirection == DIRECTION_BULLISH)
                              ? (closePrice < contextInOut.fvgLow)
                              : (closePrice > contextInOut.fvgHigh);
         if(filled)
           {
            contextInOut.fvgValid = false; // Fait de marche constate (convention interne, voir en-tete), aucune interpretation
            logTextOut += StringFormat(
               "[FVG]\nFVG comble (id=%I64u)\nCloture au-dela de la zone : %s\nHeure : %s\n",
               contextInOut.fvgId, DoubleToString(closePrice, _Digits),
               TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
            hasNewEventOut = true;
           }
        }
     }
  };

#endif // FVGDETECTOR_MQH
//+------------------------------------------------------------------+