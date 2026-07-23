//+------------------------------------------------------------------+
//|                                                  Utilities.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Fonctions utilitaires génériques et réutilisables. |
//|   Regroupées dans une classe statique CUtilities pour respecter  |
//|   l'architecture orientée classes et éviter toute duplication     |
//|   dans les autres modules.                                        |
//|                                                                    |
//| Contient notamment IsNewBar() (multi-symbole / multi-timeframe), |
//| des conversions prix <-> points, et des fonctions de formatage   |
//| texte utilisées par CLogger et CDashboard.                        |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef UTILITIES_MQH
#define UTILITIES_MQH

#include "Types.mqh"

//+------------------------------------------------------------------+
//| Classe CUtilities                                                   |
//| Toutes les méthodes sont statiques : cette classe ne conserve     |
//| aucun état propre à une instance, à l'exception du cache interne  |
//| utilisé par IsNewBar() (stocké en membres statiques de classe).   |
//+------------------------------------------------------------------+
class CUtilities
  {
private:
   // Cache interne pour IsNewBar() : permet de suivre plusieurs
   // couples (symbole, timeframe) simultanément sans dupliquer de
   // logique dans chaque module qui a besoin de détecter une
   // nouvelle bougie.
   static string            m_barKeys[];
   static datetime          m_barTimes[];

   //---------------------------------------------------------------
   // Recherche l'index d'une clé symbole/timeframe dans le cache.
   // Retourne -1 si la clé n'existe pas encore.
   //---------------------------------------------------------------
   static int        FindBarKeyIndex(const string key)
     {
      int total = ArraySize(m_barKeys);
      for(int i = 0; i < total; i++)
        {
         if(m_barKeys[i] == key)
            return(i);
        }
      return(-1);
     }

public:
   //---------------------------------------------------------------
   // Détecte l'ouverture d'une nouvelle bougie pour un symbole et un
   // timeframe donnés. Conçu pour être appelé à CHAQUE tick : la
   // fonction ne renvoie true qu'une seule fois par nouvelle bougie.
   // C'est la fonction centrale qui garantit que le robot n'analyse
   // jamais à chaque tick, uniquement à l'ouverture d'une bougie.
   //---------------------------------------------------------------
   static bool       IsNewBar(const string symbol, const ENUM_TIMEFRAMES timeframe)
     {
      datetime currentBarTime = iTime(symbol, timeframe, 0);
      if(currentBarTime == 0)
         return(false); // Données indisponibles (historique pas encore chargé)

      string key = symbol + "_" + EnumToString(timeframe);
      int    idx = FindBarKeyIndex(key);

      if(idx == -1)
        {
         // Première fois qu'on voit ce couple symbole/timeframe :
         // on l'enregistre mais on ne déclenche pas de signal "nouvelle
         // bougie" au tout premier appel (évite un faux déclenchement
         // au démarrage de l'EA).
         int newSize = ArraySize(m_barKeys) + 1;
         ArrayResize(m_barKeys, newSize);
         ArrayResize(m_barTimes, newSize);
         m_barKeys[newSize - 1]  = key;
         m_barTimes[newSize - 1] = currentBarTime;
         return(false);
        }

      if(m_barTimes[idx] != currentBarTime)
        {
         m_barTimes[idx] = currentBarTime;
         return(true);
        }

      return(false);
     }

   //---------------------------------------------------------------
   // Convertit une distance en points en distance de prix, pour un
   // symbole donné (indispensable car un point n'a pas la même valeur
   // sur XAUUSD, BTCUSD, EURUSD, NAS100, US30...).
   //---------------------------------------------------------------
   static double     PointsToPrice(const string symbol, const double points)
     {
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      return(points * point);
     }

   //---------------------------------------------------------------
   // Convertit une distance de prix en distance en points, pour un
   // symbole donné.
   //---------------------------------------------------------------
   static double     PriceToPoints(const string symbol, const double priceDistance)
     {
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(point <= 0.0)
         return(0.0);
      return(priceDistance / point);
     }

   //---------------------------------------------------------------
   // Normalise un prix au tick size du symbole (obligatoire avant
   // d'envoyer un ordre, sous peine de rejet par le broker).
   //---------------------------------------------------------------
   static double     NormalizePriceToTick(const string symbol, const double price)
     {
      double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize <= 0.0)
        {
         int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         return(NormalizeDouble(price, digits));
        }
      double normalized = MathRound(price / tickSize) * tickSize;
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      return(NormalizeDouble(normalized, digits));
     }

   //---------------------------------------------------------------
   // Retourne le spread courant du symbole, exprimé en points.
   //---------------------------------------------------------------
   static double     GetSpreadPoints(const string symbol)
     {
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(point <= 0.0)
         return(0.0);
      return((ask - bid) / point);
     }

   //---------------------------------------------------------------
   // Division sécurisée : évite toute division par zéro dans les
   // calculs de ratio (RR, Profit Factor, etc.).
   //---------------------------------------------------------------
   static double     SafeDivide(const double numerator, const double denominator, const double fallback = 0.0)
     {
      if(MathAbs(denominator) < 0.0000001)
         return(fallback);
      return(numerator / denominator);
     }

   //---------------------------------------------------------------
   // Vérifie si le marché est actuellement ouvert pour un symbole
   // (utilisé par CValidator).
   //---------------------------------------------------------------
   static bool       IsMarketOpen(const string symbol)
     {
      datetime serverTime = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(serverTime, dt);

      datetime from, to;
      if(!SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, 0, from, to))
         return(false);
      return(true);
     }

   //---------------------------------------------------------------
   // Fonctions de formatage texte : converties les enums en libellés
   // lisibles pour CLogger, CDashboard et les messages du Validator.
   //---------------------------------------------------------------
   static string     TrendStateToString(const ENUM_TREND_STATE state)
     {
      switch(state)
        {
         case TREND_BULLISH:       return("Haussière");
         case TREND_BEARISH:       return("Baissière");
         case TREND_RANGE:         return("Range");
         case TREND_TRANSITION:    return("Transition");
         case TREND_CONSOLIDATION: return("Consolidation");
         default:                  return("Inconnue");
        }
     }

   static string     SignalTypeToString(const ENUM_SIGNAL_TYPE type)
     {
      switch(type)
        {
         case SIGNAL_BUY:  return("BUY");
         case SIGNAL_SELL: return("SELL");
         default:          return("NONE");
        }
     }

   static string     VolatilityStateToString(const ENUM_VOLATILITY_STATE state)
     {
      switch(state)
        {
         case VOLATILITY_TOO_LOW:  return("Trop faible");
         case VOLATILITY_TOO_HIGH: return("Trop élevée");
         default:                  return("Normale");
        }
     }

   static string     WyckoffPhaseToString(const ENUM_WYCKOFF_PHASE phase)
     {
      switch(phase)
        {
         case WYCKOFF_ACCUMULATION: return("Accumulation");
         case WYCKOFF_MARKUP:       return("Markup");
         case WYCKOFF_DISTRIBUTION: return("Distribution");
         case WYCKOFF_MARKDOWN:     return("Markdown");
         default:                   return("Indéterminée");
        }
     }

   //---------------------------------------------------------------
   // Formate un double avec un nombre de décimales fixe, sans passer
   // par les particularités locales (toujours un point décimal).
   //---------------------------------------------------------------
   static string     FormatDouble(const double value, const int decimals)
     {
      return(DoubleToString(value, decimals));
     }

   //---------------------------------------------------------------
   // Clamp générique : borne une valeur entre un min et un max.
   //---------------------------------------------------------------
   static double     Clamp(const double value, const double minValue, const double maxValue)
     {
      if(value < minValue)
         return(minValue);
      if(value > maxValue)
         return(maxValue);
      return(value);
     }
  };

// Définition des membres statiques (obligatoire en MQL5/C++)
string   CUtilities::m_barKeys[];
datetime CUtilities::m_barTimes[];

#endif // UTILITIES_MQH
//+------------------------------------------------------------------+
