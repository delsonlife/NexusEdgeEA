//+------------------------------------------------------------------+
//|                                                    Filters.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Point d'entrée unique des filtres de marché.        |
//|   CFilters agrège spread, volatilité, session (via CSessions),   |
//|   news (via CNewsFilter), exploitabilité de la tendance (via     |
//|   CMarketContext) et drawdown courant, pour décider si un signal |
//|   mérite même d'être évalué par CSignalManager.                  |
//|                                                                    |
//|   DIFFÉRENCE avec CValidator : CFilters gate l'ANALYSE du signal  |
//|   (a-t-on un contexte de marché sain pour chercher un trade ?),   |
//|   CValidator gate l'EXÉCUTION du trade une fois le signal trouvé |
//|   (spread/session/news sont donc revérifiés à ce moment-là aussi,|
//|   car les conditions peuvent changer entre l'analyse et l'envoi   |
//|   de l'ordre - ce n'est pas une duplication de logique, juste un  |
//|   second passage temporel).                                       |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef FILTERS_MQH
#define FILTERS_MQH

#include "Types.mqh"
#include "Utilities.mqh"
#include "Sessions.mqh"
#include "NewsFilter.mqh"

//+------------------------------------------------------------------+
//| Classe CFilters                                                      |
//+------------------------------------------------------------------+
class CFilters
  {
private:
   CSessions        *m_sessions;    // Référence non propriétaire
   CNewsFilter      *m_newsFilter;  // Référence non propriétaire
   double            m_maxSpreadPoints;
   double            m_maxDrawdownPercent;
   double            m_atrMinPoints;   // Repris de Config, uniquement pour un log explicite (pas pour recalculer la décision)
   double            m_atrMaxPoints;   // Idem
   int               m_checkIndex;
   bool              m_initialized;

   //---------------------------------------------------------------
   // Ajoute un résultat de check au rapport en construction (même
   // pattern que CValidator pour cohérence de style dans tout le
   // projet).
   //---------------------------------------------------------------
   void              AddCheck(SValidationReport &report, const string label, const bool passed, const string detail)
     {
      if(m_checkIndex >= 20)
         return;

      report.checks[m_checkIndex].label  = label;
      report.checks[m_checkIndex].result = passed ? CHECK_PASSED : CHECK_FAILED;
      report.checks[m_checkIndex].detail = detail;
      m_checkIndex++;
      report.checksCount = m_checkIndex;

      if(!passed)
         report.tradeAllowed = false;
     }

public:
                     CFilters()
     {
      m_sessions           = NULL;
      m_newsFilter         = NULL;
      m_maxSpreadPoints    = 300.0;
      m_maxDrawdownPercent = 20.0;
      m_atrMinPoints       = 80.0;
      m_atrMaxPoints       = 3000.0;
      m_checkIndex         = 0;
      m_initialized        = false;
     }

   //---------------------------------------------------------------
   // Initialise le module. Ne prend pas possession de CSessions ni
   // CNewsFilter (pas de destruction ici) : c'est l'orchestrateur
   // principal qui gère leur cycle de vie.
   //---------------------------------------------------------------
   bool              Init(CSessions *sessions, CNewsFilter *newsFilter,
                          const double maxSpreadPoints = 300.0, const double maxDrawdownPercent = 20.0,
                          const double atrMinPoints = 80.0, const double atrMaxPoints = 3000.0)
     {
      if(sessions == NULL || newsFilter == NULL)
        {
         Print("CFilters::Init - CSessions ou CNewsFilter invalide (NULL)");
         return(false);
        }

      m_sessions           = sessions;
      m_newsFilter         = newsFilter;
      m_maxSpreadPoints    = maxSpreadPoints;
      m_maxDrawdownPercent = maxDrawdownPercent;
      m_atrMinPoints       = atrMinPoints;
      m_atrMaxPoints       = atrMaxPoints;
      m_initialized        = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Évalue l'ensemble des filtres de marché. Retourne un rapport
   // détaillé (même structure que CValidator) : le champ
   // tradeAllowed indique ici si l'ANALYSE de signal doit continuer.
   //---------------------------------------------------------------
   SValidationReport Evaluate(const string symbol, const SMarketContext &context, const double currentDrawdownPercent)
     {
      SValidationReport report;
      report.tradeAllowed = true;
      report.checksCount  = 0;
      report.summary      = "";
      m_checkIndex = 0;

      // 1. Spread
      double spreadPoints = CUtilities::GetSpreadPoints(symbol);
      bool spreadOk = (spreadPoints <= m_maxSpreadPoints);
      AddCheck(report, "Spread", spreadOk,
               StringFormat("Spread actuel=%.1f pts (max=%.1f pts)", spreadPoints, m_maxSpreadPoints));

      // 2. Volatilité (le régime est fourni par CMarketContext, pas
      // recalculé ici - mais on affiche le détail complet du calcul
      // pour que le refus soit toujours explicable : ATR brut, ATR
      // converti en points, et les seuils min/max réellement utilisés.
      double atrPoints = CUtilities::PriceToPoints(symbol, context.atrValue);
      bool volatilityOk = (context.volatility == VOLATILITY_NORMAL);
      AddCheck(report, "Volatilité", volatilityOk,
               StringFormat("Regime=%s | ATR brut=%.5f | ATR en points=%.1f | Seuils=[%.1f - %.1f]",
                           CUtilities::VolatilityStateToString(context.volatility),
                           context.atrValue, atrPoints, m_atrMinPoints, m_atrMaxPoints));

      // 3. Session
      string sessionDetail;
      bool sessionOk = m_sessions.IsWithinAnyEnabledSession(sessionDetail);
      AddCheck(report, "Session", sessionOk, sessionDetail);

      // 4. News
      string newsDetail;
      bool newsBlockActive = m_newsFilter.IsNewsBlockActive(newsDetail);
      AddCheck(report, "News", !newsBlockActive, newsDetail);

      // 5. Marché exploitable (ni totalement figé ni chaotique) : on
      // ne bloque que le cas extrême range + volatilité trop faible,
      // pour laisser les stratégies de breakout fonctionner sur les
      // autres régimes de Range.
      bool marketWorkable = !(context.trend == TREND_RANGE && context.volatility == VOLATILITY_TOO_LOW);
      AddCheck(report, "Contexte de marché", marketWorkable,
               StringFormat("Trend=%s | Volatilité=%s", CUtilities::TrendStateToString(context.trend),
                           CUtilities::VolatilityStateToString(context.volatility)));

      // 6. Drawdown
      bool drawdownOk = (currentDrawdownPercent <= m_maxDrawdownPercent);
      AddCheck(report, "Drawdown", drawdownOk,
               StringFormat("Drawdown actuel=%.2f%% (max=%.2f%%)", currentDrawdownPercent, m_maxDrawdownPercent));

      report.summary = BuildSummary(report);
      return(report);
     }

   //---------------------------------------------------------------
   // Résumé textuel formaté ✔/❌, identique dans l'esprit à
   // CValidator::BuildSummary(), pour cohérence de style des logs.
   //---------------------------------------------------------------
   string            BuildSummary(const SValidationReport &report) const
     {
      string result = report.tradeAllowed ? "Analyse de signal autorisée :\n" : "Analyse de signal filtrée :\n";

      for(int i = 0; i < report.checksCount; i++)
        {
         string mark = (report.checks[i].result == CHECK_PASSED) ? "✔" : "❌";
         result += StringFormat("%s %s : %s\n", mark, report.checks[i].label, report.checks[i].detail);
        }

      return(result);
     }
  };

#endif // FILTERS_MQH
//+------------------------------------------------------------------+
