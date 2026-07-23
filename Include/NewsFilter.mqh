//+------------------------------------------------------------------+
//|                                                 NewsFilter.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Filtre d'annonces économiques importantes.          |
//|   CNewsFilter accepte DEUX sources de données, interchangeables : |
//|     1) NEWS_SOURCE_NATIVE_CALENDAR : calendrier économique natif  |
//|        MQL5 (CalendarValueHistory). Dépend de l'alimentation du   |
//|        calendrier par le broker (Exness) - non garantie complète. |
//|     2) NEWS_SOURCE_CSV_IMPORT : fichier CSV fourni manuellement   |
//|        (format : DateTime;Devise;Nom;Importance), pour ne jamais |
//|        être bloqué si le calendrier natif est incomplet.          |
//|                                                                    |
//|   Le robot ignore le trading autour des annonces importantes      |
//|   (fenêtre configurable avant/après).                             |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef NEWSFILTER_MQH
#define NEWSFILTER_MQH

#include "Types.mqh"

//+------------------------------------------------------------------+
//| Classe CNewsFilter                                                   |
//+------------------------------------------------------------------+
class CNewsFilter
  {
private:
   ENUM_NEWS_SOURCE  m_source;
   int               m_minutesBefore;
   int               m_minutesAfter;
   ENUM_NEWS_IMPORTANCE m_minImportance; // Importance minimale bloquante
   SNewsEvent        m_events[];
   bool              m_initialized;
   datetime          m_lastRefresh;

   //---------------------------------------------------------------
   // Convertit l'importance native MQL5 (ENUM_CALENDAR_EVENT_IMPORTANCE)
   // vers notre propre échelle ENUM_NEWS_IMPORTANCE.
   //---------------------------------------------------------------
   ENUM_NEWS_IMPORTANCE MapNativeImportance(const ENUM_CALENDAR_EVENT_IMPORTANCE nativeImportance) const
     {
      switch(nativeImportance)
        {
         case CALENDAR_IMPORTANCE_HIGH:
            return(NEWS_IMPORTANCE_HIGH);
         case CALENDAR_IMPORTANCE_MODERATE:
            return(NEWS_IMPORTANCE_MEDIUM);
         default:
            return(NEWS_IMPORTANCE_LOW);
        }
     }

public:
                     CNewsFilter()
     {
      m_source        = NEWS_SOURCE_NONE;
      m_minutesBefore = 30;
      m_minutesAfter  = 30;
      m_minImportance = NEWS_IMPORTANCE_HIGH;
      m_initialized   = false;
      m_lastRefresh   = 0;
     }

   //---------------------------------------------------------------
   // Initialise le filtre. csvFilename n'est utilisé que si
   // source == NEWS_SOURCE_CSV_IMPORT (fichier attendu dans
   // MQL5/Files/).
   //---------------------------------------------------------------
   bool              Init(const ENUM_NEWS_SOURCE source, const int minutesBefore, const int minutesAfter,
                          const ENUM_NEWS_IMPORTANCE minImportance = NEWS_IMPORTANCE_HIGH,
                          const string csvFilename = "")
     {
      m_source        = source;
      m_minutesBefore = minutesBefore;
      m_minutesAfter  = minutesAfter;
      m_minImportance = minImportance;
      m_initialized   = true;

      if(m_source == NEWS_SOURCE_CSV_IMPORT)
         return(LoadFromCSV(csvFilename));

      if(m_source == NEWS_SOURCE_NATIVE_CALENDAR)
         return(RefreshFromNativeCalendar("USD")); // XAUUSD est principalement piloté par les news USD

      return(true); // NEWS_SOURCE_NONE : rien à charger, le filtre laissera toujours passer
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Recharge les événements depuis le calendrier économique natif
   // MQL5, pour la devise donnée, sur une fenêtre glissante de 2
   // jours (hier -> demain). À rappeler périodiquement (ex : une
   // fois par jour, pas à chaque bougie) via Update().
   //---------------------------------------------------------------
   bool              RefreshFromNativeCalendar(const string currencyCode)
     {
      ArrayResize(m_events, 0);

      datetime fromTime = TimeCurrent() - 86400;      // Depuis hier
      datetime toTime   = TimeCurrent() + 2 * 86400;  // Jusqu'à après-demain

      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, fromTime, toTime, NULL, currencyCode))
        {
         Print("CNewsFilter::RefreshFromNativeCalendar - échec CalendarValueHistory (code ", GetLastError(), ")");
         return(false);
        }

      int total = ArraySize(values);
      for(int i = 0; i < total; i++)
        {
         MqlCalendarEvent eventInfo;
         if(!CalendarEventById(values[i].event_id, eventInfo))
            continue;

         ENUM_NEWS_IMPORTANCE importance = MapNativeImportance(eventInfo.importance);
         if((int)importance < (int)m_minImportance)
            continue; // On ne conserve que les annonces suffisamment importantes

         SNewsEvent ev;
         ev.time       = values[i].time;
         ev.currency   = currencyCode;
         ev.name       = eventInfo.name;
         ev.importance = importance;

         int n = ArraySize(m_events);
         ArrayResize(m_events, n + 1);
         m_events[n] = ev;
        }

      m_lastRefresh = TimeCurrent();
      return(true);
     }

   //---------------------------------------------------------------
   // Charge les événements depuis un fichier CSV manuel (fallback si
   // le calendrier natif du broker est incomplet ou indisponible).
   // Format attendu, une ligne par annonce :
   //   AAAA.MM.JJ HH:MM;DEVISE;Nom de l'annonce;Importance(0-2)
   // Exemple :
   //   2026.07.05 14:30;USD;Non-Farm Payrolls;2
   //---------------------------------------------------------------
   bool              LoadFromCSV(const string filename)
     {
      ArrayResize(m_events, 0);

      if(filename == "")
        {
         Print("CNewsFilter::LoadFromCSV - aucun nom de fichier fourni");
         return(false);
        }

      int handle = FileOpen(filename, FILE_READ | FILE_CSV | FILE_ANSI, ';');
      if(handle == INVALID_HANDLE)
        {
         Print("CNewsFilter::LoadFromCSV - échec ouverture fichier : ", filename, " (code ", GetLastError(), ")");
         return(false);
        }

      while(!FileIsEnding(handle))
        {
         string dateStr = FileReadString(handle);
         if(dateStr == "")
            break;

         string currency       = FileReadString(handle);
         string name           = FileReadString(handle);
         int    importanceCode = (int)FileReadNumber(handle);

         SNewsEvent ev;
         ev.time       = StringToTime(dateStr);
         ev.currency   = currency;
         ev.name       = name;
         ev.importance = (ENUM_NEWS_IMPORTANCE)MathMax(0, MathMin(2, importanceCode));

         if(ev.time > 0)
           {
            int n = ArraySize(m_events);
            ArrayResize(m_events, n + 1);
            m_events[n] = ev;
           }
        }

      FileClose(handle);
      m_lastRefresh = TimeCurrent();
      return(true);
     }

   //---------------------------------------------------------------
   // À appeler une fois par jour (pas à chaque bougie) pour garder le
   // calendrier natif à jour si cette source est utilisée. Sans effet
   // pour les autres sources.
   //---------------------------------------------------------------
   void              DailyRefreshIfNeeded(const string currencyCode = "USD")
     {
      if(m_source != NEWS_SOURCE_NATIVE_CALENDAR)
         return;

      if(TimeCurrent() - m_lastRefresh >= 86400)
         RefreshFromNativeCalendar(currencyCode);
     }

   //---------------------------------------------------------------
   // Indique si une annonce importante bloque le trading à l'instant
   // donné (par défaut l'heure serveur actuelle), avec un détail
   // explicatif pour CValidator/CLogger.
   //---------------------------------------------------------------
   bool              IsNewsBlockActive(string &detail, const datetime referenceTime = 0) const
     {
      if(m_source == NEWS_SOURCE_NONE)
        {
         detail = "Filtre de news désactivé";
         return(false);
        }

      datetime checkTime = (referenceTime == 0) ? TimeCurrent() : referenceTime;
      int total = ArraySize(m_events);

      for(int i = 0; i < total; i++)
        {
         long secondsBefore = (long)m_minutesBefore * 60;
         long secondsAfter  = (long)m_minutesAfter * 60;
         datetime windowStart = (datetime)((long)m_events[i].time - secondsBefore);
         datetime windowEnd   = (datetime)((long)m_events[i].time + secondsAfter);

         if(checkTime >= windowStart && checkTime <= windowEnd)
           {
            detail = StringFormat("Annonce '%s' (%s, importance=%s) prévue à %s",
                                  m_events[i].name, m_events[i].currency,
                                  EnumToString(m_events[i].importance),
                                  TimeToString(m_events[i].time, TIME_DATE | TIME_MINUTES));
            return(true);
           }
        }

      detail = "Aucune annonce bloquante à proximité";
      return(false);
     }

   int               GetEventCount() const { return(ArraySize(m_events)); }

   SNewsEvent        GetEvent(const int index) const
     {
      SNewsEvent empty;
      empty.time = 0;
      empty.currency = "";
      empty.name = "";
      empty.importance = NEWS_IMPORTANCE_LOW;

      if(index < 0 || index >= ArraySize(m_events))
         return(empty);
      return(m_events[index]);
     }
  };

#endif // NEWSFILTER_MQH
//+------------------------------------------------------------------+
