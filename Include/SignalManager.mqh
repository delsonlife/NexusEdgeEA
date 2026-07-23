//+------------------------------------------------------------------+
//|                                              SignalManager.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Cœur du système de score intelligent.               |
//|   CSignalManager croise EMA, RSI, ATR, Support/Résistance,       |
//|   Pattern (uniquement en confluence de zone - principe validé),  |
//|   Momentum, Tendance, Breakout et Volume pour produire un signal |
//|   BUY/SELL/NONE avec score, confiance et justification textuelle |
//|   complète (le robot doit toujours pouvoir s'expliquer).          |
//|                                                                    |
//|   Seuil RELATIF (% du score maximum possible), pas un seuil fixe |
//|   en points - permet de recalibrer facilement fréquence/qualité   |
//|   des trades via le Strategy Tester (principe validé avec         |
//|   l'utilisateur : "peu de trades mais justifiés" tout en restant |
//|   pilotable plutôt que figé arbitrairement).                      |
//|                                                                    |
//|   INTERFACE DÉCOUPLÉE : SSignalResult (Types.mqh) est le contrat  |
//|   stable entre ce module et le reste du système. Un futur moteur |
//|   IA pourra remplacer CSignalManager en produisant la même struct |
//|   sans que CTradeManager/CRiskManager n'aient à changer.           |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef SIGNALMANAGER_MQH
#define SIGNALMANAGER_MQH

#include "Types.mqh"
#include "Utilities.mqh"
#include "Indicators.mqh"
#include "MarketContext.mqh"
#include "Patterns.mqh"
#include "SupportResistance.mqh"

// Seuils internes non exposés en input (ajustables ici si besoin)
#define SIGNAL_RSI_BULLISH_LEVEL     55.0
#define SIGNAL_RSI_BEARISH_LEVEL     45.0
#define SIGNAL_MOMENTUM_MIN_ABS      20.0
#define SIGNAL_LIQUIDITY_MIN         55.0
// NOTE: SIGNAL_ZONE_TOLERANCE_POINTS a ete retire d'ici et transforme en
// parametre reel (m_zoneTolerancePoints, via Init()) car sa valeur depend
// de l'echelle de prix du symbole (audit du 2026-07 : 150 points etait
// correct en absolu mais trop serre pour XAUUSD a son prix actuel).
// RSI/Momentum/Liquidite restent des constantes internes car ce sont des
// echelles normalisees (0-100), non dependantes du prix du symbole.

//+------------------------------------------------------------------+
//| Classe CSignalManager                                                |
//+------------------------------------------------------------------+
class CSignalManager
  {
private:
   CIndicators         *m_indicators;        // Référence non propriétaire
   CMarketContext      *m_marketContext;     // Référence non propriétaire
   CPatterns           *m_patterns;          // Référence non propriétaire
   CSupportResistance  *m_supportResistance; // Référence non propriétaire

   string               m_symbol;
   ENUM_TIMEFRAMES      m_timeframe;
   SScoreWeights        m_weights;
   double               m_scoreThresholdPercent; // Seuil relatif (% du score max possible)
   double               m_zoneTolerancePoints;   // Tolerance de confluence Pattern/S-R (points), paramétrable
   bool                 m_initialized;

   double               m_maxPossibleScore; // Somme de tous les poids, calculée une fois

   // --- Audit empirique des contributions (demandé pour distinguer
   // "critère structurellement rare" de "bug de détection") ---
   int                  m_totalAnalyses;
   int                  m_criteriaHitCount[9]; // Nb de fois où chaque critère a contribué >0
   string               m_criteriaLabels[9];

   //---------------------------------------------------------------
   // Calcule la somme de tous les poids configurés = score maximum
   // théorique atteignable si tous les critères pointaient dans la
   // même direction avec une force maximale.
   //---------------------------------------------------------------
   double            ComputeMaxPossibleScore() const
     {
      return(m_weights.emaScore + m_weights.rsiScore + m_weights.atrScore +
             m_weights.supportResistScore + m_weights.patternScore +
             m_weights.momentumScore + m_weights.trendScore +
             m_weights.breakoutScore + m_weights.volumeScore);
     }

   //---------------------------------------------------------------
   // Ajoute une contribution à l'accumulateur directionnel concerné
   // et construit la ligne de justification correspondante si la
   // contribution est non nulle.
   //---------------------------------------------------------------
   void              AddContribution(double &bullishTotal, double &bearishTotal, string &reasonLines,
                                     const bool isBullish, const double amount, const string label) const
     {
      if(amount <= 0.0)
         return;

      if(isBullish)
         bullishTotal += amount;
      else
         bearishTotal += amount;

      reasonLines += StringFormat("%s: +%.1f (%s) | ", label, amount, isBullish ? "haussier" : "baissier");
     }

public:
                     CSignalManager()
     {
      m_indicators         = NULL;
      m_marketContext      = NULL;
      m_patterns           = NULL;
      m_supportResistance  = NULL;
      m_symbol             = "";
      m_timeframe          = PERIOD_CURRENT;
      m_scoreThresholdPercent = 60.0;
      m_zoneTolerancePoints   = 600.0;
      m_initialized        = false;
      m_maxPossibleScore   = 0.0;

      m_totalAnalyses = 0;
      string labels[9] = {"EMA", "Tendance", "RSI", "Momentum", "Support/Resistance", "Pattern", "Breakout", "ATR Bonus", "Volume Bonus"};
      for(int i = 0; i < 9; i++)
        {
         m_criteriaHitCount[i] = 0;
         m_criteriaLabels[i]   = labels[i];
        }
     }

   //---------------------------------------------------------------
   // Initialise le moteur de signal. Ne prend possession d'aucun des
   // modules fournis (pas de destruction ici) : c'est l'orchestrateur
   // principal qui gère leur cycle de vie.
   //---------------------------------------------------------------
   bool              Init(CIndicators *indicators, CMarketContext *marketContext,
                          CPatterns *patterns, CSupportResistance *supportResistance,
                          const string symbol, const ENUM_TIMEFRAMES timeframe,
                          const SScoreWeights &weights, const double scoreThresholdPercent = 60.0,
                          const double zoneTolerancePoints = 600.0)
     {
      if(indicators == NULL || marketContext == NULL || patterns == NULL || supportResistance == NULL)
        {
         Print("CSignalManager::Init - un ou plusieurs modules requis sont NULL");
         return(false);
        }

      m_indicators            = indicators;
      m_marketContext         = marketContext;
      m_patterns              = patterns;
      m_supportResistance     = supportResistance;
      m_symbol                = symbol;
      m_timeframe             = timeframe;
      m_weights               = weights;
      m_scoreThresholdPercent = scoreThresholdPercent;
      m_zoneTolerancePoints   = zoneTolerancePoints;
      m_maxPossibleScore      = ComputeMaxPossibleScore();
      m_initialized           = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }
   double            GetMaxPossibleScore() const { return(m_maxPossibleScore); }

   //---------------------------------------------------------------
   // Rapport empirique : pour chaque critère, combien de fois (et
   // quel %) il a réellement contribué au score sur l'ensemble des
   // analyses effectuées depuis l'initialisation. C'est la preuve
   // demandée pour distinguer un critère structurellement rare d'un
   // bug de détection dans son module.
   //---------------------------------------------------------------
   string            GetContributionReport() const
     {
      string report = "===== AUDIT DES CONTRIBUTIONS (preuve empirique) =====\n";
      report += StringFormat("Nombre total de bougies analysees : %d\n", m_totalAnalyses);
      report += "--------------------------------------------------------\n";

      for(int i = 0; i < 9; i++)
        {
         double pct = (m_totalAnalyses > 0) ? ((double)m_criteriaHitCount[i] / (double)m_totalAnalyses * 100.0) : 0.0;
         report += StringFormat("%-22s : %5d / %d bougies (%.1f%%)\n",
                                m_criteriaLabels[i], m_criteriaHitCount[i], m_totalAnalyses, pct);
        }
      report += "=========================================================";
      return(report);
     }

   //---------------------------------------------------------------
   // Génère le signal pour la bougie clôturée au shift donné (1 par
   // défaut = dernière bougie clôturée au moment de l'ouverture d'une
   // nouvelle bougie). Retourne TOUJOURS un SSignalResult, même
   // PATTERN_NONE / SIGNAL_NONE, pour permettre à l'appelant de
   // l'enregistrer via CLogger::LogDecision (mode analyse des
   // performances, y compris signaux non exécutés).
   //---------------------------------------------------------------
   SSignalResult     GenerateSignal(const int shift = 1)
     {
      SSignalResult result;
      result.type       = SIGNAL_NONE;
      result.score      = 0.0;
      result.confidence = 0.0;
      result.reason     = "";
      result.time       = iTime(m_symbol, m_timeframe, shift);
      result.price      = iClose(m_symbol, m_timeframe, shift);
      result.executed   = false;

      if(!m_initialized)
        {
         result.reason = "CSignalManager non initialisé";
         return(result);
        }

      double bullishTotal = 0.0;
      double bearishTotal = 0.0;
      string reasonLines  = "";

      SMarketContext context = m_marketContext.GetContext();
      double closePrice = result.price;

      // --- Suivi diagnostic : CHAQUE critère est enregistré, même
      // s'il contribue 0 point, pour un mode debug complet.
      string critName[9];
      double critAmount[9];      // magnitude de la contribution (toujours >= 0)
      string critDirection[9];   // "Haussier" / "Baissier" / "Neutre (bonus)" / "Aucun"
      for(int i = 0; i < 9; i++)
        {
         critAmount[i]    = 0.0;
         critDirection[i] = "Aucun";
        }

      // --- 1. EMA (alignement court terme, indépendant de l'ADX) ---
      critName[0] = "EMA";
      double emaFast   = m_indicators.GetEMA(EMA_INDEX_FAST, shift);
      double emaMedium = m_indicators.GetEMA(EMA_INDEX_MEDIUM, shift);
      if(emaFast != EMPTY_VALUE && emaMedium != EMPTY_VALUE && emaFast != emaMedium)
        {
         bool emaBullish = (emaFast > emaMedium);
         AddContribution(bullishTotal, bearishTotal, reasonLines, emaBullish, m_weights.emaScore, "EMA");
         critAmount[0]    = m_weights.emaScore;
         critDirection[0] = emaBullish ? "Haussier" : "Baissier";
        }

      // --- 2. Tendance globale (confirmée ADX, via CMarketContext) ---
      critName[1] = "Tendance";
      if(context.trend == TREND_BULLISH)
        {
         AddContribution(bullishTotal, bearishTotal, reasonLines, true, m_weights.trendScore, "Tendance");
         critAmount[1] = m_weights.trendScore; critDirection[1] = "Haussier";
        }
      else if(context.trend == TREND_BEARISH)
        {
         AddContribution(bullishTotal, bearishTotal, reasonLines, false, m_weights.trendScore, "Tendance");
         critAmount[1] = m_weights.trendScore; critDirection[1] = "Baissier";
        }

      // --- 3. RSI ---
      critName[2] = "RSI";
      double rsi = m_indicators.GetRSI(shift);
      if(rsi != EMPTY_VALUE)
        {
         if(rsi >= SIGNAL_RSI_BULLISH_LEVEL)
           {
            AddContribution(bullishTotal, bearishTotal, reasonLines, true, m_weights.rsiScore, "RSI");
            critAmount[2] = m_weights.rsiScore; critDirection[2] = "Haussier";
           }
         else if(rsi <= SIGNAL_RSI_BEARISH_LEVEL)
           {
            AddContribution(bullishTotal, bearishTotal, reasonLines, false, m_weights.rsiScore, "RSI");
            critAmount[2] = m_weights.rsiScore; critDirection[2] = "Baissier";
           }
        }

      // --- 4. Momentum (proportionnel à sa force, via CMarketContext) ---
      critName[3] = "Momentum";
      if(MathAbs(context.momentum) >= SIGNAL_MOMENTUM_MIN_ABS)
        {
         double momentumAmount = m_weights.momentumScore * (MathAbs(context.momentum) / 100.0);
         AddContribution(bullishTotal, bearishTotal, reasonLines, (context.momentum > 0), momentumAmount, "Momentum");
         critAmount[3]    = momentumAmount;
         critDirection[3] = (context.momentum > 0) ? "Haussier" : "Baissier";
        }

      // --- 5. Support/Résistance (confluence de zone) ---
      critName[4] = "Support/Resistance";
      double zoneLevel = 0.0;
      bool nearZone = m_supportResistance.IsPriceNearZone(closePrice, m_zoneTolerancePoints, zoneLevel);
      if(nearZone)
        {
         // Proche d'un support (zone sous le prix) -> biais haussier (rebond attendu)
         // Proche d'une résistance (zone au-dessus du prix) -> biais baissier
         bool srBullish = (zoneLevel <= closePrice);
         AddContribution(bullishTotal, bearishTotal, reasonLines, srBullish, m_weights.supportResistScore, "Support/Resistance");
         critAmount[4]    = m_weights.supportResistScore;
         critDirection[4] = srBullish ? "Haussier" : "Baissier";
        }

      // --- 6. Pattern (UNIQUEMENT si en confluence avec une zone S/R,
      //     principe validé avec l'utilisateur : un pattern isolé ne
      //     contribue quasiment pas au score) ---
      critName[5] = "Pattern";
      SPatternResult pattern = m_patterns.DetectPattern(shift);
      if(pattern.pattern != PATTERN_NONE && nearZone)
        {
         double patternAmount = m_weights.patternScore * (pattern.strength / 100.0);
         AddContribution(bullishTotal, bearishTotal, reasonLines, pattern.bullish, patternAmount,
                         "Pattern(" + pattern.description + ")");
         critAmount[5]    = patternAmount;
         critDirection[5] = pattern.bullish ? "Haussier" : "Baissier";
         critName[5]      = "Pattern(" + pattern.description + ")";
        }
      else if(pattern.pattern != PATTERN_NONE && !nearZone)
         critName[5] = "Pattern (hors zone, ignore)";
      else
         critName[5] = "Pattern (aucun detecte)";

      // --- 7. Breakout / Fake Breakout ---
      critName[6] = "Breakout";
      ENUM_BREAKOUT_STATE breakout = m_supportResistance.DetectBreakout(shift);
      if(breakout == BREAKOUT_BULLISH)
        {
         AddContribution(bullishTotal, bearishTotal, reasonLines, true, m_weights.breakoutScore, "Breakout");
         critAmount[6] = m_weights.breakoutScore; critDirection[6] = "Haussier";
        }
      else if(breakout == BREAKOUT_BEARISH)
        {
         AddContribution(bullishTotal, bearishTotal, reasonLines, false, m_weights.breakoutScore, "Breakout");
         critAmount[6] = m_weights.breakoutScore; critDirection[6] = "Baissier";
        }
      else if(breakout == BREAKOUT_FALSE_BULLISH)
        {
         AddContribution(bullishTotal, bearishTotal, reasonLines, false, m_weights.breakoutScore * 0.5, "Fausse cassure (retournement)");
         critAmount[6] = m_weights.breakoutScore * 0.5; critDirection[6] = "Baissier (fausse cassure)";
         critName[6]   = "Breakout (fausse cassure haussiere)";
        }
      else if(breakout == BREAKOUT_FALSE_BEARISH)
        {
         AddContribution(bullishTotal, bearishTotal, reasonLines, true, m_weights.breakoutScore * 0.5, "Fausse cassure (retournement)");
         critAmount[6] = m_weights.breakoutScore * 0.5; critDirection[6] = "Haussier (fausse cassure)";
         critName[6]   = "Breakout (fausse cassure baissiere)";
        }
      else
         critName[6] = "Breakout (aucune cassure)";

      // --- 8. ATR (bonus de qualité, non directionnel : ajouté aux
      //     deux accumulateurs si la volatilité est dans le régime
      //     normal - récompense un contexte "tradable") ---
      critName[7] = "ATR Bonus";
      if(context.volatility == VOLATILITY_NORMAL)
        {
         bullishTotal += m_weights.atrScore;
         bearishTotal += m_weights.atrScore;
         reasonLines += StringFormat("ATR: +%.1f (bonus qualite, volatilite normale) | ", m_weights.atrScore);
         critAmount[7]    = m_weights.atrScore;
         critDirection[7] = "Neutre (bonus qualite, ajoute aux 2 sens)";
        }
      else
         critName[7] = StringFormat("ATR Bonus (volatilite=%s, pas de bonus)", CUtilities::VolatilityStateToString(context.volatility));

      // --- 9. Volume/Liquidité (bonus de qualité, non directionnel) ---
      critName[8] = "Volume Bonus";
      if(context.liquidityScore >= SIGNAL_LIQUIDITY_MIN)
        {
         bullishTotal += m_weights.volumeScore;
         bearishTotal += m_weights.volumeScore;
         reasonLines += StringFormat("Volume: +%.1f (liquidite=%.1f) | ", m_weights.volumeScore, context.liquidityScore);
         critAmount[8]    = m_weights.volumeScore;
         critDirection[8] = "Neutre (bonus qualite, ajoute aux 2 sens)";
        }
      else
         critName[8] = StringFormat("Volume Bonus (liquidite=%.1f < seuil %.1f, pas de bonus)", context.liquidityScore, SIGNAL_LIQUIDITY_MIN);

      // --- Audit empirique : on compte chaque critère qui a
      // réellement contribué, pour distinguer "rare mais normal" de
      // "jamais détecté à cause d'un bug" (preuve, pas supposition).
      m_totalAnalyses++;
      for(int i = 0; i < 9; i++)
        {
         if(critAmount[i] > 0.0)
            m_criteriaHitCount[i]++;
        }

      // --- Décision finale ---
      double winningTotal = MathMax(bullishTotal, bearishTotal);
      double thresholdPoints = m_maxPossibleScore * (m_scoreThresholdPercent / 100.0);
      double missingPoints = MathMax(0.0, thresholdPoints - winningTotal);

      result.score           = winningTotal;
      result.confidence      = (m_maxPossibleScore > 0.0) ? CUtilities::Clamp((winningTotal / m_maxPossibleScore) * 100.0, 0.0, 100.0) : 0.0;
      result.bullishScore    = bullishTotal;
      result.bearishScore    = bearishTotal;
      result.thresholdPoints = thresholdPoints;

      if(winningTotal >= thresholdPoints && winningTotal > 0.0)
         result.type = (bullishTotal >= bearishTotal) ? SIGNAL_BUY : SIGNAL_SELL;
      else
         result.type = SIGNAL_NONE;

      // --- Raison exacte quand Signal=NONE (demandé explicitement :
      // "je ne veux plus jamais avoir un simple SIGNAL_NONE sans
      // explication") ---
      string exactReason = "Signal genere normalement";
      if(result.type == SIGNAL_NONE)
        {
         bool isTie = (MathAbs(bullishTotal - bearishTotal) < 0.0001 && winningTotal > 0.0);
         if(winningTotal <= 0.0)
            exactReason = "Aucun critere directionnel actif (tous les critères a 0 ou neutres)";
         else if(isTie)
            exactReason = StringFormat("Egalite Bullish=Bearish=%.1f - aucune direction dominante", bullishTotal);
         else
            exactReason = StringFormat("Score insuffisant : %.1f obtenu, %.1f requis (manque %.1f pts, soit %.0f%% du score max)",
                                       winningTotal, thresholdPoints, missingPoints,
                                       (m_maxPossibleScore > 0.0) ? (missingPoints / m_maxPossibleScore * 100.0) : 0.0);
        }

      // --- Construction du bloc diagnostic complet (format demandé) ---
      string detail = "===== SCORE DETAIL =====\n";
      for(int i = 0; i < 9; i++)
         detail += StringFormat("%-28s : +%.1f (%s)\n", critName[i], critAmount[i], critDirection[i]);
      detail += "--------------------------\n";
      detail += StringFormat("Bullish   = %.1f\n", bullishTotal);
      detail += StringFormat("Bearish   = %.1f\n", bearishTotal);
      detail += StringFormat("Score     = %.1f\n", winningTotal);
      detail += StringFormat("Threshold = %.1f (%.0f%% de %.1f)\n", thresholdPoints, m_scoreThresholdPercent, m_maxPossibleScore);
      detail += StringFormat("Manquant  = %.1f\n", missingPoints);
      detail += StringFormat("Signal    = %s\n", CUtilities::SignalTypeToString(result.type));
      detail += StringFormat("Raison exacte : %s\n", exactReason);
      detail += "=========================";

      result.reason = detail;

      return(result);
     }
  };

#endif // SIGNALMANAGER_MQH
//+------------------------------------------------------------------+
