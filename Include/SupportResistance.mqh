//+------------------------------------------------------------------+
//|                                            SupportResistance.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Calcule les zones de support/résistance à partir   |
//|   des swing highs/lows de l'historique, détecte les cassures      |
//|   (breakout) et fausses cassures (fake breakout), et fournit les  |
//|   niveaux les plus proches du prix courant.                       |
//|                                                                    |
//|   Ce module est la base de confluence que CSignalManager croisera |
//|   avec les patterns détectés par CPatterns.                       |
//|                                                                    |
//|   Auto-suffisant : n'utilise que les fonctions natives de prix     |
//|   (iHigh/iLow/iClose), pas de dépendance à CIndicators.            |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef SUPPORTRESISTANCE_MQH
#define SUPPORTRESISTANCE_MQH

#include "Types.mqh"
#include "Utilities.mqh"

//+------------------------------------------------------------------+
//| Classe CSupportResistance                                            |
//+------------------------------------------------------------------+
class CSupportResistance
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   bool              m_initialized;

   int               m_lookbackBars;             // Profondeur d'historique scannée
   int               m_swingStrength;            // Nb de bougies de chaque côté pour confirmer un swing
   double            m_zoneMergeDistancePoints;   // Distance de fusion des niveaux proches (points)

   double            m_levels[];        // Niveaux de zone fusionnés (prix), triés croissants
   int               m_levelStrength[]; // Nombre de touches ayant formé chaque zone (force)

   //---------------------------------------------------------------
   // Détecte tous les swing highs/lows bruts sur l'historique et les
   // stocke dans un tableau temporaire non fusionné.
   //---------------------------------------------------------------
   void              ScanRawSwingLevels(double &rawLevels[])
     {
      ArrayResize(rawLevels, 0);

      int start = m_swingStrength + 1;
      int end   = m_lookbackBars;

      for(int s = start; s < end; s++)
        {
         double highS = iHigh(m_symbol, m_timeframe, s);
         double lowS  = iLow(m_symbol, m_timeframe, s);
         bool isSwingHigh = true;
         bool isSwingLow  = true;

         for(int k = 1; k <= m_swingStrength; k++)
           {
            if(iHigh(m_symbol, m_timeframe, s - k) > highS || iHigh(m_symbol, m_timeframe, s + k) > highS)
               isSwingHigh = false;
            if(iLow(m_symbol, m_timeframe, s - k) < lowS || iLow(m_symbol, m_timeframe, s + k) < lowS)
               isSwingLow = false;
           }

         if(isSwingHigh)
           {
            int n = ArraySize(rawLevels);
            ArrayResize(rawLevels, n + 1);
            rawLevels[n] = highS;
           }
         if(isSwingLow)
           {
            int n = ArraySize(rawLevels);
            ArrayResize(rawLevels, n + 1);
            rawLevels[n] = lowS;
           }
        }
     }

   //---------------------------------------------------------------
   // Fusionne les niveaux bruts proches (distance < zoneMergeDistance)
   // en zones uniques, avec un compteur de force (nombre de touches).
   //---------------------------------------------------------------
   void              MergeLevelsIntoZones(double &rawLevels[])
     {
      int total = ArraySize(rawLevels);
      ArrayResize(m_levels, 0);
      ArrayResize(m_levelStrength, 0);

      if(total == 0)
         return;

      ArraySort(rawLevels); // Tri croissant natif MQL5 pour tableau double

      double mergeDistance = CUtilities::PointsToPrice(m_symbol, m_zoneMergeDistancePoints);

      double clusterSum   = rawLevels[0];
      int    clusterCount = 1;

      for(int i = 1; i < total; i++)
        {
         double clusterAvg = clusterSum / clusterCount;
         if(MathAbs(rawLevels[i] - clusterAvg) <= mergeDistance)
           {
            clusterSum += rawLevels[i];
            clusterCount++;
           }
         else
           {
            int n = ArraySize(m_levels);
            ArrayResize(m_levels, n + 1);
            ArrayResize(m_levelStrength, n + 1);
            m_levels[n]         = clusterSum / clusterCount;
            m_levelStrength[n]  = clusterCount;

            clusterSum   = rawLevels[i];
            clusterCount = 1;
           }
        }

      // Dernier cluster restant
      int n = ArraySize(m_levels);
      ArrayResize(m_levels, n + 1);
      ArrayResize(m_levelStrength, n + 1);
      m_levels[n]        = clusterSum / clusterCount;
      m_levelStrength[n] = clusterCount;
     }

public:
                     CSupportResistance()
     {
      m_symbol                  = "";
      m_timeframe               = PERIOD_CURRENT;
      m_initialized             = false;
      m_lookbackBars            = 150;
      m_swingStrength           = 2;
      m_zoneMergeDistancePoints = 150.0;
     }

   //---------------------------------------------------------------
   // Initialise le module. lookbackBars doit rester raisonnable
   // (100-300) pour ne pas alourdir le recalcul à chaque bougie.
   //---------------------------------------------------------------
   bool              Init(const string symbol, const ENUM_TIMEFRAMES timeframe,
                          const int lookbackBars = 150, const int swingStrength = 2,
                          const double zoneMergeDistancePoints = 150.0)
     {
      m_symbol                  = symbol;
      m_timeframe               = timeframe;
      m_lookbackBars            = lookbackBars;
      m_swingStrength           = swingStrength;
      m_zoneMergeDistancePoints = zoneMergeDistancePoints;
      m_initialized             = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Recalcule toutes les zones de support/résistance. À appeler une
   // fois par nouvelle bougie (jamais à chaque tick).
   //---------------------------------------------------------------
   bool              Update()
     {
      if(!m_initialized)
         return(false);

      double rawLevels[];
      ScanRawSwingLevels(rawLevels);
      MergeLevelsIntoZones(rawLevels);
      return(true);
     }

   int               GetZoneCount() const { return(ArraySize(m_levels)); }

   double            GetZoneLevel(const int index) const
     {
      if(index < 0 || index >= ArraySize(m_levels))
         return(0.0);
      return(m_levels[index]);
     }

   int               GetZoneStrength(const int index) const
     {
      if(index < 0 || index >= ArraySize(m_levelStrength))
         return(0);
      return(m_levelStrength[index]);
     }

   //---------------------------------------------------------------
   // Retourne le niveau de support le plus proche EN DESSOUS du prix
   // donné (0.0 si aucun trouvé).
   //---------------------------------------------------------------
   double            GetNearestSupport(const double price) const
     {
      double best = 0.0;
      int total = ArraySize(m_levels);
      for(int i = 0; i < total; i++)
        {
         if(m_levels[i] < price && m_levels[i] > best)
            best = m_levels[i];
        }
      return(best);
     }

   //---------------------------------------------------------------
   // Retourne le niveau de résistance le plus proche AU-DESSUS du
   // prix donné (0.0 si aucun trouvé).
   //---------------------------------------------------------------
   double            GetNearestResistance(const double price) const
     {
      double best = 0.0;
      int total = ArraySize(m_levels);
      for(int i = 0; i < total; i++)
        {
         if(m_levels[i] > price && (best == 0.0 || m_levels[i] < best))
            best = m_levels[i];
        }
      return(best);
     }

   //---------------------------------------------------------------
   // Retourne le niveau de zone le plus proche du prix donné, quel
   // que soit son côté (support ou résistance).
   //---------------------------------------------------------------
   double            GetNearestZoneLevel(const double price) const
     {
      double best = 0.0;
      double bestDistance = -1.0;
      int total = ArraySize(m_levels);
      for(int i = 0; i < total; i++)
        {
         double distance = MathAbs(m_levels[i] - price);
         if(bestDistance < 0.0 || distance < bestDistance)
           {
            bestDistance = distance;
            best = m_levels[i];
           }
        }
      return(best);
     }

   //---------------------------------------------------------------
   // Indique si le prix donné est actuellement en zone de retest
   // (à moins de toleranceInPoints d'une zone connue).
   //---------------------------------------------------------------
   bool              IsPriceNearZone(const double price, const double toleranceInPoints, double &zoneLevelOut) const
     {
      double tolerance = CUtilities::PointsToPrice(m_symbol, toleranceInPoints);
      double nearest = GetNearestZoneLevel(price);
      if(nearest == 0.0)
        {
         zoneLevelOut = 0.0;
         return(false);
        }
      zoneLevelOut = nearest;
      return(MathAbs(price - nearest) <= tolerance);
     }

   //---------------------------------------------------------------
   // Détecte une cassure (ou fausse cassure) de la zone la plus
   // proche du prix précédent, entre la bougie shift+1 et shift.
   // Si shift >= 2, vérifie en plus la bougie shift-1 (plus récente,
   // déjà clôturée) pour confirmer/infirmer la cassure.
   //---------------------------------------------------------------
   ENUM_BREAKOUT_STATE DetectBreakout(const int shift = 1) const
     {
      double prevClose = iClose(m_symbol, m_timeframe, shift + 1);
      double curClose  = iClose(m_symbol, m_timeframe, shift);

      double zoneLevel = GetNearestZoneLevel(prevClose);
      if(zoneLevel <= 0.0)
         return(BREAKOUT_NONE);

      bool crossedUp   = (prevClose <= zoneLevel && curClose > zoneLevel);
      bool crossedDown = (prevClose >= zoneLevel && curClose < zoneLevel);

      if(!crossedUp && !crossedDown)
         return(BREAKOUT_NONE);

      if(shift >= 2)
        {
         double nextClose = iClose(m_symbol, m_timeframe, shift - 1);
         if(crossedUp && nextClose < zoneLevel)
            return(BREAKOUT_FALSE_BULLISH);
         if(crossedDown && nextClose > zoneLevel)
            return(BREAKOUT_FALSE_BEARISH);
        }

      return(crossedUp ? BREAKOUT_BULLISH : BREAKOUT_BEARISH);
     }

   //---------------------------------------------------------------
   // Résumé textuel réutilisable par CLogger/CDashboard.
   //---------------------------------------------------------------
   string            ToSummaryString(const double currentPrice) const
     {
      double support    = GetNearestSupport(currentPrice);
      double resistance = GetNearestResistance(currentPrice);
      return(StringFormat("Support proche=%.5f | Resistance proche=%.5f | Zones detectees=%d",
                          support, resistance, GetZoneCount()));
     }
  };

#endif // SUPPORTRESISTANCE_MQH
//+------------------------------------------------------------------+
