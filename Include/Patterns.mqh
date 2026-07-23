//+------------------------------------------------------------------+
//|                                                   Patterns.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Détection des figures de bougies japonaises.       |
//|   CPatterns analyse la géométrie pure des bougies (corps, mèches,|
//|   ratios) SANS connaître les zones de support/résistance : la     |
//|   confluence pattern + zone est la responsabilité de              |
//|   CSignalManager, pas de ce module (principe de responsabilité    |
//|   unique validé avec l'utilisateur).                               |
//|                                                                    |
//|   Patterns couverts : Pin Bar, Engulfing, Inside Bar, Outside Bar,|
//|   Doji, Morning Star, Evening Star, Marubozu, Hammer, Shooting    |
//|   Star.                                                            |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef PATTERNS_MQH
#define PATTERNS_MQH

#include "Types.mqh"

//+------------------------------------------------------------------+
//| Classe CPatterns                                                     |
//+------------------------------------------------------------------+
class CPatterns
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   bool              m_initialized;

   //---------------------------------------------------------------
   // Structure interne légère pour manipuler une bougie sans
   // multiplier les appels iOpen/iHigh/iLow/iClose partout.
   //---------------------------------------------------------------
   struct SCandle
     {
      double  open;
      double  high;
      double  low;
      double  close;
      double  bodySize;
      double  upperWick;
      double  lowerWick;
      double  range;
      bool    bullish;
     };

   SCandle           LoadCandle(const int shift) const
     {
      SCandle c;
      c.open  = iOpen(m_symbol, m_timeframe, shift);
      c.high  = iHigh(m_symbol, m_timeframe, shift);
      c.low   = iLow(m_symbol, m_timeframe, shift);
      c.close = iClose(m_symbol, m_timeframe, shift);
      c.range = c.high - c.low;
      c.bodySize = MathAbs(c.close - c.open);
      c.bullish = (c.close >= c.open);
      c.upperWick = c.high - MathMax(c.open, c.close);
      c.lowerWick = MathMin(c.open, c.close) - c.low;
      return(c);
     }

   //---------------------------------------------------------------
   // Construit un résultat vide (aucun pattern détecté).
   //---------------------------------------------------------------
   SPatternResult    EmptyResult(const int shift) const
     {
      SPatternResult r;
      r.pattern     = PATTERN_NONE;
      r.bullish     = false;
      r.strength    = 0.0;
      r.description = "Aucun pattern détecté";
      r.time        = iTime(m_symbol, m_timeframe, shift);
      return(r);
     }

   //---------------------------------------------------------------
   // Doji : corps quasi inexistant par rapport au range total.
   //---------------------------------------------------------------
   bool              IsDoji(const SCandle &c) const
     {
      if(c.range <= 0.0)
         return(false);
      return((c.bodySize / c.range) < 0.10);
     }

   //---------------------------------------------------------------
   // Marubozu : corps occupe presque tout le range, mèches minimes.
   //---------------------------------------------------------------
   bool              IsMarubozu(const SCandle &c) const
     {
      if(c.range <= 0.0)
         return(false);
      return((c.bodySize / c.range) > 0.90);
     }

   //---------------------------------------------------------------
   // Pin Bar / Hammer (biais haussier) : petit corps proche du haut
   // du range, longue mèche basse (>= 2x le corps), mèche haute courte.
   //---------------------------------------------------------------
   bool              IsBullishPinBar(const SCandle &c) const
     {
      if(c.range <= 0.0 || c.bodySize <= 0.0)
         return(false);
      bool smallBody     = (c.bodySize / c.range) < 0.35;
      bool longLowerWick = c.lowerWick >= (c.bodySize * 2.0);
      bool shortUpperWick = c.upperWick <= (c.bodySize * 0.6);
      return(smallBody && longLowerWick && shortUpperWick);
     }

   //---------------------------------------------------------------
   // Pin Bar / Shooting Star (biais baissier) : petit corps proche du
   // bas du range, longue mèche haute, mèche basse courte.
   //---------------------------------------------------------------
   bool              IsBearishPinBar(const SCandle &c) const
     {
      if(c.range <= 0.0 || c.bodySize <= 0.0)
         return(false);
      bool smallBody      = (c.bodySize / c.range) < 0.35;
      bool longUpperWick  = c.upperWick >= (c.bodySize * 2.0);
      bool shortLowerWick = c.lowerWick <= (c.bodySize * 0.6);
      return(smallBody && longUpperWick && shortLowerWick);
     }

   //---------------------------------------------------------------
   // Engulfing haussier : bougie baissière suivie d'une bougie
   // haussière dont le corps englobe entièrement le corps précédent.
   //---------------------------------------------------------------
   bool              IsBullishEngulfing(const SCandle &prev, const SCandle &cur) const
     {
      if(prev.bullish || !cur.bullish)
         return(false);
      return(cur.open <= prev.close && cur.close >= prev.open);
     }

   //---------------------------------------------------------------
   // Engulfing baissier : bougie haussière suivie d'une bougie
   // baissière dont le corps englobe entièrement le corps précédent.
   //---------------------------------------------------------------
   bool              IsBearishEngulfing(const SCandle &prev, const SCandle &cur) const
     {
      if(!prev.bullish || cur.bullish)
         return(false);
      return(cur.open >= prev.close && cur.close <= prev.open);
     }

   //---------------------------------------------------------------
   // Inside Bar : range de la bougie courante entièrement contenu
   // dans le range de la bougie précédente.
   //---------------------------------------------------------------
   bool              IsInsideBar(const SCandle &prev, const SCandle &cur) const
     {
      return(cur.high <= prev.high && cur.low >= prev.low);
     }

   //---------------------------------------------------------------
   // Outside Bar : range de la bougie courante englobe entièrement
   // le range de la bougie précédente.
   //---------------------------------------------------------------
   bool              IsOutsideBar(const SCandle &prev, const SCandle &cur) const
     {
      return(cur.high >= prev.high && cur.low <= prev.low);
     }

   //---------------------------------------------------------------
   // Morning Star (3 bougies, biais haussier) : grande baissière,
   // petite bougie d'indécision (gap ou quasi-doji), grande haussière
   // qui referme bien au-dessus du milieu de la 1ère bougie.
   //---------------------------------------------------------------
   bool              IsMorningStar(const SCandle &c2, const SCandle &c1, const SCandle &c0) const
     {
      bool firstBearishStrong = (!c2.bullish) && (c2.range > 0.0) && (c2.bodySize / c2.range > 0.55);
      bool secondSmall        = (c1.range > 0.0) && (c1.bodySize / c1.range < 0.40);
      bool thirdBullishStrong = (c0.bullish) && (c0.range > 0.0) && (c0.bodySize / c0.range > 0.55);
      if(!firstBearishStrong || !secondSmall || !thirdBullishStrong)
         return(false);

      double midFirstBody = (c2.open + c2.close) / 2.0;
      return(c0.close > midFirstBody);
     }

   //---------------------------------------------------------------
   // Evening Star (3 bougies, biais baissier) : symétrique du Morning
   // Star.
   //---------------------------------------------------------------
   bool              IsEveningStar(const SCandle &c2, const SCandle &c1, const SCandle &c0) const
     {
      bool firstBullishStrong = (c2.bullish) && (c2.range > 0.0) && (c2.bodySize / c2.range > 0.55);
      bool secondSmall        = (c1.range > 0.0) && (c1.bodySize / c1.range < 0.40);
      bool thirdBearishStrong = (!c0.bullish) && (c0.range > 0.0) && (c0.bodySize / c0.range > 0.55);
      if(!firstBullishStrong || !secondSmall || !thirdBearishStrong)
         return(false);

      double midFirstBody = (c2.open + c2.close) / 2.0;
      return(c0.close < midFirstBody);
     }

public:
                     CPatterns()
     {
      m_symbol      = "";
      m_timeframe   = PERIOD_CURRENT;
      m_initialized = false;
     }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES timeframe)
     {
      m_symbol      = symbol;
      m_timeframe   = timeframe;
      m_initialized = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Analyse la bougie au shift donné (par défaut shift=1, c'est-à-
   // dire la dernière bougie CLÔTURÉE au moment de l'ouverture d'une
   // nouvelle bougie - ne jamais analyser shift=0 qui est en cours de
   // formation) et retourne le pattern le plus significatif détecté.
   // Priorité : patterns 3 bougies > Engulfing > Pin Bar/Hammer/
   // Shooting Star > Marubozu > Inside/Outside Bar > Doji.
   //---------------------------------------------------------------
   SPatternResult    DetectPattern(const int shift = 1)
     {
      if(!m_initialized)
         return(EmptyResult(shift));

      SCandle c0 = LoadCandle(shift);       // Bougie analysée
      SCandle c1 = LoadCandle(shift + 1);   // Bougie précédente
      SCandle c2 = LoadCandle(shift + 2);   // Bougie encore avant (pour patterns 3 bougies)

      if(c0.range <= 0.0)
         return(EmptyResult(shift));

      SPatternResult result = EmptyResult(shift);

      // --- Patterns 3 bougies (priorité la plus haute) ---
      if(IsMorningStar(c2, c1, c0))
        {
         result.pattern     = PATTERN_MORNING_STAR;
         result.bullish     = true;
         result.strength    = 85.0;
         result.description = "Morning Star (retournement haussier)";
         return(result);
        }
      if(IsEveningStar(c2, c1, c0))
        {
         result.pattern     = PATTERN_EVENING_STAR;
         result.bullish     = false;
         result.strength    = 85.0;
         result.description = "Evening Star (retournement baissier)";
         return(result);
        }

      // --- Engulfing ---
      if(IsBullishEngulfing(c1, c0))
        {
         result.pattern     = PATTERN_ENGULFING_BULLISH;
         result.bullish     = true;
         result.strength    = 75.0;
         result.description = "Engulfing haussier";
         return(result);
        }
      if(IsBearishEngulfing(c1, c0))
        {
         result.pattern     = PATTERN_ENGULFING_BEARISH;
         result.bullish     = false;
         result.strength    = 75.0;
         result.description = "Engulfing baissier";
         return(result);
        }

      // --- Pin Bar / Hammer / Shooting Star ---
      if(IsBullishPinBar(c0))
        {
         result.pattern     = PATTERN_HAMMER;
         result.bullish     = true;
         result.strength    = 70.0;
         result.description = "Pin Bar / Hammer haussier";
         return(result);
        }
      if(IsBearishPinBar(c0))
        {
         result.pattern     = PATTERN_SHOOTING_STAR;
         result.bullish     = false;
         result.strength    = 70.0;
         result.description = "Pin Bar / Shooting Star baissier";
         return(result);
        }

      // --- Marubozu ---
      if(IsMarubozu(c0))
        {
         result.pattern     = c0.bullish ? PATTERN_MARUBOZU_BULLISH : PATTERN_MARUBOZU_BEARISH;
         result.bullish     = c0.bullish;
         result.strength    = 60.0;
         result.description = c0.bullish ? "Marubozu haussier" : "Marubozu baissier";
         return(result);
        }

      // --- Outside Bar / Inside Bar ---
      if(IsOutsideBar(c1, c0))
        {
         result.pattern     = PATTERN_OUTSIDE_BAR;
         result.bullish     = c0.bullish;
         result.strength    = 45.0;
         result.description = "Outside Bar";
         return(result);
        }
      if(IsInsideBar(c1, c0))
        {
         result.pattern     = PATTERN_INSIDE_BAR;
         result.bullish     = c0.bullish;
         result.strength    = 35.0;
         result.description = "Inside Bar (compression)";
         return(result);
        }

      // --- Doji (priorité la plus basse : signal d'indécision) ---
      if(IsDoji(c0))
        {
         result.pattern     = PATTERN_DOJI;
         result.bullish     = c0.bullish;
         result.strength    = 25.0;
         result.description = "Doji (indécision)";
         return(result);
        }

      return(result); // PATTERN_NONE
     }
  };

#endif // PATTERNS_MQH
//+------------------------------------------------------------------+
