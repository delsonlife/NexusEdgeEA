//+------------------------------------------------------------------+
//|                                                   Sessions.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Gestion des sessions de trading (Tokyo/Londres/    |
//|   New York), activables/désactivables individuellement via       |
//|   Config.mqh.                                                     |
//|                                                                    |
//|   Ce module est la référence UNIQUE pour toute décision liée aux |
//|   sessions. CValidator utilise actuellement sa propre copie       |
//|   temporaire de cette logique (documentée comme telle dans son   |
//|   code) ; elle pourra être remplacée par un appel à CSessions     |
//|   sans rien casser, la signature étant volontairement identique. |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef SESSIONS_MQH
#define SESSIONS_MQH

#include "Types.mqh"
#include "Config.mqh"

//+------------------------------------------------------------------+
//| Classe CSessions                                                     |
//+------------------------------------------------------------------+
class CSessions
  {
private:
   //---------------------------------------------------------------
   // Détermine si l'heure serveur actuelle tombe dans la fenêtre
   // d'une session donnée (gère les fenêtres traversant minuit).
   //---------------------------------------------------------------
   bool              IsHourWithinSession(const int currentHour, const SSessionConfig &cfg) const
     {
      if(!cfg.enabled)
         return(false);

      if(cfg.startHour <= cfg.endHour)
         return(currentHour >= cfg.startHour && currentHour < cfg.endHour);

      // Fenêtre traversant minuit (ex: 22h -> 6h)
      return(currentHour >= cfg.startHour || currentHour < cfg.endHour);
     }

public:
                     CSessions() {}

   //---------------------------------------------------------------
   // Indique si une session précise est actuellement active.
   //---------------------------------------------------------------
   bool              IsSessionActive(const ENUM_SESSION_NAME session) const
     {
      SSessionConfig cfg = GetSessionConfig(session);
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      return(IsHourWithinSession(dt.hour, cfg));
     }

   //---------------------------------------------------------------
   // Indique si l'heure serveur actuelle tombe dans AU MOINS une
   // session activée, avec un détail textuel explicatif (utilisé par
   // CValidator et CFilters pour justifier leur décision).
   //---------------------------------------------------------------
   bool              IsWithinAnyEnabledSession(string &detail) const
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

         if(IsHourWithinSession(currentHour, cfg))
           {
            detail = StringFormat("Session %s active (%02d:00-%02d:00)", names[i], cfg.startHour, cfg.endHour);
            return(true);
           }
        }

      if(!anyEnabled)
        {
         detail = "Aucune session activée dans la configuration";
         return(false);
        }

      detail = StringFormat("Heure serveur %02d:00 hors de toute session activée", currentHour);
      return(false);
     }

   //---------------------------------------------------------------
   // Retourne le nom de la (ou des) session(s) actuellement active(s),
   // pour affichage direct dans CDashboard. Gère le cas de
   // chevauchement Londres/New York (forte liquidité).
   //---------------------------------------------------------------
   string            GetCurrentSessionLabel() const
     {
      bool tokyo   = IsSessionActive(SESSION_TOKYO);
      bool london  = IsSessionActive(SESSION_LONDON);
      bool newyork = IsSessionActive(SESSION_NEWYORK);

      if(london && newyork)
         return("Londres + New York (chevauchement)");
      if(tokyo && london)
         return("Tokyo + Londres (chevauchement)");
      if(london)
         return("Londres");
      if(newyork)
         return("New York");
      if(tokyo)
         return("Tokyo");

      return("Hors session");
     }

   //---------------------------------------------------------------
   // Indique si l'on est dans le chevauchement Londres/New York,
   // généralement la fenêtre de plus forte liquidité de la journée.
   //---------------------------------------------------------------
   bool              IsLondonNewYorkOverlap() const
     {
      return(IsSessionActive(SESSION_LONDON) && IsSessionActive(SESSION_NEWYORK));
     }
  };

#endif // SESSIONS_MQH
//+------------------------------------------------------------------+
