//+------------------------------------------------------------------+
//|                                                  Fibonacci.mqh    |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| Description : Analyse Fibonacci du contexte d'entrée.             |
//|   CFibonacci répond à "ce trade a-t-il été pris près d'un niveau  |
//|   de retracement Fibonacci classique (23.6/38.2/50/61.8/78.6%) ?" |
//|                                                                    |
//|   MÉTHODE (heuristique documentée, comme la phase Wyckoff dans    |
//|   MarketContext.mqh - pas une vérité académique) :                |
//|     1. Cherche le plus haut et le plus bas sur une fenêtre        |
//|        glissante (lookback).                                       |
//|     2. Détermine le sens de l'impulsion : si le plus haut est     |
//|        plus RÉCENT que le plus bas, l'impulsion est HAUSSIÈRE     |
//|        (bas -> haut) et la grille de retracement se lit depuis le |
//|        haut vers le bas (utile pour repérer un pullback BUY).     |
//|        Si le plus bas est plus récent, l'impulsion est BAISSIÈRE  |
//|        et la grille se lit depuis le bas vers le haut (pullback   |
//|        SELL).                                                      |
//|     3. Compare le prix d'entrée à chaque niveau standard et       |
//|        retourne le plus proche.                                    |
//|                                                                    |
//|   OBSERVATEUR PUR : ne calcule rien qui influence une décision de |
//|   trading, ne fait aucun appel à CTrade. Sert uniquement à         |
//|   enrichir les logs pour analyse statistique ultérieure.           |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef FIBONACCI_MQH
#define FIBONACCI_MQH

#include "Types.mqh"
#include "Utilities.mqh"

//+------------------------------------------------------------------+
//| Classe CFibonacci                                                    |
//| Entièrement statique : aucun état à conserver entre deux appels,  |
//| chaque calcul est indépendant (contrairement à CMarketStructure   |
//| qui doit, lui, se souvenir des swings passés).                    |
//+------------------------------------------------------------------+
class CFibonacci
  {
private:
   //---------------------------------------------------------------
   // Grille de niveaux Fibonacci standard utilisée par le projet.
   // Modifiable ici seulement si besoin d'ajouter/retirer un niveau -
   // point d'entrée unique, pas de duplication ailleurs.
   //---------------------------------------------------------------
   static void       GetStandardLevels(double &levelsOut[], string &labelsOut[])
     {
      ArrayResize(levelsOut, 7);
      ArrayResize(labelsOut, 7);
      levelsOut[0] = 0.0;   labelsOut[0] = "0.0%";
      levelsOut[1] = 0.236; labelsOut[1] = "23.6%";
      levelsOut[2] = 0.382; labelsOut[2] = "38.2%";
      levelsOut[3] = 0.5;   labelsOut[3] = "50.0%";
      levelsOut[4] = 0.618; labelsOut[4] = "61.8%";
      levelsOut[5] = 0.786; labelsOut[5] = "78.6%";
      levelsOut[6] = 1.0;   labelsOut[6] = "100.0%";
     }

public:
   //---------------------------------------------------------------
   // Calcule le niveau Fibonacci le plus proche du prix d'entrée.
   // Sorties (out-params, pour éviter d'introduire un struct
   // transitoire supplémentaire dans Types.mqh pour une donnée qui
   // n'existe que le temps de ce calcul) :
   //   levelLabelOut   : ex "61.8%" ou "Indisponible" si swing invalide
   //   distancePointsOut : distance entre le prix d'entrée et ce niveau
   //   legDirectionOut : "Impulsion haussiere" ou "Impulsion baissiere"
   //---------------------------------------------------------------
   static void       ComputeNearestLevel(const string symbol, const ENUM_TIMEFRAMES timeframe,
                                         const int lookbackBars, const double entryPrice, const int shift,
                                         string &levelLabelOut, double &distancePointsOut, string &legDirectionOut)
     {
      levelLabelOut     = "Indisponible";
      distancePointsOut = 0.0;
      legDirectionOut    = "Indeterminee";

      int idxHigh = iHighest(symbol, timeframe, MODE_HIGH, lookbackBars, shift);
      int idxLow  = iLowest(symbol, timeframe, MODE_LOW, lookbackBars, shift);
      if(idxHigh < 0 || idxLow < 0)
         return;

      double swingHigh = iHigh(symbol, timeframe, idxHigh);
      double swingLow  = iLow(symbol, timeframe, idxLow);
      double range = swingHigh - swingLow;
      if(range <= 0.0)
         return;

      // idxHigh/idxLow sont des index de barre où 0 = bougie courante :
      // un index PLUS PETIT = une bougie PLUS RÉCENTE.
      bool bullishLeg = (idxHigh < idxLow); // le haut est plus récent -> impulsion bas->haut
      legDirectionOut = bullishLeg ? "Impulsion haussiere" : "Impulsion baissiere";

      double levels[];
      string labels[];
      GetStandardLevels(levels, labels);

      double bestDistance = -1.0;
      string bestLabel = "Indisponible";
      double bestPrice = 0.0;

      for(int i = 0; i < ArraySize(levels); i++)
        {
         double levelPrice = bullishLeg
                            ? (swingHigh - range * levels[i])   // retracement depuis le haut (pullback BUY)
                            : (swingLow  + range * levels[i]);  // retracement depuis le bas (pullback SELL)

         double dist = MathAbs(entryPrice - levelPrice);
         if(bestDistance < 0.0 || dist < bestDistance)
           {
            bestDistance = dist;
            bestLabel    = labels[i];
            bestPrice    = levelPrice;
           }
        }

      levelLabelOut     = bestLabel;
      distancePointsOut = CUtilities::PriceToPoints(symbol, bestDistance);
     }
  };

#endif // FIBONACCI_MQH
//+------------------------------------------------------------------+
