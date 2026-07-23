//+------------------------------------------------------------------+
//|                                             MarketStructure.mqh    |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| Description : Analyse de structure de marché (style SMC/ICT).     |
//|   CMarketStructure répond à trois questions posées explicitement :|
//|     - "Les trades avec BOS + CHOCH performent-ils mieux ?"        |
//|     - "Les trades sans sweep perdent-ils plus souvent ?"          |
//|                                                                    |
//| AVERTISSEMENT (même esprit que la phase Wyckoff dans               |
//|   MarketContext.mqh) : BOS/CHOCH/Sweep n'ont PAS de définition     |
//|   universelle unique dans la communauté du trading. Ce module      |
//|   implémente une lecture RAISONNABLE et documentée, pas une        |
//|   vérité académique. Si ce que tu observes sur le graphique ne     |
//|   correspond pas à ce que le module rapporte, la définition        |
//|   ci-dessous doit être ajustée - ce n'est pas un bug, c'est un     |
//|   choix de modélisation explicite à discuter.                      |
//|                                                                    |
//| DÉFINITIONS RETENUES ICI :                                         |
//|   - Un SWING HIGH/LOW confirmé = extremum local sur                |
//|     [swingStrength] bougies de chaque côté (même principe que      |
//|     CSupportResistance, mais réimplémenté indépendamment ici : ce  |
//|     module sert une classification différente - BOS/CHOCH -,       |
//|     alors que CSupportResistance sert la fusion en zones S/R. Une  |
//|     petite duplication assumée plutôt qu'un couplage fragile entre |
//|     deux responsabilités différentes).                              |
//|   - BOS (Break of Structure) = un nouveau swing confirmé dépasse   |
//|     le swing précédent DANS LE SENS DU BIAIS DE STRUCTURE ACTUEL   |
//|     (continuation).                                                 |
//|   - CHOCH (Change of Character) = un nouveau swing confirmé        |
//|     dépasse le swing précédent DANS LE SENS OPPOSÉ au biais actuel |
//|     (premier signal de retournement) - le biais bascule alors.     |
//|   - SWEEP (liquidity sweep) = une bougie dont la mèche dépasse un  |
//|     swing high/low récent MAIS dont la clôture revient à           |
//|     l'intérieur (chasse de stops suivie d'un retour).              |
//|                                                                    |
//| OBSERVATEUR PUR : ne modifie jamais aucune position, n'influence   |
//| aucun signal ni filtre.                                            |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef MARKETSTRUCTURE_MQH
#define MARKETSTRUCTURE_MQH

#include "Types.mqh"
#include "Utilities.mqh"

//+------------------------------------------------------------------+
//| ENUM - Type de biais de structure interne (privé au module)       |
//+------------------------------------------------------------------+
enum ENUM_STRUCTURE_BIAS
  {
   STRUCTURE_BIAS_UNKNOWN  = 0,
   STRUCTURE_BIAS_BULLISH  = 1,
   STRUCTURE_BIAS_BEARISH  = 2
  };

//+------------------------------------------------------------------+
//| Classe CMarketStructure                                              |
//+------------------------------------------------------------------+
class CMarketStructure
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_swingStrength;   // Bougies de chaque côté requises pour confirmer un swing
   int               m_lookbackBars;    // Profondeur scannée pour trouver le swing le plus récent / le sweep
   bool              m_initialized;

   double            m_lastSwingHighPrice;
   double            m_prevSwingHighPrice;
   double            m_lastSwingLowPrice;
   double            m_prevSwingLowPrice;
   ENUM_STRUCTURE_BIAS m_bias;

   string            m_lastEventDescription;

   //---------------------------------------------------------------
   // Vérifie si la bougie à l'index "idx" est un plus haut local
   // confirmé (m_swingStrength bougies de chaque côté plus basses).
   //---------------------------------------------------------------
   bool              IsConfirmedSwingHigh(const int idx) const
     {
      double centerHigh = iHigh(m_symbol, m_timeframe, idx);
      for(int k = 1; k <= m_swingStrength; k++)
        {
         if(iHigh(m_symbol, m_timeframe, idx - k) >= centerHigh) return(false); // bougie plus récente
         if(iHigh(m_symbol, m_timeframe, idx + k) >= centerHigh) return(false); // bougie plus ancienne
        }
      return(true);
     }

   bool              IsConfirmedSwingLow(const int idx) const
     {
      double centerLow = iLow(m_symbol, m_timeframe, idx);
      for(int k = 1; k <= m_swingStrength; k++)
        {
         if(iLow(m_symbol, m_timeframe, idx - k) <= centerLow) return(false);
         if(iLow(m_symbol, m_timeframe, idx + k) <= centerLow) return(false);
        }
      return(true);
     }

   //---------------------------------------------------------------
   // Cherche le swing high confirmé le plus récent dans la fenêtre
   // [minIdx .. minIdx+lookback], en partant du plus récent.
   //---------------------------------------------------------------
   bool              FindMostRecentSwingHigh(const int startIdx, double &priceOut, int &idxOut) const
     {
      for(int idx = startIdx; idx < startIdx + m_lookbackBars; idx++)
        {
         if(IsConfirmedSwingHigh(idx))
           {
            priceOut = iHigh(m_symbol, m_timeframe, idx);
            idxOut   = idx;
            return(true);
           }
        }
      return(false);
     }

   bool              FindMostRecentSwingLow(const int startIdx, double &priceOut, int &idxOut) const
     {
      for(int idx = startIdx; idx < startIdx + m_lookbackBars; idx++)
        {
         if(IsConfirmedSwingLow(idx))
           {
            priceOut = iLow(m_symbol, m_timeframe, idx);
            idxOut   = idx;
            return(true);
           }
        }
      return(false);
     }

public:
                     CMarketStructure()
     {
      m_symbol              = "";
      m_timeframe           = PERIOD_CURRENT;
      m_swingStrength        = 2;
      m_lookbackBars         = 50;
      m_initialized          = false;
      m_lastSwingHighPrice   = 0.0;
      m_prevSwingHighPrice   = 0.0;
      m_lastSwingLowPrice    = 0.0;
      m_prevSwingLowPrice    = 0.0;
      m_bias                 = STRUCTURE_BIAS_UNKNOWN;
      m_lastEventDescription = "Aucun evenement";
     }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES timeframe,
                          const int swingStrength = 2, const int lookbackBars = 50)
     {
      m_symbol        = symbol;
      m_timeframe     = timeframe;
      m_swingStrength = swingStrength;
      m_lookbackBars  = lookbackBars;
      m_initialized   = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // À appeler UNE FOIS PAR NOUVELLE BOUGIE (même cadence que
   // CMarketContext::Update() et CSupportResistance::Update()).
   // Détecte si un nouveau swing confirmé est apparu depuis le
   // dernier appel, et classe l'événement en BOS ou CHOCH.
   // shift=1 : le swing candidat le plus récent qui peut être confirmé
   // est nécessairement à shift+swingStrength au minimum (il faut
   // swingStrength bougies APRÈS lui pour le confirmer).
   //---------------------------------------------------------------
   void              Update(const int shift = 1)
     {
      if(!m_initialized)
         return;

      int searchStart = shift + m_swingStrength;

      double newHigh; int idxHigh;
      if(FindMostRecentSwingHigh(searchStart, newHigh, idxHigh))
        {
         if(newHigh != m_lastSwingHighPrice) // Nouveau swing high détecté depuis le dernier passage
           {
            m_prevSwingHighPrice = m_lastSwingHighPrice;
            m_lastSwingHighPrice = newHigh;

            if(m_prevSwingHighPrice > 0.0)
              {
               bool brokeAbovePrevHigh = (newHigh > m_prevSwingHighPrice);
               // Un nouveau plus haut qui dépasse le précédent plus haut :
               // BOS haussier si le biais était déjà haussier, sinon CHOCH
               // haussier (premier signe de retournement).
               if(brokeAbovePrevHigh)
                 {
                  if(m_bias == STRUCTURE_BIAS_BULLISH || m_bias == STRUCTURE_BIAS_UNKNOWN)
                    {
                     m_bias = STRUCTURE_BIAS_BULLISH;
                     m_lastEventDescription = "BOS_BULLISH";
                    }
                  else
                    {
                     m_bias = STRUCTURE_BIAS_BULLISH;
                     m_lastEventDescription = "CHOCH_BULLISH";
                    }
                 }
              }
           }
        }

      double newLow; int idxLow;
      if(FindMostRecentSwingLow(searchStart, newLow, idxLow))
        {
         if(newLow != m_lastSwingLowPrice)
           {
            m_prevSwingLowPrice = m_lastSwingLowPrice;
            m_lastSwingLowPrice = newLow;

            if(m_prevSwingLowPrice > 0.0)
              {
               bool brokeBelowPrevLow = (newLow < m_prevSwingLowPrice);
               if(brokeBelowPrevLow)
                 {
                  if(m_bias == STRUCTURE_BIAS_BEARISH || m_bias == STRUCTURE_BIAS_UNKNOWN)
                    {
                     m_bias = STRUCTURE_BIAS_BEARISH;
                     m_lastEventDescription = "BOS_BEARISH";
                    }
                  else
                    {
                     m_bias = STRUCTURE_BIAS_BEARISH;
                     m_lastEventDescription = "CHOCH_BEARISH";
                    }
                 }
              }
           }
        }
     }

   //---------------------------------------------------------------
   // Description texte du dernier événement de structure détecté
   // ("BOS_BULLISH", "CHOCH_BEARISH", "Aucun evenement"...). Reflète
   // l'état à l'instant de l'appel - à lire juste après Update() au
   // moment de l'ouverture d'un trade pour capturer le contexte.
   //---------------------------------------------------------------
   string            GetLastEventDescription() const { return(m_lastEventDescription); }

   ENUM_STRUCTURE_BIAS GetCurrentBias() const { return(m_bias); }

   //---------------------------------------------------------------
   // NOUVEAU (Profit Guard - Niveau 2 "Protection structurelle").
   // Expose les niveaux de swing bruts, en lecture seule, pour
   // permettre à un module tiers (ProfitProtectionEngine) de définir
   // SA PROPRE interprétation (ex: "Higher Low" = dernier swing low
   // confirmé > précédent) sans que CMarketStructure ait à connaître
   // ce concept lui-même - reste un détecteur générique de structure,
   // réutilisable par n'importe quel futur module (FVG, Order Blocks...).
   // Retourne 0.0 si aucun swing confirmé pour l'instant (cas normal
   // en tout début de série de données).
   //---------------------------------------------------------------
   double            GetLastSwingHighPrice() const { return(m_lastSwingHighPrice); }
   double            GetPrevSwingHighPrice() const { return(m_prevSwingHighPrice); }
   double            GetLastSwingLowPrice() const { return(m_lastSwingLowPrice); }
   double            GetPrevSwingLowPrice() const { return(m_prevSwingLowPrice); }

   //---------------------------------------------------------------
   // Détecte un SWEEP (chasse de liquidité) sur la bougie à "shift" :
   // sa mèche dépasse le dernier swing high/low connu, mais sa
   // clôture revient à l'intérieur. Retourne le côté balayé
   // ("Support", "Resistance" ou "Aucun").
   //---------------------------------------------------------------
   string            DetectSweep(const int shift = 1) const
     {
      if(!m_initialized)
         return("Aucun");

      double high  = iHigh(m_symbol, m_timeframe, shift);
      double low   = iLow(m_symbol, m_timeframe, shift);
      double close = iClose(m_symbol, m_timeframe, shift);

      if(m_lastSwingHighPrice > 0.0 && high > m_lastSwingHighPrice && close < m_lastSwingHighPrice)
         return("Resistance"); // Mèche au-dessus d'un plus haut connu, clôture revenue en dessous

      if(m_lastSwingLowPrice > 0.0 && low < m_lastSwingLowPrice && close > m_lastSwingLowPrice)
         return("Support"); // Mèche sous un plus bas connu, clôture revenue au-dessus

      return("Aucun");
     }
  };

#endif // MARKETSTRUCTURE_MQH
//+------------------------------------------------------------------+
