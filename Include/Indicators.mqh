//+------------------------------------------------------------------+
//|                                                 Indicators.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Encapsule tous les indicateurs techniques utilisés |
//|   par le robot dans une classe unique CIndicators.                |
//|                                                                    |
//|   Une instance = un couple (symbole, timeframe). L'EA étant       |
//|   multi-timeframe (M15/H1/H4) et multi-actifs, on crée typiquement|
//|   plusieurs instances (une par timeframe analysé).                |
//|                                                                    |
//|   Volontairement DÉCOUPLÉE de Config.mqh : les périodes sont      |
//|   passées en paramètres à Init(), pas lues directement depuis les |
//|   inputs. Cela permet de réutiliser la classe dans n'importe quel |
//|   contexte (tests unitaires, autre EA, futur moteur IA...).       |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef INDICATORS_MQH
#define INDICATORS_MQH

#include "Types.mqh"

// Index utilisés pour le tableau interne des handles EMA
#define EMA_INDEX_FAST   0  // EMA rapide (ex: 20)
#define EMA_INDEX_MEDIUM 1  // EMA médiane (ex: 50)
#define EMA_INDEX_SLOW   2  // EMA lente (ex: 100)
#define EMA_INDEX_TREND  3  // EMA de tendance long terme (ex: 200)

//+------------------------------------------------------------------+
//| Classe CIndicators                                                   |
//+------------------------------------------------------------------+
class CIndicators
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   bool              m_initialized;

   int               m_handleEMA[4];
   int               m_handleRSI;
   int               m_handleATR;
   int               m_handleADX;
   int               m_handleBB;
   int               m_handleFractals;

   //---------------------------------------------------------------
   // Lit une seule valeur d'un buffer d'indicateur, avec gestion
   // d'erreur systématique. Retourne EMPTY_VALUE en cas d'échec afin
   // que l'appelant puisse détecter une donnée indisponible sans
   // planter (ex : historique pas encore chargé).
   //---------------------------------------------------------------
   double            ReadSingleBufferValue(const int handle, const int bufferIndex, const int shift) const
     {
      if(handle == INVALID_HANDLE)
         return(EMPTY_VALUE);

      double buffer[];
      ArraySetAsSeries(buffer, true);
      int copied = CopyBuffer(handle, bufferIndex, shift, 1, buffer);
      if(copied <= 0)
         return(EMPTY_VALUE);

      return(buffer[0]);
     }

public:
                     CIndicators()
     {
      m_symbol      = "";
      m_timeframe   = PERIOD_CURRENT;
      m_initialized = false;

      for(int i = 0; i < 4; i++)
         m_handleEMA[i] = INVALID_HANDLE;

      m_handleRSI      = INVALID_HANDLE;
      m_handleATR      = INVALID_HANDLE;
      m_handleADX      = INVALID_HANDLE;
      m_handleBB       = INVALID_HANDLE;
      m_handleFractals = INVALID_HANDLE;
     }

                    ~CIndicators()
     {
      Deinit();
     }

   //---------------------------------------------------------------
   // Crée tous les handles d'indicateurs pour le symbole/timeframe
   // donné. Doit être appelé une seule fois (dans OnInit du module
   // appelant). Retourne false si un seul handle échoue.
   //---------------------------------------------------------------
   bool              Init(const string symbol, const ENUM_TIMEFRAMES timeframe,
                          const int emaFastPeriod, const int emaMediumPeriod,
                          const int emaSlowPeriod, const int emaTrendPeriod,
                          const int rsiPeriod, const int atrPeriod, const int adxPeriod,
                          const int bbPeriod, const double bbDeviation)
     {
      m_symbol    = symbol;
      m_timeframe = timeframe;

      m_handleEMA[EMA_INDEX_FAST]   = iMA(symbol, timeframe, emaFastPeriod,   0, MODE_EMA, PRICE_CLOSE);
      m_handleEMA[EMA_INDEX_MEDIUM] = iMA(symbol, timeframe, emaMediumPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_handleEMA[EMA_INDEX_SLOW]   = iMA(symbol, timeframe, emaSlowPeriod,   0, MODE_EMA, PRICE_CLOSE);
      m_handleEMA[EMA_INDEX_TREND]  = iMA(symbol, timeframe, emaTrendPeriod, 0, MODE_EMA, PRICE_CLOSE);

      m_handleRSI      = iRSI(symbol, timeframe, rsiPeriod, PRICE_CLOSE);
      m_handleATR      = iATR(symbol, timeframe, atrPeriod);
      m_handleADX      = iADX(symbol, timeframe, adxPeriod);
      m_handleBB       = iBands(symbol, timeframe, bbPeriod, 0, bbDeviation, PRICE_CLOSE);
      m_handleFractals = iFractals(symbol, timeframe);

      bool allValid = true;
      for(int i = 0; i < 4; i++)
        {
         if(m_handleEMA[i] == INVALID_HANDLE)
            allValid = false;
        }
      if(m_handleRSI == INVALID_HANDLE || m_handleATR == INVALID_HANDLE ||
         m_handleADX == INVALID_HANDLE || m_handleBB == INVALID_HANDLE ||
         m_handleFractals == INVALID_HANDLE)
         allValid = false;

      if(!allValid)
        {
         PrintFormat("CIndicators::Init - échec création d'un ou plusieurs handles pour %s %s (code %d)",
                     symbol, EnumToString(timeframe), GetLastError());
         return(false);
        }

      m_initialized = true;
      return(true);
     }

   //---------------------------------------------------------------
   // Libère tous les handles d'indicateurs (à appeler dans OnDeinit).
   //---------------------------------------------------------------
   void              Deinit()
     {
      for(int i = 0; i < 4; i++)
        {
         if(m_handleEMA[i] != INVALID_HANDLE)
           {
            IndicatorRelease(m_handleEMA[i]);
            m_handleEMA[i] = INVALID_HANDLE;
           }
        }
      if(m_handleRSI != INVALID_HANDLE)      { IndicatorRelease(m_handleRSI);      m_handleRSI = INVALID_HANDLE; }
      if(m_handleATR != INVALID_HANDLE)      { IndicatorRelease(m_handleATR);      m_handleATR = INVALID_HANDLE; }
      if(m_handleADX != INVALID_HANDLE)      { IndicatorRelease(m_handleADX);      m_handleADX = INVALID_HANDLE; }
      if(m_handleBB  != INVALID_HANDLE)      { IndicatorRelease(m_handleBB);       m_handleBB  = INVALID_HANDLE; }
      if(m_handleFractals != INVALID_HANDLE) { IndicatorRelease(m_handleFractals); m_handleFractals = INVALID_HANDLE; }

      m_initialized = false;
     }

   bool              IsInitialized() const { return(m_initialized); }
   string            GetSymbol()     const { return(m_symbol); }
   ENUM_TIMEFRAMES   GetTimeframe()  const { return(m_timeframe); }

   //---------------------------------------------------------------
   // EMA - index : EMA_INDEX_FAST / EMA_INDEX_MEDIUM / EMA_INDEX_SLOW / EMA_INDEX_TREND
   //---------------------------------------------------------------
   double            GetEMA(const int emaIndex, const int shift = 0) const
     {
      if(emaIndex < 0 || emaIndex > 3)
         return(EMPTY_VALUE);
      return(ReadSingleBufferValue(m_handleEMA[emaIndex], 0, shift));
     }

   //---------------------------------------------------------------
   // RSI
   //---------------------------------------------------------------
   double            GetRSI(const int shift = 0) const
     {
      return(ReadSingleBufferValue(m_handleRSI, 0, shift));
     }

   //---------------------------------------------------------------
   // ATR
   //---------------------------------------------------------------
   double            GetATR(const int shift = 0) const
     {
      return(ReadSingleBufferValue(m_handleATR, 0, shift));
     }

   //---------------------------------------------------------------
   // ADX - ligne principale + DI+ / DI-
   //---------------------------------------------------------------
   double            GetADXMain(const int shift = 0) const
     {
      return(ReadSingleBufferValue(m_handleADX, 0, shift));
     }

   double            GetADXPlusDI(const int shift = 0) const
     {
      return(ReadSingleBufferValue(m_handleADX, 1, shift));
     }

   double            GetADXMinusDI(const int shift = 0) const
     {
      return(ReadSingleBufferValue(m_handleADX, 2, shift));
     }

   //---------------------------------------------------------------
   // Bollinger Bands - base / haut / bas
   //---------------------------------------------------------------
   double            GetBBMiddle(const int shift = 0) const
     {
      return(ReadSingleBufferValue(m_handleBB, 0, shift));
     }

   double            GetBBUpper(const int shift = 0) const
     {
      return(ReadSingleBufferValue(m_handleBB, 1, shift));
     }

   double            GetBBLower(const int shift = 0) const
     {
      return(ReadSingleBufferValue(m_handleBB, 2, shift));
     }

   //---------------------------------------------------------------
   // Fractals - retourne le prix du fractal, ou EMPTY_VALUE si aucun
   // fractal à ce shift. IMPORTANT : un fractal n'est confirmé que
   // 2 bougies après sa formation (limitation native de l'indicateur
   // MQL5) ; l'appelant (CSupportResistance, CPatterns) doit en
   // tenir compte et ne jamais lire les fractals des shifts 0 et 1.
   //---------------------------------------------------------------
   double            GetFractalUp(const int shift) const
     {
      return(ReadSingleBufferValue(m_handleFractals, 0, shift));
     }

   double            GetFractalDown(const int shift) const
     {
      return(ReadSingleBufferValue(m_handleFractals, 1, shift));
     }

   //---------------------------------------------------------------
   // Volume (tick volume, MT5 ne fournissant pas le volume réel pour
   // la majorité des CFD/Forex chez les brokers dont Exness).
   //---------------------------------------------------------------
   long              GetTickVolume(const int shift = 0) const
     {
      long volumeBuffer[];
      ArraySetAsSeries(volumeBuffer, true);
      int copied = CopyTickVolume(m_symbol, m_timeframe, shift, 1, volumeBuffer);
      if(copied <= 0)
         return(0);
      return(volumeBuffer[0]);
     }

   //---------------------------------------------------------------
   // VWAP (Volume Weighted Average Price), recalculé depuis le début
   // de la journée de trading (minuit heure serveur). MQL5 ne fournit
   // pas de VWAP natif : ce calcul est fait "à la main" à partir des
   // bougies du timeframe de l'instance.
   // NOTE PERFORMANCE : à n'appeler qu'une fois par nouvelle bougie
   // (jamais à chaque tick), le coût de CopyRates() étant non nul.
   //---------------------------------------------------------------
   double            GetVWAP(const int shift = 0) const
     {
      datetime referenceTime = iTime(m_symbol, m_timeframe, shift);
      if(referenceTime == 0)
         return(EMPTY_VALUE);

      MqlDateTime dt;
      TimeToStruct(referenceTime, dt);
      dt.hour = 0;
      dt.min  = 0;
      dt.sec  = 0;
      datetime dayStart = StructToTime(dt);

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      // start_time doit être antérieur à stop_time (ordre chronologique)
      int copied = CopyRates(m_symbol, m_timeframe, dayStart, referenceTime, rates);
      if(copied <= 0)
         return(EMPTY_VALUE);

      double sumPriceVolume = 0.0;
      double sumVolume      = 0.0;

      for(int i = 0; i < copied; i++)
        {
         double typicalPrice = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
         double vol = (double)rates[i].tick_volume;
         sumPriceVolume += typicalPrice * vol;
         sumVolume      += vol;
        }

      if(sumVolume <= 0.0)
         return(EMPTY_VALUE);

      return(sumPriceVolume / sumVolume);
     }
  };

#endif // INDICATORS_MQH
//+------------------------------------------------------------------+
