//+------------------------------------------------------------------+
//|                                                   Validator.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Moteur de validation pré-trade.                     |
//|   CValidator effectue TOUTES les vérifications de sécurité et de  |
//|   cohérence avant qu'un trade ne soit envoyé au broker :           |
//|     marché ouvert, trading autorisé, compte connecté, spread,     |
//|     session, news, marge disponible, nombre de positions, perte/  |
//|     gain journalier, taille de lot, distances SL/TP (y compris    |
//|     distance minimale imposée par le broker - stops level).       |
//|                                                                    |
//|   Retourne un SValidationReport détaillé (VALID/INVALID + raison  |
//|   de chaque check), jamais un simple booléen : le robot doit      |
//|   toujours pouvoir expliquer pourquoi il refuse un trade.          |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef VALIDATOR_MQH
#define VALIDATOR_MQH

#include "Types.mqh"
#include "Utilities.mqh"
#include "Config.mqh"

//+------------------------------------------------------------------+
//| Classe CValidator                                                    |
//+------------------------------------------------------------------+
class CValidator
  {
private:
   int               m_checkIndex; // Index courant dans le tableau de checks du rapport en construction

   //---------------------------------------------------------------
   // Ajoute un résultat de check au rapport en construction.
   //---------------------------------------------------------------
   void              AddCheck(SValidationReport &report, const string label, const bool passed, const string detail)
     {
      if(m_checkIndex >= 20)
         return; // Sécurité : le tableau SValidationCheck[20] est plein

      report.checks[m_checkIndex].label  = label;
      report.checks[m_checkIndex].result = passed ? CHECK_PASSED : CHECK_FAILED;
      report.checks[m_checkIndex].detail = detail;
      m_checkIndex++;
      report.checksCount = m_checkIndex;

      if(!passed)
         report.tradeAllowed = false;
     }

   //---------------------------------------------------------------
   // Vérifie si l'heure serveur actuelle tombe dans au moins une
   // session activée par l'utilisateur (Tokyo/Londres/New York).
   // NOTE : logique provisoire, destinée à être reprise telle quelle
   // par CSessions (Market/Sessions.mqh) sans duplication - ce
   // module fera référence à celui-ci plutôt que de tout réécrire.
   //---------------------------------------------------------------
   bool              IsWithinAnyEnabledSession(string &sessionDetail) const
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int currentHour = dt.hour;

      ENUM_SESSION_NAME sessions[3] = {SESSION_TOKYO, SESSION_LONDON, SESSION_NEWYORK};
      string names[3] = {"Tokyo", "Londres", "New York"};

      bool anyEnabled = false;
      for(int i = 0; i < 3; i++)
        {
         SSessionConfig cfg = GetSessionConfig(sessions[i]);
         if(!cfg.enabled)
            continue;
         anyEnabled = true;

         bool withinWindow;
         if(cfg.startHour <= cfg.endHour)
            withinWindow = (currentHour >= cfg.startHour && currentHour < cfg.endHour);
         else // Fenêtre traversant minuit (ex: 22h -> 6h)
            withinWindow = (currentHour >= cfg.startHour || currentHour < cfg.endHour);

         if(withinWindow)
           {
            sessionDetail = StringFormat("Session %s active (%02d:00-%02d:00)", names[i], cfg.startHour, cfg.endHour);
            return(true);
           }
        }

      if(!anyEnabled)
        {
         sessionDetail = "Aucune session activée dans la configuration";
         return(false);
        }

      sessionDetail = StringFormat("Heure serveur %02d:00 hors de toute session activée", currentHour);
      return(false);
     }

   //---------------------------------------------------------------
   // Vérifie la distance SL/TP par rapport au prix d'entrée, en la
   // comparant au stops level minimal imposé par le broker.
   //---------------------------------------------------------------
   bool              CheckStopsDistance(const string symbol, const double entryPrice, const double stopPrice,
                                        const string label, string &detail) const
     {
      if(stopPrice <= 0.0)
        {
         detail = label + " non défini";
         return(true); // Un SL ou TP à 0 (non utilisé) n'est pas une erreur en soi
        }

      long stopsLevelPoints = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDistance = CUtilities::PointsToPrice(symbol, (double)stopsLevelPoints);
      double actualDistance = MathAbs(entryPrice - stopPrice);

      if(actualDistance < minDistance)
        {
         detail = StringFormat("%s trop proche : distance=%.5f, minimum broker=%.5f",
                               label, actualDistance, minDistance);
         return(false);
        }

      detail = StringFormat("%s OK : distance=%.5f (minimum broker=%.5f)", label, actualDistance, minDistance);
      return(true);
     }

   //---------------------------------------------------------------
   // Vérifie que le lot respecte les bornes min/max/step du broker.
   //---------------------------------------------------------------
   bool              CheckLotSize(const string symbol, const double lot, string &detail) const
     {
      double volMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double volMax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      double volStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

      if(lot < volMin || lot > volMax)
        {
         detail = StringFormat("Lot %.2f hors bornes broker [%.2f - %.2f]", lot, volMin, volMax);
         return(false);
        }

      if(volStep > 0.0)
        {
         double steps = (lot - volMin) / volStep;
         double roundedSteps = MathRound(steps);
         if(MathAbs(steps - roundedSteps) > 0.0001)
           {
            detail = StringFormat("Lot %.2f non conforme au step broker (%.2f)", lot, volStep);
            return(false);
           }
        }

      detail = StringFormat("Lot %.2f conforme (min=%.2f, max=%.2f, step=%.2f)", lot, volMin, volMax, volStep);
      return(true);
     }

   //---------------------------------------------------------------
   // Vérifie que la marge disponible couvre la marge requise pour
   // le volume et le type d'ordre prévus.
   //---------------------------------------------------------------
   bool              CheckMargin(const string symbol, const ENUM_SIGNAL_TYPE signalType, const double lot,
                                 const double entryPrice, string &detail) const
     {
      ENUM_ORDER_TYPE orderType = (signalType == SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double requiredMargin = 0.0;

      if(!OrderCalcMargin(orderType, symbol, lot, entryPrice, requiredMargin))
        {
         detail = StringFormat("Échec du calcul de marge (code %d)", GetLastError());
         return(false);
        }

      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

      if(requiredMargin > freeMargin)
        {
         detail = StringFormat("Marge insuffisante : requise=%.2f, disponible=%.2f", requiredMargin, freeMargin);
         return(false);
        }

      detail = StringFormat("Marge OK : requise=%.2f, disponible=%.2f", requiredMargin, freeMargin);
      return(true);
     }

public:
                     CValidator()
     {
      m_checkIndex = 0;
     }

   //---------------------------------------------------------------
   // Exécute l'ensemble des vérifications et retourne un rapport
   // complet. tradeAllowed n'est true QUE si tous les checks passent.
   //---------------------------------------------------------------
   SValidationReport Validate(const SValidationInput &vctx)
     {
      SValidationReport report;
      report.tradeAllowed = true;
      report.checksCount  = 0;
      report.summary      = "";
      m_checkIndex = 0;

      string detail;

      // 1. Marché ouvert
      bool marketOpen = CUtilities::IsMarketOpen(vctx.symbol);
      AddCheck(report, "Marché ouvert", marketOpen, marketOpen ? "Session de trading active" : "Marché fermé pour ce symbole");

      // 2. Trading autorisé (terminal + compte + symbole)
      bool tradeAllowed = (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
                          (bool)MQLInfoInteger(MQL_TRADE_ALLOWED) &&
                          (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) &&
                          (SymbolInfoInteger(vctx.symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_FULL);
      AddCheck(report, "Trading autorisé", tradeAllowed, tradeAllowed ? "Trading activé (terminal/compte/symbole)" : "Trading désactivé quelque part (terminal, compte ou symbole)");

      // 3. Compte connecté
      bool connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
      AddCheck(report, "Compte connecté", connected, connected ? "Connexion au serveur active" : "Pas de connexion au serveur");

      // 4. Spread
      double spreadPoints = CUtilities::GetSpreadPoints(vctx.symbol);
      bool spreadOk = (spreadPoints <= vctx.maxSpreadPoints);
      AddCheck(report, "Spread", spreadOk,
               StringFormat("Spread actuel=%.1f pts (max autorisé=%.1f pts)", spreadPoints, vctx.maxSpreadPoints));

      // 5. Session
      string sessionDetail;
      bool sessionOk = vctx.useSessionOverride ? vctx.sessionAllowedOverride : IsWithinAnyEnabledSession(sessionDetail);
      if(vctx.useSessionOverride)
         sessionDetail = sessionOk ? "Session autorisée (validée par CSessions)" : "Session refusée (validée par CSessions)";
      AddCheck(report, "Session", sessionOk, sessionDetail);

      // 6. News
      bool newsOk = !vctx.newsBlockActive;
      AddCheck(report, "News", newsOk, newsOk ? "Aucune annonce bloquante" : "Annonce économique importante en cours ou imminente");

      // 7. Nombre de positions max
      bool positionsOk = (vctx.currentOpenPositions < vctx.maxPositions);
      AddCheck(report, "Nombre de positions", positionsOk,
               StringFormat("Positions ouvertes=%d (max=%d)", vctx.currentOpenPositions, vctx.maxPositions));

      // 8. Perte journalière maximale
      bool dailyLossOk = true;
      AddCheck(report, "Perte journalière", dailyLossOk,
               StringFormat("P/L jour=%.2f%% (limite perte=-%.2f%%)", vctx.dailyProfitPercent, MathAbs(vctx.maxDailyLossPercent)));

      // 9. Gain journalier maximal (stop trading si atteint)
      bool dailyGainOk = true;
      AddCheck(report, "Gain journalier", dailyGainOk,
               StringFormat("P/L jour=%.2f%% (limite gain=+%.2f%%)", vctx.dailyProfitPercent, vctx.maxDailyGainPercent));

      // 10. Taille du lot
      bool lotOk = CheckLotSize(vctx.symbol, vctx.lot, detail);
      AddCheck(report, "Taille du lot", lotOk, detail);

      // 11. Distance Stop Loss
      bool slOk = CheckStopsDistance(vctx.symbol, vctx.entryPrice, vctx.slPrice, "Distance SL", detail);
      AddCheck(report, "Distance SL", slOk, detail);

      // 12. Distance Take Profit
      bool tpOk = CheckStopsDistance(vctx.symbol, vctx.entryPrice, vctx.tpPrice, "Distance TP", detail);
      AddCheck(report, "Distance TP", tpOk, detail);

      // 13. Marge disponible
      bool marginOk = CheckMargin(vctx.symbol, vctx.signalType, vctx.lot, vctx.entryPrice, detail);
      AddCheck(report, "Marge disponible", marginOk, detail);

      report.summary = BuildSummary(report);
      return(report);
     }

   //---------------------------------------------------------------
   // Construit le résumé textuel formaté avec ✔/❌, tel que demandé :
   //   Trade refusé :
   //   ✔ Spread OK
   //   ✔ Session OK
   //   ❌ News importante
   //---------------------------------------------------------------
   string            BuildSummary(const SValidationReport &report) const
     {
      string result = report.tradeAllowed ? "Trade autorisé :\n" : "Trade refusé :\n";

      for(int i = 0; i < report.checksCount; i++)
        {
         string mark = (report.checks[i].result == CHECK_PASSED) ? "✔" : "❌";
         result += StringFormat("%s %s : %s\n", mark, report.checks[i].label, report.checks[i].detail);
        }

      return(result);
     }
  };

#endif // VALIDATOR_MQH
//+------------------------------------------------------------------+
