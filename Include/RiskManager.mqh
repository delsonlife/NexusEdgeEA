//+------------------------------------------------------------------+
//|                                                RiskManager.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Calcul du risque : lot, Stop Loss, Take Profit,    |
//|   Risk/Reward. Utilise directement les valeurs officielles du     |
//|   broker (tick value, tick size, volume min/max/step) via         |
//|   SymbolInfoDouble - donc compatible nativement avec les comptes  |
//|   Cent Exness sans code spécifique, MT5 retournant déjà ces       |
//|   valeurs dans la devise réelle du compte.                        |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef RISKMANAGER_MQH
#define RISKMANAGER_MQH

#include "Types.mqh"
#include "Utilities.mqh"
#include "Indicators.mqh"
#include "SupportResistance.mqh"

//+------------------------------------------------------------------+
//| Classe CRiskManager                                                  |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   CIndicators         *m_indicators;        // Référence non propriétaire
   CSupportResistance  *m_supportResistance; // Référence non propriétaire

   string               m_symbol;
   ENUM_TIMEFRAMES      m_timeframe;
   bool                 m_initialized;

   ENUM_SL_METHOD       m_slMethod;
   double               m_slAtrMultiplier;
   ENUM_TP_METHOD       m_tpMethod;
   double               m_tpRRRatio;
   double               m_tpAtrMultiplier;
   int                  m_swingLookbackBars;
   double               m_zoneBufferPoints; // Marge de sécurité au-delà d'une zone S/R pour le SL/TP

   //---------------------------------------------------------------
   // Plus bas brut sur les N dernières bougies (swing low simple,
   // sans fusion en zone - utilisé pour SL_METHOD_LAST_SWING).
   //---------------------------------------------------------------
   double            GetRawSwingLow(const int shift) const
     {
      int idx = iLowest(m_symbol, m_timeframe, MODE_LOW, m_swingLookbackBars, shift);
      if(idx < 0)
         return(0.0);
      return(iLow(m_symbol, m_timeframe, idx));
     }

   //---------------------------------------------------------------
   // Plus haut brut sur les N dernières bougies (swing high simple).
   //---------------------------------------------------------------
   double            GetRawSwingHigh(const int shift) const
     {
      int idx = iHighest(m_symbol, m_timeframe, MODE_HIGH, m_swingLookbackBars, shift);
      if(idx < 0)
         return(0.0);
      return(iHigh(m_symbol, m_timeframe, idx));
     }

public:
                     CRiskManager()
     {
      m_indicators         = NULL;
      m_supportResistance  = NULL;
      m_symbol             = "";
      m_timeframe          = PERIOD_CURRENT;
      m_initialized        = false;
      m_slMethod           = SL_METHOD_ATR;
      m_slAtrMultiplier    = 1.5;
      m_tpMethod           = TP_METHOD_RR;
      m_tpRRRatio          = 2.0;
      m_tpAtrMultiplier    = 3.0;
      m_swingLookbackBars  = 20;
      m_zoneBufferPoints   = 50.0;
     }

   //---------------------------------------------------------------
   // Initialise le module. Ne prend possession d'aucune référence
   // fournie (pas de destruction ici).
   //---------------------------------------------------------------
   bool              Init(CIndicators *indicators, CSupportResistance *supportResistance,
                          const string symbol, const ENUM_TIMEFRAMES timeframe,
                          const ENUM_SL_METHOD slMethod, const double slAtrMultiplier,
                          const ENUM_TP_METHOD tpMethod, const double tpRRRatio, const double tpAtrMultiplier,
                          const int swingLookbackBars = 20, const double zoneBufferPoints = 50.0)
     {
      if(indicators == NULL || supportResistance == NULL)
        {
         Print("CRiskManager::Init - CIndicators ou CSupportResistance invalide (NULL)");
         return(false);
        }

      m_indicators         = indicators;
      m_supportResistance  = supportResistance;
      m_symbol             = symbol;
      m_timeframe          = timeframe;
      m_slMethod           = slMethod;
      m_slAtrMultiplier    = slAtrMultiplier;
      m_tpMethod           = tpMethod;
      m_tpRRRatio          = tpRRRatio;
      m_tpAtrMultiplier    = tpAtrMultiplier;
      m_swingLookbackBars  = swingLookbackBars;
      m_zoneBufferPoints   = zoneBufferPoints;
      m_initialized        = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Calcule le prix du Stop Loss selon la méthode configurée.
   // Retourne 0.0 en cas d'échec (aucune donnée disponible).
   //---------------------------------------------------------------
   double            CalculateStopLoss(const ENUM_SIGNAL_TYPE signalType, const double entryPrice, const int shift = 1) const
     {
      if(!m_initialized || signalType == SIGNAL_NONE)
         return(0.0);

      double buffer = CUtilities::PointsToPrice(m_symbol, m_zoneBufferPoints);
      double slPrice = 0.0;

      switch(m_slMethod)
        {
         case SL_METHOD_ATR:
           {
            double atr = m_indicators.GetATR(shift);
            if(atr == EMPTY_VALUE || atr <= 0.0)
               return(0.0);
            double distance = atr * m_slAtrMultiplier;
            slPrice = (signalType == SIGNAL_BUY) ? (entryPrice - distance) : (entryPrice + distance);
            break;
           }

         case SL_METHOD_SUPPORT_RESIST:
           {
            if(signalType == SIGNAL_BUY)
              {
               double support = m_supportResistance.GetNearestSupport(entryPrice);
               if(support <= 0.0)
                  return(0.0);
               slPrice = support - buffer;
              }
            else
              {
               double resistance = m_supportResistance.GetNearestResistance(entryPrice);
               if(resistance <= 0.0)
                  return(0.0);
               slPrice = resistance + buffer;
              }
            break;
           }

         case SL_METHOD_LAST_SWING:
           {
            if(signalType == SIGNAL_BUY)
              {
               double swingLow = GetRawSwingLow(shift);
               if(swingLow <= 0.0)
                  return(0.0);
               slPrice = swingLow - buffer;
              }
            else
              {
               double swingHigh = GetRawSwingHigh(shift);
               if(swingHigh <= 0.0)
                  return(0.0);
               slPrice = swingHigh + buffer;
              }
            break;
           }

         default:
            return(0.0);
        }

      return(CUtilities::NormalizePriceToTick(m_symbol, slPrice));
     }

   //---------------------------------------------------------------
   // Calcule le prix du Take Profit selon la méthode configurée.
   // Nécessite le SL déjà calculé pour la méthode TP_METHOD_RR.
   //---------------------------------------------------------------
   double            CalculateTakeProfit(const ENUM_SIGNAL_TYPE signalType, const double entryPrice,
                                         const double slPrice, const int shift = 1) const
     {
      if(!m_initialized || signalType == SIGNAL_NONE)
         return(0.0);

      double buffer = CUtilities::PointsToPrice(m_symbol, m_zoneBufferPoints);
      double tpPrice = 0.0;

      switch(m_tpMethod)
        {
         case TP_METHOD_RR:
           {
            if(slPrice <= 0.0)
               return(0.0);
            double slDistance = MathAbs(entryPrice - slPrice);
            double tpDistance = slDistance * m_tpRRRatio;
            tpPrice = (signalType == SIGNAL_BUY) ? (entryPrice + tpDistance) : (entryPrice - tpDistance);
            break;
           }

         case TP_METHOD_ATR:
           {
            double atr = m_indicators.GetATR(shift);
            if(atr == EMPTY_VALUE || atr <= 0.0)
               return(0.0);
            double distance = atr * m_tpAtrMultiplier;
            tpPrice = (signalType == SIGNAL_BUY) ? (entryPrice + distance) : (entryPrice - distance);
            break;
           }

         case TP_METHOD_SUPPORT_RESIST:
           {
            if(signalType == SIGNAL_BUY)
              {
               double resistance = m_supportResistance.GetNearestResistance(entryPrice);
               if(resistance <= 0.0)
                  return(0.0);
               tpPrice = resistance - buffer;
              }
            else
              {
               double support = m_supportResistance.GetNearestSupport(entryPrice);
               if(support <= 0.0)
                  return(0.0);
               tpPrice = support + buffer;
              }
            break;
           }

         default:
            return(0.0);
        }

      return(CUtilities::NormalizePriceToTick(m_symbol, tpPrice));
     }

   //---------------------------------------------------------------
   // Calcule le lot en fonction du risque en % du capital et de la
   // distance du SL, en respectant tick value/tick size/volume min-
   // max-step du broker. Retourne 0.0 si le calcul échoue (l'appelant
   // - CValidator - doit alors refuser le trade).
   //---------------------------------------------------------------
   double            CalculateLotSize(const double riskPercent, const double entryPrice, const double slPrice) const
     {
      if(!m_initialized || slPrice <= 0.0 || entryPrice <= 0.0)
         return(0.0);

      double slDistance = MathAbs(entryPrice - slPrice);
      if(slDistance <= 0.0)
         return(0.0);

      double tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue <= 0.0 || tickSize <= 0.0)
        {
         Print("CRiskManager::CalculateLotSize - tickValue/tickSize invalide pour ", m_symbol);
         return(0.0);
        }

      double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = accountBalance * (riskPercent / 100.0);

      double ticksInDistance = slDistance / tickSize;
      double valuePerLot = ticksInDistance * tickValue;
      if(valuePerLot <= 0.0)
         return(0.0);

      double rawLot = riskAmount / valuePerLot;

      double volMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double volMax  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double volStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);

      double normalizedLot = rawLot;
      if(volStep > 0.0)
         normalizedLot = MathFloor(rawLot / volStep) * volStep; // Arrondi vers le bas : ne jamais dépasser le risque voulu

      normalizedLot = CUtilities::Clamp(normalizedLot, volMin, volMax);

      // Sécurité : si l'arrondi vers le bas tombe à 0 mais que le
      // minimum broker est atteignable, on force le volume minimum
      // (mieux vaut un risque légèrement supérieur qu'un lot nul).
      if(normalizedLot <= 0.0 && volMin > 0.0)
         normalizedLot = volMin;

      return(normalizedLot);
     }

   //---------------------------------------------------------------
   // Calcule le ratio Risk/Reward réel entre l'entrée, le SL et le TP.
   //---------------------------------------------------------------
   double            CalculateRR(const double entryPrice, const double slPrice, const double tpPrice) const
     {
      double riskDistance   = MathAbs(entryPrice - slPrice);
      double rewardDistance = MathAbs(tpPrice - entryPrice);
      return(CUtilities::SafeDivide(rewardDistance, riskDistance, 0.0));
     }

   //---------------------------------------------------------------
   // Construit une struct SRiskParams complète, pour transmission à
   // CLogger/CDashboard sans recalculer les mêmes valeurs ailleurs.
   //---------------------------------------------------------------
   SRiskParams       BuildRiskParams(const double riskPercent, const double slPrice) const
     {
      SRiskParams p;
      p.riskPercent      = riskPercent;
      p.slDistancePoints = CUtilities::PriceToPoints(m_symbol, MathAbs(SymbolInfoDouble(m_symbol, SYMBOL_BID) - slPrice));
      p.tickValue        = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      p.tickSize         = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      p.volumeMin        = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      p.volumeMax        = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      p.volumeStep       = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      return(p);
     }
  };

#endif // RISKMANAGER_MQH
//+------------------------------------------------------------------+
