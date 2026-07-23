//+------------------------------------------------------------------+
//|                                             SignalRecorder.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Analyse des performances - suivi post-signal.       |
//|   CSignalRecorder enregistre CHAQUE signal détecté (exécuté ou    |
//|   non) puis, plusieurs bougies plus tard, mesure ce qu'il serait |
//|   devenu (mouvement de prix après 10, 20, 50 bougies - fenêtres  |
//|   configurables via Config.mqh). Exporté en CSV pour analyse.    |
//|                                                                    |
//|   DIFFÉRENCE avec CLogger::LogDecision() : Logger journalise la  |
//|   décision au moment T (score, raison...). CSignalRecorder suit   |
//|   ce même signal dans le temps pour savoir s'il aurait été bon.   |
//|   C'est cette base qui permettra d'identifier objectivement quels|
//|   filtres/seuils écartent de bons trades ou en laissent passer de|
//|   mauvais - base du futur AI/DatasetExporter.mqh.                 |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef SIGNALRECORDER_MQH
#define SIGNALRECORDER_MQH

#include "Types.mqh"
#include "Utilities.mqh"

//+------------------------------------------------------------------+
//| Classe CSignalRecorder                                               |
//+------------------------------------------------------------------+
class CSignalRecorder
  {
private:
   //---------------------------------------------------------------
   // Entrée en attente de revue complète (interne, pas exposée hors
   // de cette classe).
   //---------------------------------------------------------------
   struct SPendingEntry
     {
      datetime          signalTime;
      ENUM_SIGNAL_TYPE  type;
      double            score;
      double            confidence;
      double            priceAtSignal;
      bool              executed;
      bool              done1, done2, done3;
      double            move1, move2, move3; // Mouvement de prix (signé) après N bougies
     };

   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_reviewBars1, m_reviewBars2, m_reviewBars3;
   string            m_csvFilename;
   int               m_csvHandle;
   bool              m_initialized;

   SPendingEntry     m_pending[];

   //---------------------------------------------------------------
   // Écrit l'en-tête CSV une seule fois (fichier neuf).
   //---------------------------------------------------------------
   void              WriteHeaderIfNeeded()
     {
      if(m_csvHandle == INVALID_HANDLE)
         return;
      if(FileSize(m_csvHandle) == 0)
        {
         FileWrite(m_csvHandle,
                  "SignalTime", "Symbole", "Signal", "Score", "Confiance",
                  "PrixAuSignal", "Execute",
                  StringFormat("Mouvement_%dBougies", m_reviewBars1),
                  StringFormat("Mouvement_%dBougies", m_reviewBars2),
                  StringFormat("Mouvement_%dBougies", m_reviewBars3));
         FileFlush(m_csvHandle);
        }
     }

   //---------------------------------------------------------------
   // Écrit une ligne CSV pour une entrée entièrement revue (les 3
   // fenêtres de revue sont complètes).
   //---------------------------------------------------------------
   void              WriteCompletedRow(const SPendingEntry &e)
     {
      if(m_csvHandle == INVALID_HANDLE)
         return;

      FileSeek(m_csvHandle, 0, SEEK_END);
      FileWrite(m_csvHandle,
               TimeToString(e.signalTime, TIME_DATE | TIME_MINUTES),
               m_symbol,
               CUtilities::SignalTypeToString(e.type),
               DoubleToString(e.score, 2),
               DoubleToString(e.confidence, 2),
               DoubleToString(e.priceAtSignal, 5),
               e.executed ? "OUI" : "NON",
               DoubleToString(e.move1, 5),
               DoubleToString(e.move2, 5),
               DoubleToString(e.move3, 5));
      FileFlush(m_csvHandle);
     }

   //---------------------------------------------------------------
   // Retire une entrée du tableau des entrées en attente (swap avec
   // la dernière puis réduction de taille - évite un décalage coûteux).
   //---------------------------------------------------------------
   void              RemovePendingAt(const int index)
     {
      int last = ArraySize(m_pending) - 1;
      if(index != last)
         m_pending[index] = m_pending[last];
      ArrayResize(m_pending, last);
     }

public:
                     CSignalRecorder()
     {
      m_symbol        = "";
      m_timeframe     = PERIOD_CURRENT;
      m_reviewBars1   = 10;
      m_reviewBars2   = 20;
      m_reviewBars3   = 50;
      m_csvFilename   = "NexusEdgeEA_SignalReview.csv";
      m_csvHandle     = INVALID_HANDLE;
      m_initialized   = false;
     }

                    ~CSignalRecorder()
     {
      Deinit();
     }

   //---------------------------------------------------------------
   // Initialise le recorder et ouvre le fichier CSV (mode append).
   //---------------------------------------------------------------
   bool              Init(const string symbol, const ENUM_TIMEFRAMES timeframe,
                          const int reviewBars1, const int reviewBars2, const int reviewBars3,
                          const string csvFilename = "NexusEdgeEA_SignalReview.csv")
     {
      m_symbol      = symbol;
      m_timeframe   = timeframe;
      m_reviewBars1 = reviewBars1;
      m_reviewBars2 = reviewBars2;
      m_reviewBars3 = reviewBars3;
      m_csvFilename = csvFilename;

      m_csvHandle = FileOpen(m_csvFilename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(m_csvHandle == INVALID_HANDLE)
        {
         Print("CSignalRecorder::Init - échec ouverture fichier : ", m_csvFilename, " (code ", GetLastError(), ")");
         return(false);
        }
      FileSeek(m_csvHandle, 0, SEEK_END);
      WriteHeaderIfNeeded();

      m_initialized = true;
      return(true);
     }

   void              Deinit()
     {
      if(m_csvHandle != INVALID_HANDLE)
        {
         FileClose(m_csvHandle);
         m_csvHandle = INVALID_HANDLE;
        }
      m_initialized = false;
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Enregistre un nouveau signal à suivre dans le temps. À appeler
   // pour TOUS les signaux (BUY/SELL/NONE), exécutés ou non - c'est
   // la donnée brute qui permettra de calibrer objectivement le
   // seuil de score et les filtres.
   //---------------------------------------------------------------
   void              RecordSignal(const SSignalResult &signal)
     {
      if(!m_initialized)
         return;

      SPendingEntry e;
      e.signalTime    = signal.time;
      e.type          = signal.type;
      e.score         = signal.score;
      e.confidence    = signal.confidence;
      e.priceAtSignal = signal.price;
      e.executed      = signal.executed;
      e.done1 = e.done2 = e.done3 = false;
      e.move1 = e.move2 = e.move3 = 0.0;

      int n = ArraySize(m_pending);
      ArrayResize(m_pending, n + 1);
      m_pending[n] = e;
     }

   //---------------------------------------------------------------
   // À appeler une fois par nouvelle bougie : vérifie si des entrées
   // en attente ont atteint une de leurs fenêtres de revue (10/20/50
   // bougies après le signal) et met à jour leur mouvement de prix.
   // Écrit la ligne CSV et libère l'entrée une fois les 3 fenêtres
   // complètes.
   //---------------------------------------------------------------
   void              Update()
     {
      if(!m_initialized)
         return;

      for(int i = ArraySize(m_pending) - 1; i >= 0; i--)
        {
         int barsElapsed = iBarShift(m_symbol, m_timeframe, m_pending[i].signalTime, false);
         if(barsElapsed < 0)
            continue; // Historique pas encore disponible pour cette date

         if(!m_pending[i].done1 && barsElapsed >= m_reviewBars1)
           {
            double priceThen = iClose(m_symbol, m_timeframe, MathMax(barsElapsed - m_reviewBars1, 0));
            m_pending[i].move1 = priceThen - m_pending[i].priceAtSignal;
            m_pending[i].done1 = true;
           }
         if(!m_pending[i].done2 && barsElapsed >= m_reviewBars2)
           {
            double priceThen = iClose(m_symbol, m_timeframe, MathMax(barsElapsed - m_reviewBars2, 0));
            m_pending[i].move2 = priceThen - m_pending[i].priceAtSignal;
            m_pending[i].done2 = true;
           }
         if(!m_pending[i].done3 && barsElapsed >= m_reviewBars3)
           {
            double priceThen = iClose(m_symbol, m_timeframe, MathMax(barsElapsed - m_reviewBars3, 0));
            m_pending[i].move3 = priceThen - m_pending[i].priceAtSignal;
            m_pending[i].done3 = true;
           }

         if(m_pending[i].done1 && m_pending[i].done2 && m_pending[i].done3)
           {
            WriteCompletedRow(m_pending[i]);
            RemovePendingAt(i);
           }
        }
     }

   int               GetPendingCount() const { return(ArraySize(m_pending)); }
  };

#endif // SIGNALRECORDER_MQH
//+------------------------------------------------------------------+
