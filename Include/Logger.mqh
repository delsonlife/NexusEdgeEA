//+------------------------------------------------------------------+
//|                                                     Logger.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Journalisation professionnelle de l'EA.             |
//|   Classe CLogger : écrit simultanément dans plusieurs formats de  |
//|   fichier :                                                        |
//|     - CSV  : historique des trades exécutés (une ligne/trade)    |
//|     - TXT  : journal texte horodaté (info/erreur/debug)          |
//|     - JSON : chaque décision/signal, exécuté ou non (JSON Lines) |
//|     - CSV  : snapshot marché complet à l'ouverture de chaque trade|
//|     - CSV  : événements chronologiques de la vie de chaque trade |
//|       (NOUVEAU - Phase 1)                                         |
//|     - CSV  : enregistrement complet par trade (ouverture + vie + |
//|       clôture en une seule ligne) (NOUVEAU - Phase 1)             |
//|     - CSV  : revue du marché après la clôture (NOUVEAU - Phase 1)|
//|                                                                    |
//|   Le format JSON est la base du futur AI/SignalRecorder.mqh :    |
//|   il permet d'analyser après coup quels signaux ont été rejetés  |
//|   et pourquoi, sans attendre le module AI complet.                |
//|                                                                    |
//| MODIFIÉ (Phase 1 - Instrumentation) :                             |
//|   - LogTrade() et LogTradeSnapshot() reçoivent désormais          |
//|     positionId, pour que TOUS les fichiers de sortie du projet    |
//|     partagent la même clé de corrélation.                         |
//|   - Trois nouvelles méthodes d'écriture, chacune déléguant à un   |
//|     nouveau fichier CSV dédié, sur le même modèle que l'existant. |
//|   - CDebug (Debug.mqh) reste le seul point d'entrée pour les logs |
//|     de debug catégorisés ; CLogger continue de fournir le socle   |
//|     d'écriture bas niveau, inchangé dans son fonctionnement.       |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef LOGGER_MQH
#define LOGGER_MQH

#include "Types.mqh"
#include "Utilities.mqh"

//+------------------------------------------------------------------+
//| Classe CLogger                                                      |
//+------------------------------------------------------------------+
class CLogger
  {
private:
   int              m_csvHandle;      // Handle fichier CSV (trades)
   int              m_txtHandle;      // Handle fichier TXT (logs)
   int              m_jsonHandle;     // Handle fichier JSON (décisions/signaux)
   int              m_snapshotHandle; // Handle fichier CSV (snapshot marché complet à chaque trade ouvert)
   int              m_eventsHandle;   // NOUVEAU - Handle fichier CSV (événements chronologiques de la vie d'un trade)
   int              m_fullHandle;     // NOUVEAU - Handle fichier CSV (enregistrement complet par trade)
   int              m_postCloseHandle;// NOUVEAU - Handle fichier CSV (revue du marché après clôture)
   int              m_systemEventsHandle; // NOUVEAU - Handle fichier CSV (evenements systeme : filtres, kill switch, pertes journalieres)
   int              m_debugPipelineHandle; // NOUVEAU (correctif diagnostic) - Handle fichier TXT temporaire de trace pipeline
   ENUM_LOG_LEVEL   m_logLevel;    // Niveau de log actif
   bool             m_initialized; // L'init a-t-elle réussi ?
   bool             m_enableDebugPipelineTxt; // NOUVEAU - active/desactive DebugPipeline.txt

   //---------------------------------------------------------------
   // Horodatage standard utilisé pour toutes les lignes de log.
   //---------------------------------------------------------------
   string            BuildTimestamp() const
     {
      return(TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
     }

   //---------------------------------------------------------------
   // Écrit une ligne dans le fichier TXT + la console "Experts",
   // en respectant le niveau de log configuré (InpLogLevel).
   //---------------------------------------------------------------
   void              WriteLog(const ENUM_LOG_LEVEL level, const string tag, const string message)
     {
      if(m_logLevel == LOG_LEVEL_NONE)
         return;
      if((int)level > (int)m_logLevel)
         return; // Le message est plus verbeux que le niveau autorisé

      string line = StringFormat("[%s] [%s] %s", BuildTimestamp(), tag, message);
      Print(line);

      if(m_txtHandle != INVALID_HANDLE)
        {
         FileSeek(m_txtHandle, 0, SEEK_END);
         FileWriteString(m_txtHandle, line + "\r\n");
         FileFlush(m_txtHandle);
        }
     }

public:
                     CLogger()
     {
      m_csvHandle       = INVALID_HANDLE;
      m_txtHandle       = INVALID_HANDLE;
      m_jsonHandle      = INVALID_HANDLE;
      m_snapshotHandle  = INVALID_HANDLE;
      m_eventsHandle    = INVALID_HANDLE;
      m_fullHandle      = INVALID_HANDLE;
      m_postCloseHandle = INVALID_HANDLE;
      m_systemEventsHandle = INVALID_HANDLE;
      m_debugPipelineHandle = INVALID_HANDLE;
      m_logLevel    = LOG_LEVEL_INFO;
      m_initialized = false;
      m_enableDebugPipelineTxt = true;
     }

                    ~CLogger()
     {
      Deinit();
     }

   //---------------------------------------------------------------
   // Initialise tous les fichiers de log. Les fichiers sont ouverts en
   // mode append (les données précédentes ne sont jamais écrasées),
   // et l'en-tête CSV n'est écrit qu'une seule fois (fichier neuf).
   // Les fichiers sont créés dans le dossier sandbox MQL5/Files/.
   //---------------------------------------------------------------
   bool              Init(const ENUM_LOG_LEVEL level = LOG_LEVEL_INFO, const string filePrefix = "NexusEdgeEA",
                          const bool enableDebugPipelineTxt = true)
     {
      m_logLevel = level;
      m_enableDebugPipelineTxt = enableDebugPipelineTxt;

      string safePrefix = filePrefix;
      StringReplace(safePrefix, " ", "_");

      string csvName  = safePrefix + "_Trades.csv";
      string txtName  = safePrefix + "_Log.txt";
      string jsonName = safePrefix + "_Decisions.json";

      bool csvAlreadyExists = FileIsExist(csvName);

      m_csvHandle = FileOpen(csvName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(m_csvHandle == INVALID_HANDLE)
        {
         Print("CLogger::Init - échec ouverture fichier CSV : ", csvName, " (code ", GetLastError(), ")");
         return(false);
        }
      FileSeek(m_csvHandle, 0, SEEK_END);
      if(!csvAlreadyExists || FileSize(m_csvHandle) == 0)
        {
         FileWrite(m_csvHandle,
                   "PositionId", "Date", "Heure", "Symbole", "Signal", "Score",
                   "Entree", "Sortie", "SL", "TP", "Gain", "Perte",
                   "Commentaires", "DureeSecondes", "CloseReason", "MFE", "MAE");
         FileFlush(m_csvHandle);
        }

      m_txtHandle = FileOpen(txtName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(m_txtHandle == INVALID_HANDLE)
        {
         Print("CLogger::Init - échec ouverture fichier TXT : ", txtName, " (code ", GetLastError(), ")");
         return(false);
        }
      FileSeek(m_txtHandle, 0, SEEK_END);

      m_jsonHandle = FileOpen(jsonName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(m_jsonHandle == INVALID_HANDLE)
        {
         Print("CLogger::Init - échec ouverture fichier JSON : ", jsonName, " (code ", GetLastError(), ")");
         return(false);
        }
      FileSeek(m_jsonHandle, 0, SEEK_END);

      string snapshotName = safePrefix + "_TradeSnapshots_v2.csv"; // NOUVEAU (correctif) - suffixe de version : voir explication en tete de section TradeFull ci-dessous
      bool snapshotAlreadyExists = FileIsExist(snapshotName);
      m_snapshotHandle = FileOpen(snapshotName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(m_snapshotHandle == INVALID_HANDLE)
        {
         Print("CLogger::Init - échec ouverture fichier Snapshot : ", snapshotName, " (code ", GetLastError(), ")");
         return(false);
        }
      FileSeek(m_snapshotHandle, 0, SEEK_END);
      if(!snapshotAlreadyExists || FileSize(m_snapshotHandle) == 0)
        {
         FileWrite(m_snapshotHandle,
                  "PositionId", "EntryTime", "Symbole", "Timeframe", "Signal",
                  "EMA_Rapide", "EMA_Lente", "RSI", "ATR", "Momentum",
                  "TrendState", "VolatilityState",
                  "Support", "Resistance", "DistSupport", "DistResistance",
                  "Pattern", "Breakout",
                  "ScoreBullish", "ScoreBearish", "ScoreThreshold",
                  "RR", "Lot", "Entry", "SL", "TP",
                  "FibNiveauProche", "FibDistancePoints", "FibDirectionImpulsion",
                  "StructureEvent", "SweepZone");
         FileFlush(m_snapshotHandle);
        }

      // --- NOUVEAU (Phase 1) : TradeEvents.csv ---
      string eventsName = safePrefix + "_TradeEvents.csv";
      bool eventsAlreadyExists = FileIsExist(eventsName);
      m_eventsHandle = FileOpen(eventsName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(m_eventsHandle == INVALID_HANDLE)
        {
         Print("CLogger::Init - échec ouverture fichier Events : ", eventsName, " (code ", GetLastError(), ")");
         return(false);
        }
      FileSeek(m_eventsHandle, 0, SEEK_END);
      if(!eventsAlreadyExists || FileSize(m_eventsHandle) == 0)
        {
         FileWrite(m_eventsHandle,
                  "PositionId", "Heure", "TypeEvenement", "Cause",
                  "AncienneValeur", "NouvelleValeur", "ProfitCourant", "Note");
         FileFlush(m_eventsHandle);
        }

      // --- NOUVEAU (Phase 1) : TradeFull.csv (une ligne = un trade complet) ---
      // CORRECTIF (schema drift) : suffixe "_v2" ajoute au nom de fichier.
      // Diagnostic confirme : ce fichier a change de nombre de colonnes a
      // plusieurs reprises au fil des livraisons (43 -> 50 -> 55 colonnes)
      // sans que l'ancien fichier CSV ne soit supprime entre deux tests -
      // l'en-tete (ecrit UNE SEULE FOIS a la creation) restait fige sur
      // l'ancien schema pendant que les lignes suivantes suivaient le
      // nouveau, produisant un CSV avec un nombre de colonnes incoherent
      // ligne par ligne. Verser le nom de fichier garantit qu'un futur
      // changement de schema cree un FICHIER NEUF plutot que de corrompre
      // l'existant. ACTION REQUISE : supprimer les anciens fichiers
      // NexusEdgeEA_TradeFull.csv / NexusEdgeEA_TradeSnapshots.csv restes
      // du dossier MQL5/Files avant le prochain test - ce correctif ne
      // repare pas retroactivement un fichier deja corrompu.
      string fullName = safePrefix + "_TradeFull_v3.csv"; // v2 -> v3 : ajout des colonnes Profit Guard
      bool fullAlreadyExists = FileIsExist(fullName);
      m_fullHandle = FileOpen(fullName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(m_fullHandle == INVALID_HANDLE)
        {
         Print("CLogger::Init - échec ouverture fichier TradeFull : ", fullName, " (code ", GetLastError(), ")");
         return(false);
        }
      FileSeek(m_fullHandle, 0, SEEK_END);
      if(!fullAlreadyExists || FileSize(m_fullHandle) == 0)
        {
         FileWrite(m_fullHandle,
                  "PositionId", "EntryTime", "Symbole", "Timeframe", "Signal",
                  "EntryPrice", "SLInitial", "TPInitial", "Lot", "RRPlanned",
                  "EMA_Rapide", "EMA_Lente", "RSI", "ATR", "Momentum",
                  "TrendState", "VolatilityState", "Support", "Resistance",
                  "DistSupport", "DistResistance", "Pattern", "Breakout",
                  "ScoreBullish", "ScoreBearish", "ScoreThreshold", "TradeQualityScore",
                  "FibNiveauProche", "FibDistancePoints", "FibDirectionImpulsion",
                  "StructureEvent", "SweepZone",
                  "MFE_Money", "MAE_Money_Heat", "TempsEnGainSec", "TempsEnPerteSec",
                  "NbModifSL", "NbModifSL_BreakEven", "NbModifSL_Trailing", "NbModifSL_ProfitGuard", "NbModifTP", "BreakEvenActiveA", "TrailingActiveA",
                  "ProfitGuardArmed", "ProfitGuardPeakProfitMoney", "ProfitGuardLastSource",
                  "NewsPendantTradeCount", "NewsPendantTradeDetail",
                  "ExitPrice", "ProfitFinal", "CloseTime", "DureeSecondes",
                  "CloseReasonBrut", "CloseReasonDetaille",
                  "CaptureRatioPercent", "ProfitLaisseSurLaTable",
                  "RR_Obtenu", "ProfitPercent", "NbPartials");
         FileFlush(m_fullHandle);
        }

      // --- NOUVEAU (Phase 1) : PostCloseReview.csv ---
      string postCloseName = safePrefix + "_PostCloseReview.csv";
      bool postCloseAlreadyExists = FileIsExist(postCloseName);
      m_postCloseHandle = FileOpen(postCloseName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(m_postCloseHandle == INVALID_HANDLE)
        {
         Print("CLogger::Init - échec ouverture fichier PostCloseReview : ", postCloseName, " (code ", GetLastError(), ")");
         return(false);
        }
      FileSeek(m_postCloseHandle, 0, SEEK_END);
      if(!postCloseAlreadyExists || FileSize(m_postCloseHandle) == 0)
        {
         FileWrite(m_postCloseHandle,
                  "PositionId", "Symbole", "Signal", "ExitPrice", "ExitProfitMoney", "ExitTime",
                  "Mouvement_5min", "Mouvement_15min", "Mouvement_30min", "Mouvement_1h", "Mouvement_4h");
         FileFlush(m_postCloseHandle);
        }

      // --- NOUVEAU (correctif journalisation) : SystemEvents.csv.
      // Événements SYSTÈME, pas liés à un trade précis (donc pas de
      // positionId) : blocages de filtres (session/spread/news/...),
      // arrêts de sécurité (perte/gain journalier, pertes
      // consécutives = "kill switch"). Ces événements étaient déjà
      // comptés par CDiagnostics et parfois affichés en texte, mais
      // JAMAIS écrits systématiquement dans un fichier structuré et
      // horodaté, indépendamment de InpDebugPipeline. C'est le trou
      // que ce fichier comble.
      string systemEventsName = safePrefix + "_SystemEvents.csv";
      bool systemEventsAlreadyExists = FileIsExist(systemEventsName);
      m_systemEventsHandle = FileOpen(systemEventsName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(m_systemEventsHandle == INVALID_HANDLE)
        {
         Print("CLogger::Init - échec ouverture fichier SystemEvents : ", systemEventsName, " (code ", GetLastError(), ")");
         return(false);
        }
      FileSeek(m_systemEventsHandle, 0, SEEK_END);
      if(!systemEventsAlreadyExists || FileSize(m_systemEventsHandle) == 0)
        {
         FileWrite(m_systemEventsHandle, "Timestamp", "Categorie", "Message");
         FileFlush(m_systemEventsHandle);
        }

      // --- NOUVEAU (correctif diagnostic, demande explicite) : DebugPipeline.txt.
      // Fichier TEMPORAIRE (écrasé à chaque démarrage de l'EA, contrairement
      // aux CSV qui restent le format final d'analyse en mode append) :
      // trace texte brute du parcours d'une donnée à travers TradeManager
      // -> TradeLifecycleTracker -> STradeFullRecord -> Logger -> CSV.
      // Non bloquant si l'ouverture échoue (Print un avertissement mais ne
      // fait pas échouer Init() - c'est un outil de diagnostic, pas une
      // donnée d'analyse, il ne doit jamais empêcher l'EA de démarrer).
      if(m_enableDebugPipelineTxt)
        {
         string debugPipelineName = safePrefix + "_DebugPipeline.txt";
         m_debugPipelineHandle = FileOpen(debugPipelineName, FILE_WRITE | FILE_TXT | FILE_ANSI); // FILE_WRITE seul = écrase le fichier précédent
         if(m_debugPipelineHandle == INVALID_HANDLE)
            Print("CLogger::Init - échec ouverture fichier DebugPipeline (non bloquant) : ", debugPipelineName, " (code ", GetLastError(), ")");
        }

      m_initialized = true;
      LogInfo(StringFormat("Logger initialisé (niveau=%s, fichiers=%s/%s/%s + TradeEvents/TradeFull/PostCloseReview/SystemEvents%s)",
                           EnumToString(m_logLevel), csvName, txtName, jsonName,
                           (m_debugPipelineHandle != INVALID_HANDLE) ? "/DebugPipeline" : ""));
      return(true);
     }

   //---------------------------------------------------------------
   // Ferme proprement tous les handles de fichiers.
   //---------------------------------------------------------------
   void              Deinit()
     {
      if(m_csvHandle != INVALID_HANDLE)
        {
         FileClose(m_csvHandle);
         m_csvHandle = INVALID_HANDLE;
        }
      if(m_txtHandle != INVALID_HANDLE)
        {
         FileClose(m_txtHandle);
         m_txtHandle = INVALID_HANDLE;
        }
      if(m_jsonHandle != INVALID_HANDLE)
        {
         FileClose(m_jsonHandle);
         m_jsonHandle = INVALID_HANDLE;
        }
      if(m_snapshotHandle != INVALID_HANDLE)
        {
         FileClose(m_snapshotHandle);
         m_snapshotHandle = INVALID_HANDLE;
        }
      if(m_eventsHandle != INVALID_HANDLE)
        {
         FileClose(m_eventsHandle);
         m_eventsHandle = INVALID_HANDLE;
        }
      if(m_fullHandle != INVALID_HANDLE)
        {
         FileClose(m_fullHandle);
         m_fullHandle = INVALID_HANDLE;
        }
      if(m_postCloseHandle != INVALID_HANDLE)
        {
         FileClose(m_postCloseHandle);
         m_postCloseHandle = INVALID_HANDLE;
        }
      if(m_systemEventsHandle != INVALID_HANDLE)
        {
         FileClose(m_systemEventsHandle);
         m_systemEventsHandle = INVALID_HANDLE;
        }
      if(m_debugPipelineHandle != INVALID_HANDLE)
        {
         FileClose(m_debugPipelineHandle);
         m_debugPipelineHandle = INVALID_HANDLE;
        }
      m_initialized = false;
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Méthodes de log texte, filtrées par niveau (InpLogLevel).
   //---------------------------------------------------------------
   void              LogError(const string message) { WriteLog(LOG_LEVEL_ERROR, "ERROR", message); }
   void              LogInfo(const string message)   { WriteLog(LOG_LEVEL_INFO,  "INFO",  message); }
   void              LogDebug(const string message)  { WriteLog(LOG_LEVEL_DEBUG, "DEBUG", message); }

   //---------------------------------------------------------------
   // Enregistre un trade réellement exécuté et clôturé dans le CSV.
   // Une ligne = un trade complet, avec toutes les colonnes du
   // cahier des charges (Date, Heure, Symbole, Signal, Score,
   // Entrée, Sortie, SL, TP, Gain, Perte, Commentaires, Durée).
   //
   // MODIFIÉ (Phase 1) : ajout de positionId (première colonne), pour
   // permettre la corrélation avec TradeSnapshots/TradeEvents/TradeFull.
   //---------------------------------------------------------------
   void              LogTrade(const ulong positionId, const string symbol, const ENUM_SIGNAL_TYPE signal, const double score,
                              const double entryPrice, const double exitPrice,
                              const double sl, const double tp,
                              const double profit, const double loss,
                              const string comment, const int durationSeconds,
                              const string closeReason = "", const double mfe = 0.0, const double mae = 0.0)
     {
      if(m_csvHandle == INVALID_HANDLE)
         return;

      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

      FileSeek(m_csvHandle, 0, SEEK_END);
      FileWrite(m_csvHandle,
               IntegerToString((long)positionId),
               TimeToString(TimeCurrent(), TIME_DATE),
               TimeToString(TimeCurrent(), TIME_MINUTES | TIME_SECONDS),
               symbol,
               CUtilities::SignalTypeToString(signal),
               DoubleToString(score, 2),
               DoubleToString(entryPrice, digits),
               DoubleToString(exitPrice, digits),
               DoubleToString(sl, digits),
               DoubleToString(tp, digits),
               DoubleToString(profit, 2),
               DoubleToString(loss, 2),
               comment,
               IntegerToString(durationSeconds),
               closeReason,
               DoubleToString(mfe, digits),
               DoubleToString(mae, digits));
      FileFlush(m_csvHandle);

      LogInfo(StringFormat(
         "TRADE CLOSED : positionId=%I64u %s %s | Resultat=%s | Raison=%s | Profit=%.2f | Duree=%ds | MFE=%.5f | MAE=%.5f",
         positionId, symbol, CUtilities::SignalTypeToString(signal),
         (profit > 0.0) ? "WIN" : "LOSS",
         closeReason, profit, durationSeconds, mfe, mae));
     }

   //---------------------------------------------------------------
   // Enregistre CHAQUE décision/signal détecté par CSignalManager,
   // qu'il ait été exécuté ou non, au format JSON Lines (1 objet
   // JSON par ligne). C'est cette méthode qui doit être appelée à
   // CHAQUE nouvelle bougie analysée, quel que soit le résultat.
   //---------------------------------------------------------------
   void              LogDecision(const SSignalResult &signal, const string symbol)
     {
      if(m_jsonHandle == INVALID_HANDLE)
         return;

      string reasonEscaped = signal.reason;
      StringReplace(reasonEscaped, "\\", "\\\\");
      StringReplace(reasonEscaped, "\"", "'");
      StringReplace(reasonEscaped, "\r\n", "\\n");
      StringReplace(reasonEscaped, "\n", "\\n");

      string json = StringFormat(
         "{\"time\":\"%s\",\"symbol\":\"%s\",\"signal\":\"%s\",\"score\":%.2f,\"confidence\":%.2f,\"price\":%.5f,\"executed\":%s,\"reason\":\"%s\"}",
         TimeToString(signal.time, TIME_DATE | TIME_SECONDS),
         symbol,
         CUtilities::SignalTypeToString(signal.type),
         signal.score,
         signal.confidence,
         signal.price,
         (signal.executed ? "true" : "false"),
         reasonEscaped);

      FileSeek(m_jsonHandle, 0, SEEK_END);
      FileWriteString(m_jsonHandle, json + "\r\n");
      FileFlush(m_jsonHandle);
     }

   //---------------------------------------------------------------
   // Enregistre un snapshot complet du contexte marché au moment de
   // l'ouverture d'un trade (point 3 du cahier des charges "laboratoire
   // d'analyse"). Permet une analyse statistique après plusieurs
   // centaines d'exécutions, dans un fichier CSV dédié.
   //
   // MODIFIÉ (Phase 1) : positionId ajouté en première colonne (le
   // champ existe désormais dans STradeSnapshot - voir Types.mqh).
   //---------------------------------------------------------------
   void              LogTradeSnapshot(const STradeSnapshot &snap)
     {
      if(m_snapshotHandle == INVALID_HANDLE)
         return;

      int digits = (int)SymbolInfoInteger(snap.symbol, SYMBOL_DIGITS);

      FileSeek(m_snapshotHandle, 0, SEEK_END);
      FileWrite(m_snapshotHandle,
               IntegerToString((long)snap.positionId),
               TimeToString(snap.entryTime, TIME_DATE | TIME_SECONDS),
               snap.symbol,
               EnumToString(snap.timeframe),
               CUtilities::SignalTypeToString(snap.signalType),
               DoubleToString(snap.emaFast, digits),
               DoubleToString(snap.emaSlow, digits),
               DoubleToString(snap.rsi, 2),
               DoubleToString(snap.atr, digits),
               DoubleToString(snap.momentum, 2),
               CUtilities::TrendStateToString(snap.trendState),
               CUtilities::VolatilityStateToString(snap.volatilityState),
               DoubleToString(snap.nearestSupport, digits),
               DoubleToString(snap.nearestResistance, digits),
               DoubleToString(snap.distanceToSupport, digits),
               DoubleToString(snap.distanceToResistance, digits),
               snap.patternDescription,
               EnumToString(snap.breakoutState),
               DoubleToString(snap.scoreBullish, 2),
               DoubleToString(snap.scoreBearish, 2),
               DoubleToString(snap.scoreThreshold, 2),
               DoubleToString(snap.rr, 2),
               DoubleToString(snap.lot, 2),
               DoubleToString(snap.entryPrice, digits),
               DoubleToString(snap.slPrice, digits),
               DoubleToString(snap.tpPrice, digits),
               snap.fibNearestLevel,
               DoubleToString(snap.fibDistancePoints, 1),
               snap.fibLegDirection,
               snap.structureEvent,
               snap.sweepZone);
      FileFlush(m_snapshotHandle);
     }

   //---------------------------------------------------------------
   // NOUVEAU (Phase 1). Enregistre UN événement de la vie d'un trade
   // (SPositionEvent, produit par CTradeLifecycleTracker). Une ligne
   // par événement - à appeler en boucle par l'orchestrateur pour
   // tous les événements d'un trade fraîchement clôturé, avant que
   // CTradeLifecycleTracker::ReleasePosition() ne les libère.
   //
   // MODIFIÉ (correctif diagnostic, demande explicite) : retourne
   // désormais un VRAI succès/échec (au lieu d'un void supposé
   // toujours réussi). errorCodeOut est rempli avec GetLastError()
   // en cas d'échec réel d'écriture (0 si succès, ou un code dédié
   // si le handle est simplement invalide - cas différent d'un échec
   // d'écriture MT5, distingué explicitement).
   //---------------------------------------------------------------
   bool              LogTradeEvent(const SPositionEvent &ev, int &errorCodeOut)
     {
      errorCodeOut = 0;
      if(m_eventsHandle == INVALID_HANDLE)
        {
         errorCodeOut = -1; // Convention interne : handle jamais ouvert (pas un code GetLastError() MT5)
         return(false);
        }

      FileSeek(m_eventsHandle, 0, SEEK_END);
      uint written = FileWrite(m_eventsHandle,
               IntegerToString((long)ev.positionId),
               TimeToString(ev.time, TIME_DATE | TIME_SECONDS),
               EnumToString(ev.eventType),
               ev.cause,
               DoubleToString(ev.previousValue, 5),
               DoubleToString(ev.newValue, 5),
               DoubleToString(ev.currentProfit, 2),
               ev.note);
      if(written == 0)
        {
         errorCodeOut = GetLastError();
         return(false);
        }
      FileFlush(m_eventsHandle);
      return(true);
     }

   //---------------------------------------------------------------
   // NOUVEAU (Phase 1). Enregistre l'enregistrement COMPLET d'un trade
   // (STradeFullRecord : ouverture + vie + clôture réunies) - UNE
   // SEULE ligne par trade, pensée pour être directement exploitable
   // dans Excel/Python sans jointure entre plusieurs fichiers.
   //
   // MODIFIÉ (correctif diagnostic, demande explicite) : même principe
   // que LogTradeEvent() ci-dessus - retour bool réel + code d'erreur.
   //---------------------------------------------------------------
   bool              LogTradeFull(const STradeFullRecord &rec, int &errorCodeOut)
     {
      errorCodeOut = 0;
      if(m_fullHandle == INVALID_HANDLE)
        {
         errorCodeOut = -1; // Convention interne : handle jamais ouvert
         return(false);
        }

      int digits = (int)SymbolInfoInteger(rec.symbol, SYMBOL_DIGITS);

      FileSeek(m_fullHandle, 0, SEEK_END);
      uint written = FileWrite(m_fullHandle,
               IntegerToString((long)rec.positionId),
               TimeToString(rec.entryTime, TIME_DATE | TIME_SECONDS),
               rec.symbol,
               EnumToString(rec.timeframe),
               CUtilities::SignalTypeToString(rec.signalType),
               DoubleToString(rec.entryPrice, digits),
               DoubleToString(rec.slInitial, digits),
               DoubleToString(rec.tpInitial, digits),
               DoubleToString(rec.lot, 2),
               DoubleToString(rec.rrPlanned, 2),
               DoubleToString(rec.emaFast, digits),
               DoubleToString(rec.emaSlow, digits),
               DoubleToString(rec.rsi, 2),
               DoubleToString(rec.atr, digits),
               DoubleToString(rec.momentum, 2),
               CUtilities::TrendStateToString(rec.trendState),
               CUtilities::VolatilityStateToString(rec.volatilityState),
               DoubleToString(rec.nearestSupport, digits),
               DoubleToString(rec.nearestResistance, digits),
               DoubleToString(rec.distanceToSupport, digits),
               DoubleToString(rec.distanceToResistance, digits),
               rec.patternDescription,
               EnumToString(rec.breakoutState),
               DoubleToString(rec.scoreBullish, 2),
               DoubleToString(rec.scoreBearish, 2),
               DoubleToString(rec.scoreThreshold, 2),
               DoubleToString(rec.tradeQualityScore, 1),
               rec.fibNearestLevel,
               DoubleToString(rec.fibDistancePoints, 1),
               rec.fibLegDirection,
               rec.structureEvent,
               rec.sweepZone,
               DoubleToString(rec.mfeMoney, 2),
               DoubleToString(rec.maeMoney, 2),
               IntegerToString(rec.timeInProfitSec),
               IntegerToString(rec.timeInLossSec),
               IntegerToString(rec.slModificationCount),
               IntegerToString(rec.slModificationCountBreakEven),
               IntegerToString(rec.slModificationCountTrailing),
               IntegerToString(rec.slModificationCountProfitGuard),
               IntegerToString(rec.tpModificationCount),
               (rec.breakEvenActivatedTime > 0) ? TimeToString(rec.breakEvenActivatedTime, TIME_DATE | TIME_SECONDS) : "Non",
               (rec.trailingActivatedTime > 0) ? TimeToString(rec.trailingActivatedTime, TIME_DATE | TIME_SECONDS) : "Non",
               rec.profitGuardArmed ? "Oui" : "Non",
               DoubleToString(rec.profitGuardPeakProfitMoney, 2),
               rec.profitGuardLastSource,
               IntegerToString(rec.newsDuringTradeCount),
               rec.newsDuringTradeLastDetail,
               DoubleToString(rec.exitPrice, digits),
               DoubleToString(rec.profitFinal, 2),
               TimeToString(rec.closeTime, TIME_DATE | TIME_SECONDS),
               IntegerToString(rec.durationSeconds),
               rec.closeReasonRaw,
               rec.closeReasonDetailed,
               DoubleToString(rec.captureRatioPercent, 1),
               DoubleToString(rec.profitLeftOnTable, 2),
               DoubleToString(rec.rrRealized, 2),
               DoubleToString(rec.profitPercent, 2),
               IntegerToString(rec.partialCloseCount));
      if(written == 0)
        {
         errorCodeOut = GetLastError();
         return(false);
        }
      FileFlush(m_fullHandle);
      return(true);
     }

   //---------------------------------------------------------------
   // NOUVEAU (Phase 1). Enregistre une revue post-clôture complète
   // (SPostCloseReview, produite par CPostCloseWatcher une fois les 5
   // fenêtres temporelles atteintes).
   //---------------------------------------------------------------
   void              LogPostCloseReview(const SPostCloseReview &review)
     {
      if(m_postCloseHandle == INVALID_HANDLE)
         return;

      int digits = (int)SymbolInfoInteger(review.symbol, SYMBOL_DIGITS);

      FileSeek(m_postCloseHandle, 0, SEEK_END);
      FileWrite(m_postCloseHandle,
               IntegerToString((long)review.positionId),
               review.symbol,
               CUtilities::SignalTypeToString(review.type),
               DoubleToString(review.exitPrice, digits),
               DoubleToString(review.exitProfitMoney, 2),
               TimeToString(review.exitTime, TIME_DATE | TIME_SECONDS),
               DoubleToString(review.move5min, digits),
               DoubleToString(review.move15min, digits),
               DoubleToString(review.move30min, digits),
               DoubleToString(review.move1h, digits),
               DoubleToString(review.move4h, digits));
      FileFlush(m_postCloseHandle);
     }

   //---------------------------------------------------------------
   // NOUVEAU (correctif journalisation). Enregistre un événement
   // SYSTÈME (pas lié à un trade précis) : blocage de filtre, arrêt
   // de sécurité journalier, kill switch (pertes consécutives), etc.
   // Écrit à la fois dans SystemEvents.csv (structuré) ET dans le
   // journal TXT (via LogInfo, déjà horodaté) - un seul appel suffit
   // à l'appelant, pas besoin d'appeler LogInfo() séparément.
   //---------------------------------------------------------------
   void              LogSystemEvent(const string category, const string message)
     {
      if(m_systemEventsHandle != INVALID_HANDLE)
        {
         FileSeek(m_systemEventsHandle, 0, SEEK_END);
         FileWrite(m_systemEventsHandle, BuildTimestamp(), category, message);
         FileFlush(m_systemEventsHandle);
        }
      LogInfo(StringFormat("[%s] %s", category, message));
     }

   //---------------------------------------------------------------
   // NOUVEAU (correctif diagnostic, demande explicite). Écrit un bloc
   // de trace brut dans DebugPipeline.txt. N'écrit RIEN ailleurs (pas
   // dans le TXT principal, pas dans la console) - ce fichier est
   // volontairement séparé pour ne pas polluer les logs normaux avec
   // du détail de diagnostic temporaire. Sans effet si le fichier n'a
   // pas pu s'ouvrir (InpEnableDebugPipelineTxt=false ou échec
   // d'ouverture) - jamais bloquant.
   //---------------------------------------------------------------
   void              LogPipelineDebug(const string block)
     {
      if(m_debugPipelineHandle == INVALID_HANDLE)
         return;
      FileSeek(m_debugPipelineHandle, 0, SEEK_END);
      FileWriteString(m_debugPipelineHandle, StringFormat("[%s] ", BuildTimestamp()) + block + "\r\n");
      FileFlush(m_debugPipelineHandle);
     }
  };

#endif // LOGGER_MQH
//+------------------------------------------------------------------+
