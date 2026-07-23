//+------------------------------------------------------------------+
//|                                              MarketContext.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Moteur central de contexte marché.                  |
//|   CMarketContext détermine, à chaque nouvelle bougie, un          |
//|   instantané complet (SMarketContext) : tendance, volatilité,     |
//|   momentum, force du marché, compression, liquidité et phase     |
//|   Wyckoff estimée.                                                 |
//|                                                                    |
//|   TOUS les autres modules (SignalManager, RiskManager, Filters,  |
//|   Validator, Dashboard...) consomment CE contexte en LECTURE      |
//|   SEULE plutôt que de recalculer leur propre vision du marché —   |
//|   garantissant une vision cohérente et centralisée.                |
//|                                                                    |
//|   CORRECTIF (2026-07-09) : Update() utilise désormais un shift    |
//|   cohérent (1 par défaut = dernière bougie CLÔTURÉE), au lieu du  |
//|   shift 0 (bougie en cours de formation) utilisé partout avant.   |
//|   Le bug était particulièrement visible sur le volume tick : à    |
//|   l'instant où une nouvelle bougie s'ouvre, son volume est quasi  |
//|   nul, donnant un score de liquidité systématiquement proche de 0 |
//|   comparé à la moyenne de bougies pleinement formées. EMA/RSI/ATR |
//|   étaient moins affectés (leur valeur change peu entre l'ouverture|
//|   et la clôture d'une bougie) mais souffraient de la même          |
//|   incohérence de principe.                                         |
//|                                                                    |
//|   AVERTISSEMENT : la détection de phase Wyckoff est une           |
//|   heuristique "best effort" (combinaison tendance/volatilité/     |
//|   volume/position du prix). Ce n'est pas une classification       |
//|   Wyckoff académique rigoureuse — à utiliser comme indication      |
//|   contextuelle supplémentaire, pas comme vérité absolue.           |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef MARKETCONTEXT_MQH
#define MARKETCONTEXT_MQH

#include "Types.mqh"
#include "Utilities.mqh"
#include "Indicators.mqh"

//+------------------------------------------------------------------+
//| Classe CMarketContext                                               |
//+------------------------------------------------------------------+
class CMarketContext
  {
private:
   CIndicators      *m_indicators;   // Référence vers les indicateurs du timeframe analysé (non propriétaire)
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   bool              m_initialized;

   // Seuils configurables (passés à Init, pas lus depuis Config.mqh
   // pour garder la classe découplée et réutilisable)
   double            m_adxTrendThreshold;  // Au-dessus : tendance jugée valide
   double            m_adxRangeThreshold;  // En-dessous : range jugé valide
   double            m_atrMinPoints;       // Volatilité minimale acceptable (points)
   double            m_atrMaxPoints;       // Volatilité maximale acceptable (points)
   int               m_lookbackBars;       // Profondeur d'historique pour moyennes (volume, BB width...)

   SMarketContext    m_context;            // Dernier instantané calculé

   //---------------------------------------------------------------
   // Détermine la tendance en croisant l'alignement des 4 EMA, la
   // position du prix par rapport à l'EMA rapide, et la force ADX.
   // shift : bougie analysée (1 = dernière clôturée).
   //---------------------------------------------------------------
   ENUM_TREND_STATE  DetermineTrend(const int shift) const
     {
      double emaFast   = m_indicators.GetEMA(EMA_INDEX_FAST, shift);
      double emaMedium = m_indicators.GetEMA(EMA_INDEX_MEDIUM, shift);
      double emaSlow    = m_indicators.GetEMA(EMA_INDEX_SLOW, shift);
      double emaTrend  = m_indicators.GetEMA(EMA_INDEX_TREND, shift);
      double adxMain   = m_indicators.GetADXMain(shift);
      double closePrice = iClose(m_symbol, m_timeframe, shift);

      if(emaFast == EMPTY_VALUE || emaMedium == EMPTY_VALUE || emaSlow == EMPTY_VALUE ||
         emaTrend == EMPTY_VALUE || adxMain == EMPTY_VALUE)
         return(TREND_RANGE); // Données indisponibles : posture prudente

      bool bullishAlignment = (emaFast > emaMedium && emaMedium > emaSlow && emaSlow > emaTrend && closePrice > emaFast);
      bool bearishAlignment = (emaFast < emaMedium && emaMedium < emaSlow && emaSlow < emaTrend && closePrice < emaFast);

      if(adxMain < m_adxRangeThreshold)
         return(TREND_RANGE);

      if(bullishAlignment && adxMain >= m_adxTrendThreshold)
         return(TREND_BULLISH);

      if(bearishAlignment && adxMain >= m_adxTrendThreshold)
         return(TREND_BEARISH);

      // ADX ni clairement range ni clairement tendance forte, ou EMA
      // pas parfaitement alignées : on considère une transition.
      return(TREND_TRANSITION);
     }

   //---------------------------------------------------------------
   // Détermine le régime de volatilité à partir de l'ATR, converti
   // en points pour être comparable aux seuils configurés.
   //---------------------------------------------------------------
   ENUM_VOLATILITY_STATE DetermineVolatility(const double atrValue) const
     {
      if(atrValue == EMPTY_VALUE)
         return(VOLATILITY_TOO_LOW);

      double atrPoints = CUtilities::PriceToPoints(m_symbol, atrValue);

      if(atrPoints < m_atrMinPoints)
         return(VOLATILITY_TOO_LOW);
      if(atrPoints > m_atrMaxPoints)
         return(VOLATILITY_TOO_HIGH);
      return(VOLATILITY_NORMAL);
     }

   //---------------------------------------------------------------
   // Momentum basé sur le RSI, ramené à une échelle -100..+100.
   //---------------------------------------------------------------
   double            CalculateMomentum(const int shift) const
     {
      double rsi = m_indicators.GetRSI(shift);
      if(rsi == EMPTY_VALUE)
         return(0.0);
      return(CUtilities::Clamp((rsi - 50.0) * 2.0, -100.0, 100.0));
     }

   //---------------------------------------------------------------
   // Force du marché basée sur l'ADX, ramenée à une échelle 0..100.
   //---------------------------------------------------------------
   double            CalculateMarketStrength(const double adxMain) const
     {
      if(adxMain == EMPTY_VALUE)
         return(0.0);
      // ADX dépasse rarement 60-70 en pratique : on étire l'échelle.
      return(CUtilities::Clamp(adxMain * 1.6, 0.0, 100.0));
     }

   //---------------------------------------------------------------
   // Score de liquidité heuristique : volume tick de la bougie
   // analysée (shift) comparé à la moyenne des m_lookbackBars
   // bougies PRÉCÉDENTES (shift+1 .. shift+lookbackBars), jamais la
   // bougie encore en formation.
   //---------------------------------------------------------------
   double            CalculateLiquidityScore(const int shift) const
     {
      long currentVolume = m_indicators.GetTickVolume(shift);
      double sumVolume = 0.0;
      int count = 0;

      for(int i = shift + 1; i <= shift + m_lookbackBars; i++)
        {
         long v = m_indicators.GetTickVolume(i);
         if(v > 0)
           {
            sumVolume += (double)v;
            count++;
           }
        }

      if(count == 0)
         return(50.0); // Valeur neutre par défaut si pas d'historique

      double avgVolume = sumVolume / count;
      if(avgVolume <= 0.0)
         return(50.0);

      double ratio = (double)currentVolume / avgVolume;
      return(CUtilities::Clamp(ratio * 50.0, 0.0, 100.0));
     }

   //---------------------------------------------------------------
   // Détermine l'état de compression à partir de la largeur des
   // Bollinger Bands de la bougie analysée comparée à sa moyenne
   // récente (bougies précédentes uniquement).
   //---------------------------------------------------------------
   ENUM_COMPRESSION_STATE DetermineCompression(const int shift) const
     {
      double upperNow  = m_indicators.GetBBUpper(shift);
      double lowerNow   = m_indicators.GetBBLower(shift);
      double upperPrev = m_indicators.GetBBUpper(shift + 1);
      double lowerPrev  = m_indicators.GetBBLower(shift + 1);

      if(upperNow == EMPTY_VALUE || lowerNow == EMPTY_VALUE)
         return(COMPRESSION_NONE);

      double widthNow = upperNow - lowerNow;

      double sumWidth = 0.0;
      int count = 0;
      for(int i = shift + 1; i <= shift + m_lookbackBars; i++)
        {
         double u = m_indicators.GetBBUpper(i);
         double l = m_indicators.GetBBLower(i);
         if(u == EMPTY_VALUE || l == EMPTY_VALUE)
            continue;
         sumWidth += (u - l);
         count++;
        }

      if(count == 0)
         return(COMPRESSION_NONE);

      double avgWidth = sumWidth / count;
      if(avgWidth <= 0.0)
         return(COMPRESSION_NONE);

      double widthPrev = (upperPrev != EMPTY_VALUE && lowerPrev != EMPTY_VALUE) ? (upperPrev - lowerPrev) : widthNow;

      if(widthNow < avgWidth * 0.7)
         return(COMPRESSION_BUILDING);

      // Expansion nette après une bougie précédente encore serrée :
      // interprété comme un relâchement de compression (breakout probable)
      if(widthNow > avgWidth * 1.3 && widthPrev < avgWidth * 0.9)
         return(COMPRESSION_RELEASED);

      return(COMPRESSION_NONE);
     }

   //---------------------------------------------------------------
   // Estimation heuristique de phase Wyckoff, à partir de la
   // combinaison tendance + volatilité + position du prix dans son
   // range récent + liquidité. Best-effort, non académique.
   //---------------------------------------------------------------
   ENUM_WYCKOFF_PHASE DetermineWyckoffPhase(const int shift, const ENUM_TREND_STATE trend,
                                            const ENUM_VOLATILITY_STATE volatility,
                                            const double liquidityScore) const
     {
      int lookback = MathMax(m_lookbackBars, 10);
      double highestHigh = iHigh(m_symbol, m_timeframe, iHighest(m_symbol, m_timeframe, MODE_HIGH, lookback, shift + 1));
      double lowestLow   = iLow(m_symbol, m_timeframe, iLowest(m_symbol, m_timeframe, MODE_LOW, lookback, shift + 1));
      double closePrice  = iClose(m_symbol, m_timeframe, shift);

      double range = highestHigh - lowestLow;
      if(range <= 0.0)
         return(WYCKOFF_UNDEFINED);

      double positionInRange = (closePrice - lowestLow) / range; // 0 = proche du plus bas, 1 = proche du plus haut

      if(trend == TREND_BULLISH)
         return(WYCKOFF_MARKUP);

      if(trend == TREND_BEARISH)
         return(WYCKOFF_MARKDOWN);

      if(trend == TREND_RANGE || trend == TREND_CONSOLIDATION)
        {
         if(positionInRange < 0.35 && liquidityScore > 55.0)
            return(WYCKOFF_ACCUMULATION);
         if(positionInRange > 0.65 && liquidityScore > 55.0)
            return(WYCKOFF_DISTRIBUTION);
        }

      return(WYCKOFF_UNDEFINED);
     }

public:
                     CMarketContext()
     {
      m_indicators        = NULL;
      m_symbol            = "";
      m_timeframe         = PERIOD_CURRENT;
      m_initialized       = false;
      m_adxTrendThreshold = 25.0;
      m_adxRangeThreshold = 20.0;
      m_atrMinPoints      = 50.0;
      m_atrMaxPoints      = 800.0;
      m_lookbackBars      = 20;

      ZeroMemory(m_context);
     }

   //---------------------------------------------------------------
   // Initialise le contexte. NE PREND PAS possession de l'objet
   // CIndicators fourni (pas de destruction dans ce module) : c'est
   // l'appelant (module orchestrateur) qui gère son cycle de vie.
   //---------------------------------------------------------------
   bool              Init(CIndicators *indicators, const string symbol, const ENUM_TIMEFRAMES timeframe,
                          const double adxTrendThreshold = 25.0, const double adxRangeThreshold = 20.0,
                          const double atrMinPoints = 50.0, const double atrMaxPoints = 800.0,
                          const int lookbackBars = 20)
     {
      if(indicators == NULL || !indicators.IsInitialized())
        {
         Print("CMarketContext::Init - objet CIndicators invalide ou non initialisé");
         return(false);
        }

      m_indicators        = indicators;
      m_symbol            = symbol;
      m_timeframe         = timeframe;
      m_adxTrendThreshold = adxTrendThreshold;
      m_adxRangeThreshold = adxRangeThreshold;
      m_atrMinPoints      = atrMinPoints;
      m_atrMaxPoints      = atrMaxPoints;
      m_lookbackBars      = lookbackBars;

      m_initialized = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Recalcule l'intégralité du contexte marché. À appeler UNE FOIS
   // par nouvelle bougie (jamais à chaque tick), typiquement juste
   // après CUtilities::IsNewBar().
   // shift=1 par défaut : analyse la dernière bougie CLÔTURÉE, jamais
   // la bougie en cours de formation (shift=0) - voir le correctif
   // documenté en tête de fichier.
   //---------------------------------------------------------------
   bool              Update(const int shift = 1)
     {
      if(!m_initialized)
         return(false);

      double atrValue = m_indicators.GetATR(shift);
      double adxMain  = m_indicators.GetADXMain(shift);

      m_context.trend          = DetermineTrend(shift);
      m_context.volatility     = DetermineVolatility(atrValue);
      m_context.momentum       = CalculateMomentum(shift);
      m_context.marketStrength = CalculateMarketStrength(adxMain);
      m_context.liquidityScore = CalculateLiquidityScore(shift);
      m_context.compression    = DetermineCompression(shift);
      m_context.wyckoffPhase   = DetermineWyckoffPhase(shift, m_context.trend, m_context.volatility, m_context.liquidityScore);
      m_context.atrValue       = (atrValue == EMPTY_VALUE) ? 0.0 : atrValue;
      m_context.adxValue       = (adxMain == EMPTY_VALUE) ? 0.0 : adxMain;
      m_context.lastUpdate     = TimeCurrent();

      return(true);
     }

   //---------------------------------------------------------------
   // Retourne le dernier instantané calculé (lecture seule pour les
   // autres modules).
   //---------------------------------------------------------------
   SMarketContext    GetContext() const { return(m_context); }

   // Accesseurs individuels pratiques (évitent de copier toute la
   // struct quand un seul champ est nécessaire, ex: Dashboard)
   ENUM_TREND_STATE       GetTrend()          const { return(m_context.trend); }
   ENUM_VOLATILITY_STATE  GetVolatility()      const { return(m_context.volatility); }
   ENUM_WYCKOFF_PHASE     GetWyckoffPhase()    const { return(m_context.wyckoffPhase); }
   ENUM_COMPRESSION_STATE GetCompression()     const { return(m_context.compression); }
   double                 GetMomentum()        const { return(m_context.momentum); }
   double                 GetMarketStrength()  const { return(m_context.marketStrength); }
   double                 GetLiquidityScore()  const { return(m_context.liquidityScore); }

   //---------------------------------------------------------------
   // Résumé textuel lisible du contexte, réutilisable par CLogger et
   // CDashboard sans dupliquer la logique de formatage.
   //---------------------------------------------------------------
   string            ToSummaryString() const
     {
      return(StringFormat(
         "Trend=%s | Volatilite=%s | Wyckoff=%s | Momentum=%.1f | Force=%.1f | Liquidite=%.1f | ATR=%.5f | ADX=%.1f",
         CUtilities::TrendStateToString(m_context.trend),
         CUtilities::VolatilityStateToString(m_context.volatility),
         CUtilities::WyckoffPhaseToString(m_context.wyckoffPhase),
         m_context.momentum,
         m_context.marketStrength,
         m_context.liquidityScore,
         m_context.atrValue,
         m_context.adxValue));
     }
  };

#endif // MARKETCONTEXT_MQH
//+------------------------------------------------------------------+
