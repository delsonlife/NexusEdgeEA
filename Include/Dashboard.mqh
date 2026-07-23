//+------------------------------------------------------------------+
//|                                                   Dashboard.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Tableau de bord affiché sur le graphique.           |
//|   CDashboard dessine un panneau (fond + labels) avec toutes les   |
//|   informations demandées : nom, version, tendance, score, signal,|
//|   spread, ATR, RSI, profit du jour, drawdown, positions, session,|
//|   état du robot.                                                   |
//|                                                                    |
//|   Utilise les objets graphiques natifs MQL5 (OBJ_LABEL,           |
//|   OBJ_RECTANGLE_LABEL) - aucune dépendance externe.                |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef DASHBOARD_MQH
#define DASHBOARD_MQH

#include "Types.mqh"
#include "Utilities.mqh"

//+------------------------------------------------------------------+
//| Classe CDashboard                                                     |
//+------------------------------------------------------------------+
class CDashboard
  {
private:
   string            m_prefix;
   int               m_x;
   int               m_y;
   int               m_lineHeight;
   int               m_panelWidth;
   bool              m_initialized;
   bool              m_visible;

   //---------------------------------------------------------------
   // Crée (si nécessaire) ou met à jour un label texte à la ligne
   // donnée (lineIndex à partir de 0).
   //---------------------------------------------------------------
   void              SetLabel(const string suffix, const int lineIndex, const string text, const color clr = clrWhite)
     {
      string name = m_prefix + "_" + suffix;

      if(ObjectFind(0, name) < 0)
        {
         bool created = ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         if(!created)
           {
            Print("CDashboard: Dashboard Error - échec ObjectCreate(OBJ_LABEL) pour '", name, "' - GetLastError()=", GetLastError());
            return;
           }
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, m_x + 10);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
        }

      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, m_y + 10 + lineIndex * m_lineHeight);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
     }

   //---------------------------------------------------------------
   // Crée (si nécessaire) le rectangle de fond du panneau.
   //---------------------------------------------------------------
   void              EnsureBackground(const int totalLines)
     {
      string name = m_prefix + "_Background";
      int panelHeight = 20 + totalLines * m_lineHeight;

      if(ObjectFind(0, name) < 0)
        {
         bool created = ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         if(!created)
           {
            Print("CDashboard: Dashboard Error - échec ObjectCreate(OBJ_RECTANGLE_LABEL) pour '", name, "' - GetLastError()=", GetLastError());
            return;
           }
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, m_x);
         ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'20,20,20');
         ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clrDimGray);
         ObjectSetInteger(0, name, OBJPROP_BACK, false);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, name, OBJPROP_XSIZE, m_panelWidth);
         Print("CDashboard: Dashboard Created (prefix=", m_prefix, ")");
        }

      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, m_y);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, panelHeight);
     }

   //---------------------------------------------------------------
   // Couleur contextuelle pour le signal (vert=BUY, rouge=SELL,
   // gris=NONE).
   //---------------------------------------------------------------
   color             GetSignalColor(const ENUM_SIGNAL_TYPE signal) const
     {
      if(signal == SIGNAL_BUY)
         return(clrLimeGreen);
      if(signal == SIGNAL_SELL)
         return(clrTomato);
      return(clrSilver);
     }

   //---------------------------------------------------------------
   // Couleur contextuelle pour la tendance.
   //---------------------------------------------------------------
   color             GetTrendColor(const ENUM_TREND_STATE trend) const
     {
      if(trend == TREND_BULLISH)
         return(clrLimeGreen);
      if(trend == TREND_BEARISH)
         return(clrTomato);
      return(clrKhaki);
     }

public:
                     CDashboard()
     {
      m_prefix      = "NEA_Dash";
      m_x           = 10;
      m_y           = 20;
      m_lineHeight  = 16;
      m_panelWidth  = 260;
      m_initialized = false;
      m_visible     = true;
     }

   //---------------------------------------------------------------
   // Initialise le dashboard (position, préfixe des objets - utile
   // pour éviter toute collision si plusieurs instances de l'EA
   // tournent sur des graphiques différents).
   //---------------------------------------------------------------
   bool              Init(const int x, const int y, const bool visible, const string prefix = "NEA_Dash")
     {
      Print("CDashboard: Dashboard Init Start (x=", x, ", y=", y, ", visible=", visible, ", prefix=", prefix, ")");
      m_x           = x;
      m_y           = y;
      m_visible     = visible;
      m_prefix      = prefix;
      m_initialized = true;
      Print("CDashboard: Dashboard Init termine avec succes");
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Supprime tous les objets graphiques créés par ce dashboard
   // (à appeler dans OnDeinit).
   //---------------------------------------------------------------
   void              Deinit()
     {
      ObjectsDeleteAll(0, m_prefix + "_");
      ChartRedraw(0);
     }

   //---------------------------------------------------------------
   // Met à jour l'intégralité du panneau. À appeler à chaque nouvelle
   // bougie (ou plus souvent si l'on veut un affichage temps réel du
   // spread - peu coûteux, ObjectSetString ne redessine que le texte).
   //---------------------------------------------------------------
   void              Update(const SDashboardData &data)
     {
      if(!m_initialized)
        {
         Print("CDashboard: Update ignore - dashboard non initialise (appeler Init() dans OnInit)");
         return;
        }
      if(!m_visible)
         return; // Desactive volontairement via InpShowDashboard=false, pas une erreur

      const int totalLines = 14;
      EnsureBackground(totalLines);

      int line = 0;
      SetLabel("Title", line++, StringFormat("%s v%s", EA_NAME, EA_VERSION), clrWhite);
      SetLabel("Symbol", line++, "Symbole    : " + data.symbol, clrWhite);
      SetLabel("Trend", line++, "Tendance   : " + CUtilities::TrendStateToString(data.trend), GetTrendColor(data.trend));
      SetLabel("Volatility", line++, "Volatilite : " + CUtilities::VolatilityStateToString(data.volatility), clrWhite);
      SetLabel("Signal", line++, "Signal     : " + CUtilities::SignalTypeToString(data.signalType), GetSignalColor(data.signalType));
      SetLabel("Score", line++, StringFormat("Score      : %.1f / %.1f", data.score, data.maxScore), clrWhite);
      SetLabel("Spread", line++, StringFormat("Spread     : %.1f pts", data.spreadPoints), clrWhite);
      SetLabel("ATR", line++, StringFormat("ATR        : %.5f", data.atrValue), clrWhite);
      SetLabel("RSI", line++, StringFormat("RSI        : %.1f", data.rsiValue), clrWhite);
      SetLabel("Profit", line++, StringFormat("Profit jour: %.2f", data.dailyProfit), (data.dailyProfit >= 0.0) ? clrLimeGreen : clrTomato);
      SetLabel("Drawdown", line++, StringFormat("Drawdown   : %.2f%%", data.drawdownPercent), (data.drawdownPercent > 10.0) ? clrTomato : clrWhite);
      SetLabel("Positions", line++, StringFormat("Positions  : %d / %d", data.positionsCount, data.maxPositions), clrWhite);
      SetLabel("Session", line++, "Session    : " + data.sessionLabel, clrWhite);
      SetLabel("State", line++, "Etat       : " + data.robotState, clrYellow);

      ChartRedraw(0);
     }
  };

#endif // DASHBOARD_MQH
//+------------------------------------------------------------------+
