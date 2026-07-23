//+------------------------------------------------------------------+
//|                                                      Debug.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Système de debug centralisé, par catégorie.        |
//|   CDebug ne réécrit AUCUN système d'écriture de fichier : il      |
//|   s'appuie entièrement sur CLogger::LogDebug() déjà existant, et  |
//|   se contente de filtrer QUELLE catégorie de message a le droit   |
//|   de passer, avant même de construire la chaîne formatée.         |
//|                                                                    |
//|   DEUX DIMENSIONS DE FILTRAGE INDÉPENDANTES :                     |
//|     1) Sévérité  -> gérée par CLogger (InpLogLevel), INCHANGÉE.   |
//|     2) Catégorie -> gérée ici (InpDebugTrade/Signal/Trailing/     |
//|        Stats), NOUVELLE.                                          |
//|   Un message DEBUG_TRAILING(...) ne s'affiche donc que si         |
//|   InpLogLevel >= LOG_LEVEL_DEBUG ET InpDebugTrailing == true.      |
//|                                                                    |
//|   PERFORMANCE : les macros DEBUG_*() vérifient le flag de         |
//|   catégorie AVANT de construire la chaîne formatée (StringFormat).|
//|   Catégorie désactivée = aucun formatage de chaîne, aucun appel   |
//|   à CLogger. Impact quasi nul quand une catégorie est éteinte.    |
//|                                                                    |
//|   EXTENSIBILITÉ : ajouter une catégorie future (ex: DEBUG_RISK)   |
//|   nécessite seulement : une valeur d'enum avant DEBUG_CAT_COUNT,  |
//|   un flag bool dans Config.mqh, un paramètre supplémentaire dans  |
//|   CDebug::Init(), et une macro DEBUG_RISK(...) sur le même modèle |
//|   que les 4 existantes. Aucune structure existante n'est cassée.  |
//|                                                                    |
//|   INDÉPENDANCE MÉTIER : ce module ne connaît RIEN de la logique   |
//|   de trading (pas d'include de SignalManager, TradeManager,       |
//|   RiskManager...). Il ne fait qu'écrire du texte formaté via      |
//|   CLogger. Aucune décision n'est prise ici.                       |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef DEBUG_MQH
#define DEBUG_MQH

#include "Types.mqh"
#include "Logger.mqh"

// ENUM_DEBUG_CATEGORY est défini dans Types.mqh (cohérence demandée :
// tous les enums et structs du projet au même endroit). Voir Types.mqh
// pour la définition et les commentaires associés.

//+------------------------------------------------------------------+
//| Classe CDebug                                                       |
//| Toutes les méthodes sont statiques : CDebug ne s'instancie jamais, |
//| au même titre que CUtilities. Un seul point d'entrée global pour  |
//| tout le projet.                                                    |
//+------------------------------------------------------------------+
class CDebug
  {
private:
   static CLogger  *s_logger;                        // Référence non propriétaire vers le logger déjà initialisé
   static bool      s_categoryEnabled[DEBUG_CAT_COUNT]; // Flags par catégorie, copiés depuis Config à Init()
   static bool      s_initialized;

   //---------------------------------------------------------------
   // Libellé texte d'une catégorie, pour préfixer les messages dans
   // le fichier TXT / la console Experts (ex: "[DEBUG][TRAILING] ...").
   //---------------------------------------------------------------
   static string     CategoryLabel(const ENUM_DEBUG_CATEGORY category)
     {
      switch(category)
        {
         case DEBUG_CAT_TRADE:    return("TRADE");
         case DEBUG_CAT_SIGNAL:   return("SIGNAL");
         case DEBUG_CAT_TRAILING: return("TRAILING");
         case DEBUG_CAT_STATS:    return("STATS");
         default:                 return("DEBUG");
        }
     }

public:
   //---------------------------------------------------------------
   // Initialise CDebug avec le logger déjà initialisé par
   // l'orchestrateur (aucune prise de possession - CDebug ne détruit
   // jamais ce pointeur) et l'état initial de chaque catégorie,
   // typiquement lu depuis Config.mqh (InpDebugTrade, etc.).
   //---------------------------------------------------------------
   static void       Init(CLogger *logger, const bool enableTrade, const bool enableSignal,
                          const bool enableTrailing, const bool enableStats)
     {
      s_logger = logger;
      s_categoryEnabled[DEBUG_CAT_TRADE]    = enableTrade;
      s_categoryEnabled[DEBUG_CAT_SIGNAL]   = enableSignal;
      s_categoryEnabled[DEBUG_CAT_TRAILING] = enableTrailing;
      s_categoryEnabled[DEBUG_CAT_STATS]    = enableStats;
      s_initialized = (logger != NULL);
     }

   //---------------------------------------------------------------
   // Permet d'activer/désactiver une catégorie à chaud (utile si un
   // jour un bouton dashboard ou une commande graphique doit changer
   // le niveau de debug sans relancer l'EA - pas utilisé aujourd'hui,
   // mais ne coûte rien à prévoir).
   //---------------------------------------------------------------
   static void       SetCategoryEnabled(const ENUM_DEBUG_CATEGORY category, const bool enabled)
     {
      if(category < 0 || category >= DEBUG_CAT_COUNT)
         return;
      s_categoryEnabled[category] = enabled;
     }

   //---------------------------------------------------------------
   // Vérification rapide utilisée par les macros DEBUG_*() AVANT de
   // construire la chaîne formatée - c'est ce qui garantit l'absence
   // d'impact performance quand une catégorie est désactivée.
   //---------------------------------------------------------------
   static bool       IsCategoryEnabled(const ENUM_DEBUG_CATEGORY category)
     {
      if(!s_initialized)
         return(false);
      if(category < 0 || category >= DEBUG_CAT_COUNT)
         return(false);
      return(s_categoryEnabled[category]);
     }

   //---------------------------------------------------------------
   // Point d'écriture unique, appelé uniquement quand la catégorie
   // est déjà confirmée active. Délègue entièrement à
   // CLogger::LogDebug() - CDebug n'ouvre, n'écrit, ni ne ferme
   // aucun fichier lui-même.
   //---------------------------------------------------------------
   static void       Log(const ENUM_DEBUG_CATEGORY category, const string message)
     {
      if(!s_initialized || s_logger == NULL)
         return;

      s_logger.LogDebug(StringFormat("[%s] %s", CategoryLabel(category), message));
     }
  };

// Définition des membres statiques (obligatoire en MQL5, même
// pattern que CUtilities::m_barKeys/m_barTimes dans Utilities.mqh)
CLogger *CDebug::s_logger = NULL;
bool     CDebug::s_categoryEnabled[DEBUG_CAT_COUNT];
bool     CDebug::s_initialized = false;

//+------------------------------------------------------------------+
//| MACROS - point d'usage dans tout le reste du projet               |
//|                                                                    |
//| CORRECTIF COMPILATION : le préprocesseur MQL5 NE SUPPORTE PAS les |
//| macros variadiques (..., __VA_ARGS__) - contrairement à ce qui    |
//| était supposé initialement. Testé et confirmé à la compilation.   |
//| Les macros prennent donc UN SEUL paramètre : l'appelant construit |
//| lui-même la chaîne via StringFormat(...).                          |
//|                                                                    |
//| Usage :                                                            |
//|   DEBUG_SIGNAL(StringFormat("Score Bull = %.1f", scoreBull));     |
//|   DEBUG_TRADE(StringFormat("Ouverture SELL %.2f lot", lot));      |
//|   DEBUG_TRAILING(StringFormat("SL deplace de %.5f vers %.5f", oldSL, newSL)); |
//|   DEBUG_STATS(StringFormat("Capture Ratio = %.2f%%", ratio));      |
//|                                                                    |
//| PERFORMANCE PRÉSERVÉE MALGRÉ L'ABSENCE DE VARIADIQUE : la macro    |
//| fait une SUBSTITUTION TEXTUELLE, pas un appel de fonction. Le      |
//| paramètre "msg" (donc l'appel StringFormat(...) écrit par          |
//| l'appelant) n'apparaît qu'UNE FOIS dans le corps de la macro, à    |
//| l'intérieur du bloc if. Le compilateur ne génère donc le code de   |
//| formatage qu'à l'intérieur de cette branche : si la catégorie est  |
//| désactivée, StringFormat(...) n'est JAMAIS exécuté à l'exécution   |
//| (le if est évalué avant, et la branche vraie n'est jamais prise). |
//| La propriété "zero impact quand désactivé" est donc intacte.       |
//+------------------------------------------------------------------+
#define DEBUG_TRADE(msg)    do { if(CDebug::IsCategoryEnabled(DEBUG_CAT_TRADE))    CDebug::Log(DEBUG_CAT_TRADE,    (msg)); } while(false)
#define DEBUG_SIGNAL(msg)   do { if(CDebug::IsCategoryEnabled(DEBUG_CAT_SIGNAL))   CDebug::Log(DEBUG_CAT_SIGNAL,   (msg)); } while(false)
#define DEBUG_TRAILING(msg) do { if(CDebug::IsCategoryEnabled(DEBUG_CAT_TRAILING)) CDebug::Log(DEBUG_CAT_TRAILING, (msg)); } while(false)
#define DEBUG_STATS(msg)    do { if(CDebug::IsCategoryEnabled(DEBUG_CAT_STATS))    CDebug::Log(DEBUG_CAT_STATS,    (msg)); } while(false)

#endif // DEBUG_MQH
//+------------------------------------------------------------------+
