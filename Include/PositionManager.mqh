//+------------------------------------------------------------------+
//|                                              PositionManager.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Suivi de l'historique des positions clôturées.     |
//|   CPositionManager reconstruit chaque trade complet à partir de   |
//|   l'historique des deals MT5 (HistorySelect/HistoryDealGet...),   |
//|   plutôt que de tenir un journal manuel parallèle - c'est la      |
//|   source de vérité du broker, donc exacte y compris en cas de     |
//|   fermeture partielle, swap, commission.                          |
//|                                                                    |
//|   LIMITE CONNUE : le RR réalisé est calculé à partir du SL de     |
//|   l'ORDRE D'ENTRÉE initial (ORDER_SL), qui ne reflète pas les      |
//|   ajustements ultérieurs (Break Even, Trailing). C'est une        |
//|   approximation assumée et documentée, pas une erreur silencieuse.|
//|                                                                    |
//| MODIFIÉ (correctif "doublons au redémarrage", diagnostiqué le     |
//|   2026-07-17 par analyse des CSV réels - PositionId identiques    |
//|   répétés plusieurs fois dans TradeFull.csv) :                     |
//|                                                                    |
//|   AVANT : m_processedPositionIds[] n'existait qu'en mémoire. À    |
//|   chaque redémarrage de l'EA (recompilation, coupure réseau       |
//|   relançant le terminal, etc.), ce tableau repartait vide, alors  |
//|   que Update() rescanne systématiquement une fenêtre glissante de |
//|   30 jours d'historique (m_lastSyncTime par défaut). Résultat :   |
//|   les trades déjà journalisés dans une session précédente étaient |
//|   "redécouverts" comme nouveaux et rejournalisés à l'identique -  |
//|   d'où les lignes dupliquées observées dans TradeFull.csv.        |
//|                                                                    |
//|   APRÈS : la liste des positions déjà traitées est persistée dans |
//|   un petit fichier dédié (une ligne = un positionId), rechargée   |
//|   au démarrage (Init) et mise à jour à chaque nouveau trade       |
//|   traité (MarkProcessed). Un trade déjà journalisé avant l'arrêt  |
//|   de l'EA reste donc marqué comme tel après un redémarrage.        |
//|                                                                    |
//|   AUCUNE logique de reconstruction de trade (BuildRecordFromPosition,|
//|   calcul MFE/MAE/RR) n'a été modifiée - uniquement la persistance |
//|   de la déduplication, conformément à "ne modifier aucune logique |
//|   de trading, uniquement le système de journalisation".            |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef POSITIONMANAGER_MQH
#define POSITIONMANAGER_MQH

#include "Types.mqh"
#include "Utilities.mqh"

//+------------------------------------------------------------------+
//| Classe CPositionManager                                              |
//+------------------------------------------------------------------+
class CPositionManager
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   long              m_magicNumber;
   bool              m_initialized;

   SPositionRecord   m_records[];
   datetime          m_lastSyncTime;
   ulong             m_processedPositionIds[]; // Évite d'enregistrer deux fois la même position (en mémoire, session courante)
   string            m_persistFilename;         // NOUVEAU - persistance disque de m_processedPositionIds entre sessions

   //---------------------------------------------------------------
   // Vérifie si une position (POSITION_ID) a déjà été enregistrée.
   //---------------------------------------------------------------
   bool              AlreadyProcessed(const ulong positionId) const
     {
      int total = ArraySize(m_processedPositionIds);
      for(int i = 0; i < total; i++)
        {
         if(m_processedPositionIds[i] == positionId)
            return(true);
        }
      return(false);
     }

   void              MarkProcessed(const ulong positionId)
     {
      int n = ArraySize(m_processedPositionIds);
      ArrayResize(m_processedPositionIds, n + 1);
      m_processedPositionIds[n] = positionId;
      PersistProcessedId(positionId); // NOUVEAU - écrit immédiatement sur disque
     }

   //---------------------------------------------------------------
   // NOUVEAU (correctif doublons). Recharge la liste des positions
   // déjà traitées depuis le fichier de persistance, au démarrage.
   // Si le fichier n'existe pas encore (toute première exécution de
   // l'EA sur ce symbole/magic), ne fait rien - comportement identique
   // à avant le correctif (liste vide au départ).
   //---------------------------------------------------------------
   void              LoadProcessedIds()
     {
      if(!FileIsExist(m_persistFilename))
         return;

      int handle = FileOpen(m_persistFilename, FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle == INVALID_HANDLE)
        {
         Print("CPositionManager::LoadProcessedIds - échec ouverture ", m_persistFilename, " (code ", GetLastError(), ") - demarrage avec liste vide");
         return;
        }

      int loadedCount = 0;
      while(!FileIsEnding(handle))
        {
         string line = FileReadString(handle);
         if(line == "")
            continue;
         ulong id = (ulong)StringToInteger(line);
         if(id > 0 && !AlreadyProcessed(id))
           {
            int n = ArraySize(m_processedPositionIds);
            ArrayResize(m_processedPositionIds, n + 1);
            m_processedPositionIds[n] = id;
            loadedCount++;
           }
        }
      FileClose(handle);
      PrintFormat("CPositionManager::LoadProcessedIds - %d position(s) deja traitee(s) rechargee(s) depuis %s", loadedCount, m_persistFilename);
     }

   //---------------------------------------------------------------
   // NOUVEAU (correctif doublons). Ajoute UN positionId au fichier de
   // persistance (mode append - jamais de réécriture complète, donc
   // coût négligeable même après des milliers de trades).
   //---------------------------------------------------------------
   void              PersistProcessedId(const ulong positionId)
     {
      int handle = FileOpen(m_persistFilename, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(handle == INVALID_HANDLE)
        {
         Print("CPositionManager::PersistProcessedId - échec ouverture ", m_persistFilename, " (code ", GetLastError(), ")");
         return;
        }
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, IntegerToString((long)positionId) + "\r\n");
      FileClose(handle);
     }

   //---------------------------------------------------------------
   // Traduit le DEAL_REASON du deal de sortie en une raison lisible.
   // LIMITE DOCUMENTÉE : MT5 ne distingue pas nativement "SL initial"
   // de "SL déplacé par Break Even/Trailing" - les deux remontent en
   // DEAL_REASON_SL. De même, une fermeture forcée par le stop
   // journalier (CloseAllPositions) et une fermeture partielle
   // manuelle via code remontent toutes deux en DEAL_REASON_EXPERT.
   // C'est une limite du terminal, pas de notre code - restituée
   // telle quelle plutôt que masquée.
   //---------------------------------------------------------------
   string            MapCloseReason(const ENUM_DEAL_REASON reason) const
     {
      switch(reason)
        {
         case DEAL_REASON_TP:     return("TP atteint");
         case DEAL_REASON_SL:     return("SL atteint (initial ou ajuste par BreakEven/Trailing)");
         case DEAL_REASON_SO:     return("Stop Out (marge insuffisante)");
         case DEAL_REASON_EXPERT: return("Fermeture par l'EA (CloseAll / partielle / logique programmee)");
         case DEAL_REASON_CLIENT: return("Fermeture manuelle (terminal)");
         case DEAL_REASON_MOBILE: return("Fermeture manuelle (mobile)");
         case DEAL_REASON_WEB:    return("Fermeture manuelle (web)");
         default:                 return("Autre (DEAL_REASON=" + EnumToString(reason) + ")");
        }
     }

   //---------------------------------------------------------------
   // Calcule le MFE (Maximum Favorable Excursion) et le MAE (Maximum
   // Adverse Excursion) en scannant les bougies entre l'ouverture et
   // la clôture du trade. Permet de savoir après coup si le SL était
   // trop serré (MAE proche du SL sans jamais y toucher) ou si le TP
   // était trop ambitieux (MFE n'atteint jamais le TP).
   //---------------------------------------------------------------
   void              CalculateExcursions(const datetime openTime, const datetime closeTime,
                                         const double entryPrice, const ENUM_SIGNAL_TYPE type,
                                         double &mfeOut, double &maeOut) const
     {
      mfeOut = 0.0;
      maeOut = 0.0;

      if(closeTime <= openTime)
         return;

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(m_symbol, m_timeframe, openTime, closeTime, rates);
      if(copied <= 0)
         return; // Historique indisponible pour cette fenêtre - MFE/MAE restent à 0 (signale l'absence de donnee)

      double bestFavorable = entryPrice;
      double worstAdverse  = entryPrice;

      for(int i = 0; i < copied; i++)
        {
         if(type == SIGNAL_BUY)
           {
            if(rates[i].high > bestFavorable) bestFavorable = rates[i].high;
            if(rates[i].low  < worstAdverse)   worstAdverse  = rates[i].low;
           }
         else
           {
            if(rates[i].low  < bestFavorable)  bestFavorable = rates[i].low;
            if(rates[i].high > worstAdverse)    worstAdverse  = rates[i].high;
           }
        }

      mfeOut = MathAbs(bestFavorable - entryPrice);
      maeOut = MathAbs(entryPrice - worstAdverse);
     }

   //---------------------------------------------------------------
   // Reconstruit un SPositionRecord complet pour une position donnée
   // (via son POSITION_ID), en scannant tous les deals qui lui sont
   // rattachés (HistorySelectByPosition).
   //---------------------------------------------------------------
   bool              BuildRecordFromPosition(const ulong positionId, SPositionRecord &recordOut)
     {
      if(!HistorySelectByPosition((long)positionId))
         return(false);

      int dealsTotal = HistoryDealsTotal();
      if(dealsTotal <= 0)
         return(false);

      bool foundEntry = false;
      bool foundExit   = false;

      double entryPrice = 0.0;
      double exitPrice  = 0.0;
      datetime openTime  = 0;
      datetime closeTime = 0;
      double totalProfit = 0.0;
      double totalVolume = 0.0;
      ENUM_SIGNAL_TYPE type = SIGNAL_NONE;
      long entryOrderTicket = 0;
      ENUM_DEAL_REASON exitReason = DEAL_REASON_CLIENT;

      for(int i = 0; i < dealsTotal; i++)
        {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0)
            continue;

         long entryFlag = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         totalProfit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                      + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                      + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

         if(entryFlag == DEAL_ENTRY_IN)
           {
            entryPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            openTime   = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
            entryOrderTicket = (long)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
            totalVolume += HistoryDealGetDouble(dealTicket, DEAL_VOLUME);

            ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
            type = (dealType == DEAL_TYPE_BUY) ? SIGNAL_BUY : SIGNAL_SELL;
            foundEntry = true;
           }
         else if(entryFlag == DEAL_ENTRY_OUT || entryFlag == DEAL_ENTRY_OUT_BY)
           {
            exitPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            closeTime  = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
            exitReason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
            foundExit  = true;
           }
        }

      if(!foundEntry || !foundExit)
         return(false); // Position pas encore totalement clôturée ou historique incomplet

      recordOut.positionId      = positionId;
      recordOut.symbol          = m_symbol;
      recordOut.type            = type;
      recordOut.volume          = totalVolume;
      recordOut.entryPrice      = entryPrice;
      recordOut.exitPrice       = exitPrice;
      recordOut.profit          = totalProfit;
      recordOut.openTime        = openTime;
      recordOut.closeTime       = closeTime;
      recordOut.durationSeconds = (int)(closeTime - openTime);
      recordOut.closeReason     = MapCloseReason(exitReason);

      double mfe = 0.0, mae = 0.0;
      CalculateExcursions(openTime, closeTime, entryPrice, type, mfe, mae);
      recordOut.mfe = mfe;
      recordOut.mae = mae;

      // RR approximatif basé sur le SL initial de l'ordre d'entrée
      // (voir limite documentée en tête de fichier)
      double initialSL = 0.0;
      if(entryOrderTicket > 0 && HistoryOrderSelect((ulong)entryOrderTicket))
         initialSL = HistoryOrderGetDouble((ulong)entryOrderTicket, ORDER_SL);

      if(initialSL > 0.0)
        {
         double riskDistance   = MathAbs(entryPrice - initialSL);
         double rewardDistance = MathAbs(exitPrice - entryPrice);
         recordOut.rr = CUtilities::SafeDivide(rewardDistance, riskDistance, 0.0);
        }
      else
         recordOut.rr = 0.0;

      return(true);
     }

public:
                     CPositionManager()
     {
      m_symbol       = "";
      m_timeframe    = PERIOD_CURRENT;
      m_magicNumber  = 0;
      m_initialized  = false;
      m_lastSyncTime = 0;
      m_persistFilename = "";
     }

   //---------------------------------------------------------------
   // Initialise le module. historyStartTime définit le point de
   // départ de l'historique à considérer (ex : début du backtest ou
   // date de mise en service du robot).
   //
   // MODIFIÉ (correctif doublons) : recharge automatiquement la liste
   // des positions déjà traitées depuis le fichier de persistance.
   //---------------------------------------------------------------
   bool              Init(const string symbol, const ENUM_TIMEFRAMES timeframe, const long magicNumber, const datetime historyStartTime = 0)
     {
      m_symbol      = symbol;
      m_timeframe   = timeframe;
      m_magicNumber = magicNumber;
      m_lastSyncTime = (historyStartTime > 0) ? historyStartTime : (TimeCurrent() - 30 * 86400);

      string safeSymbol = symbol;
      StringReplace(safeSymbol, ".", "_");
      m_persistFilename = StringFormat("NexusEdgeEA_ProcessedPositions_%s_%d.dat", safeSymbol, magicNumber);
      LoadProcessedIds(); // NOUVEAU - reconstruit la déduplication depuis la session précédente

      m_initialized = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Scanne l'historique des deals depuis la dernière synchronisation
   // et enregistre toute nouvelle position clôturée. À appeler une
   // fois par nouvelle bougie (pas besoin de plus fréquent).
   //---------------------------------------------------------------
   int               Update()
     {
      if(!m_initialized)
         return(0);

      datetime toTime = TimeCurrent() + 3600; // Marge de sécurité
      if(!HistorySelect(m_lastSyncTime, toTime))
         return(0);

      int dealsTotal = HistoryDealsTotal();
      int newRecords = 0;

      for(int i = 0; i < dealsTotal; i++)
        {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0)
            continue;

         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != m_symbol)
            continue;
         if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != m_magicNumber)
            continue;

         long entryFlag = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entryFlag != DEAL_ENTRY_OUT && entryFlag != DEAL_ENTRY_OUT_BY)
            continue; // On ne traite que sur les deals de SORTIE (position réellement clôturée)

         ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
         if(AlreadyProcessed(positionId))
            continue; // NOUVEAU (correctif doublons) : grâce à LoadProcessedIds(), fonctionne aussi apres un redemarrage

         SPositionRecord record;
         if(BuildRecordFromPosition(positionId, record))
           {
            int n = ArraySize(m_records);
            ArrayResize(m_records, n + 1);
            m_records[n] = record;
            MarkProcessed(positionId); // Persiste immédiatement sur disque
            newRecords++;
           }
        }

      m_lastSyncTime = TimeCurrent();
      return(newRecords);
     }

   int               GetRecordCount() const { return(ArraySize(m_records)); }

   SPositionRecord   GetRecord(const int index) const
     {
      SPositionRecord empty;
      ZeroMemory(empty);
      if(index < 0 || index >= ArraySize(m_records))
         return(empty);
      return(m_records[index]);
     }

   //---------------------------------------------------------------
   // Profit moyen par trade clôturé.
   //---------------------------------------------------------------
   double            GetAverageProfit() const
     {
      int total = ArraySize(m_records);
      if(total == 0)
         return(0.0);

      double sum = 0.0;
      for(int i = 0; i < total; i++)
         sum += m_records[i].profit;
      return(sum / total);
     }

   //---------------------------------------------------------------
   // Durée moyenne d'un trade, en secondes.
   //---------------------------------------------------------------
   double            GetAverageDurationSeconds() const
     {
      int total = ArraySize(m_records);
      if(total == 0)
         return(0.0);

      double sum = 0.0;
      for(int i = 0; i < total; i++)
         sum += m_records[i].durationSeconds;
      return(sum / total);
     }

   //---------------------------------------------------------------
   // RR moyen réalisé sur l'ensemble des trades clôturés (0 exclus
   // du calcul, un RR nul signifiant en général un SL non retrouvé
   // dans l'historique plutôt qu'un RR réellement nul).
   //---------------------------------------------------------------
   double            GetAverageRR() const
     {
      int total = ArraySize(m_records);
      if(total == 0)
         return(0.0);

      double sum = 0.0;
      int count = 0;
      for(int i = 0; i < total; i++)
        {
         if(m_records[i].rr > 0.0)
           {
            sum += m_records[i].rr;
            count++;
           }
        }
      if(count == 0)
         return(0.0);
      return(sum / count);
     }

   //---------------------------------------------------------------
   // Nombre de trades gagnants / perdants (utile pour CStatistics,
   // exposé ici pour éviter de rescanner l'historique deux fois).
   //---------------------------------------------------------------
   int               GetWinningTradesCount() const
     {
      int total = ArraySize(m_records);
      int count = 0;
      for(int i = 0; i < total; i++)
        {
         if(m_records[i].profit > 0.0)
            count++;
        }
      return(count);
     }

   int               GetLosingTradesCount() const
     {
      int total = ArraySize(m_records);
      int count = 0;
      for(int i = 0; i < total; i++)
        {
         if(m_records[i].profit < 0.0)
            count++;
        }
      return(count);
     }
  };

#endif // POSITIONMANAGER_MQH
//+------------------------------------------------------------------+
