//+------------------------------------------------------------------+
//|                                       TradeLifecycleTracker.mqh    |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| PHILOSOPHIE (à lire avant toute modification future) :             |
//|   Ce module est un OBSERVATEUR PASSIF. Il ne prend aucune          |
//|   décision de trading et ne modifie JAMAIS une position. Il        |
//|   n'appelle ni OrderSend, ni PositionClose, ni PositionModify, ni  |
//|   aucune primitive de CTrade. Son unique responsabilité est de    |
//|   collecter des données objectives sur la vie d'un trade afin de  |
//|   permettre l'analyse statistique et l'amélioration future de la  |
//|   stratégie. Si un jour quelqu'un est tenté d'ajouter ici une      |
//|   ligne qui modifie un SL, un TP, ou ferme une position : NON.    |
//|   Cette logique appartient exclusivement à CTradeManager.          |
//|                                                                    |
//| CE QUE CE MODULE FAIT :                                            |
//|   - Suit chaque position ouverte, tick par tick (MFE/MAE en       |
//|     argent réel $, Heat, temps passé en gain/en perte).            |
//|   - Enregistre chaque événement notable de la vie du trade         |
//|     (Break Even activé, Trailing activé, SL/TP modifié) sous      |
//|     forme d'une structure générique SPositionEvent, horodatée.     |
//|   - Calcule un Trade Quality Score à l'ouverture (0-100), à       |
//|     partir du contexte marché déjà capturé dans STradeSnapshot.    |
//|                                                                    |
//| CE QUE CE MODULE NE FAIT PAS :                                     |
//|   - Il ne lit PAS lui-même POSITION_SL/POSITION_TP/POSITION_PROFIT|
//|     via PositionSelectByTicket(). Toutes les valeurs lui sont      |
//|     transmises par l'orchestrateur (NexusEdgeEA.mq5), qui a déjà  |
//|     ces informations sous la main dans ManageOpenPositions(). Ce   |
//|     choix évite toute duplication de lecture de position et tout  |
//|     risque d'interférence avec le contexte de sélection utilisé   |
//|     ailleurs (CTradeManager, CPositionManager).                    |
//|   - Il n'écrit AUCUN fichier lui-même. L'écriture (CSV, timeline   |
//|     texte) est la responsabilité de CLogger, appelé par            |
//|     l'orchestrateur - voir Logger.mqh (étape suivante).            |
//|                                                                    |
//| CORRÉLATION : chaque trade suivi est indexé par positionId, la     |
//|   même clé que POSITION_TICKET/POSITION_IDENTIFIER déjà utilisée   |
//|   dans tout le projet (CPositionManager, RecordOpenContext dans    |
//|   NexusEdgeEA.mq5). Aucun nouvel identifiant n'est introduit.      |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef TRADELIFECYCLETRACKER_MQH
#define TRADELIFECYCLETRACKER_MQH

#include "Types.mqh"
#include "Utilities.mqh"

//+------------------------------------------------------------------+
//| Classe CTradeLifecycleTracker                                       |
//+------------------------------------------------------------------+
class CTradeLifecycleTracker
  {
private:
   //---------------------------------------------------------------
   // État vivant d'un trade suivi. Structure INTERNE (pas dans
   // Types.mqh) : contrairement à STradeFullRecord/SPositionEvent
   // qui sont des formats de SORTIE partagés avec CLogger, ceci est
   // un détail d'implémentation propre au tracker, jamais exposé
   // directement à l'extérieur de cette classe.
   //---------------------------------------------------------------
   struct SLiveTrade
     {
      ulong             positionId;
      string            symbol;
      ENUM_SIGNAL_TYPE  type;
      double            entryPrice;
      double            lot;
      double            initialSL;
      double            initialTP;
      double            currentSL;
      double            currentTP;
      datetime          openTime;
      datetime          lastUpdateTime;      // Dernier passage dans Update() - sert à calculer le delta de temps
      double            mfeMoney;            // Meilleur profit flottant jamais atteint ($)
      double            maeMoney;            // Pire perte flottante jamais atteinte ($) = Heat, stockée positive
      int               timeInProfitSec;
      int               timeInLossSec;
      int               slModificationCount;
      int               slModificationCountBreakEven; // NOUVEAU
      int               slModificationCountTrailing;  // NOUVEAU
      int               slModificationCountProfitGuard; // NOUVEAU (Profit Guard)
      int               tpModificationCount;
      bool              breakEvenActivatedFlag;
      bool              trailingActivatedFlag;
      datetime          breakEvenActivatedTime;
      datetime          trailingActivatedTime;
      double            tradeQualityScore;
      int               newsDuringTradeCount;     // NOUVEAU
      string            lastNewsLabelSeen;        // NOUVEAU - dedoublonnage (une meme fenetre de news ne compte qu'une fois)
      string            newsDuringTradeLastDetail; // NOUVEAU
      int               partialCloseCount;        // NOUVEAU
      SPositionEvent    events[];            // Journal chronologique complet de ce trade
     };

   SLiveTrade        m_trades[];
   bool              m_enabled;
   bool              m_initialized;

   //---------------------------------------------------------------
   // Recherche l'index d'un trade suivi par positionId. Retourne -1
   // si non trouvé (ex: position ouverte avant le démarrage de cette
   // session de l'EA, ou déjà finalisée).
   //---------------------------------------------------------------
   int               FindIndex(const ulong positionId) const
     {
      int total = ArraySize(m_trades);
      for(int i = 0; i < total; i++)
        {
         if(m_trades[i].positionId == positionId)
            return(i);
        }
      return(-1);
     }

   //---------------------------------------------------------------
   // Ajoute un événement générique au journal d'un trade. Point
   // d'entrée UNIQUE pour toute écriture dans events[] - toutes les
   // méthodes RecordXxx() publiques passent par ici, ce qui garantit
   // qu'un futur type d'événement (partial close, pyramiding...)
   // n'a besoin d'aucune nouvelle logique de stockage, seulement
   // d'une nouvelle valeur d'ENUM_TRADE_EVENT_TYPE.
   //---------------------------------------------------------------
   void              PushEvent(const int idx, const ENUM_TRADE_EVENT_TYPE eventType, const string cause,
                                const double previousValue, const double newValue,
                                const double currentProfitMoney, const string note = "")
     {
      SPositionEvent ev;
      ev.positionId    = m_trades[idx].positionId;
      ev.time          = TimeCurrent();
      ev.eventType     = eventType;
      ev.cause         = cause;
      ev.previousValue = previousValue;
      ev.newValue      = newValue;
      ev.currentProfit = currentProfitMoney;
      ev.note          = note;

      int n = ArraySize(m_trades[idx].events);
      ArrayResize(m_trades[idx].events, n + 1);
      m_trades[idx].events[n] = ev;
     }

   //---------------------------------------------------------------
   // Retire un trade du tableau des trades suivis (swap avec le
   // dernier - même technique que le reste du projet, ex:
   // CPositionManager, NexusEdgeEA.mq5).
   //---------------------------------------------------------------
   void              RemoveAt(const int idx)
     {
      int last = ArraySize(m_trades) - 1;
      if(idx != last)
         m_trades[idx] = m_trades[last];
      ArrayResize(m_trades, last);
     }

public:
                     CTradeLifecycleTracker()
     {
      m_enabled     = true;
      m_initialized = false;
     }

   //---------------------------------------------------------------
   // Initialise le tracker. enabled correspond typiquement à
   // InpTrackTradeLifecycle (Config.mqh) - si false, toutes les
   // méthodes publiques deviennent des no-op, garantissant un impact
   // nul sur les performances du robot.
   //---------------------------------------------------------------
   bool              Init(const bool enabled = true)
     {
      m_enabled     = enabled;
      m_initialized = true;
      ArrayResize(m_trades, 0);
      return(true);
     }

   bool              IsEnabled() const { return(m_enabled && m_initialized); }

   int               GetTrackedCount() const { return(ArraySize(m_trades)); }

   bool              IsTracked(const ulong positionId) const { return(FindIndex(positionId) >= 0); }

   //---------------------------------------------------------------
   // NOUVEAU (correctif diagnostic). Expose les compteurs de
   // modification à chaud, pour le fichier DebugPipeline.txt - permet
   // de confirmer immédiatement, à chaque modification, que le
   // tracker a bien retrouvé la position ET incrémenté le bon
   // compteur. Retourne false si la position n'est pas suivie (dans
   // ce cas les compteurs sortants restent à 0 - signale clairement
   // le problème plutôt que de le masquer).
   //---------------------------------------------------------------
   bool              GetModifyCounts(const ulong positionId, int &total, int &breakEvenCount, int &trailingCount, int &profitGuardCount) const
     {
      total = 0; breakEvenCount = 0; trailingCount = 0; profitGuardCount = 0;
      int idx = FindIndex(positionId);
      if(idx < 0)
         return(false);
      total            = m_trades[idx].slModificationCount;
      breakEvenCount   = m_trades[idx].slModificationCountBreakEven;
      trailingCount    = m_trades[idx].slModificationCountTrailing;
      profitGuardCount = m_trades[idx].slModificationCountProfitGuard;
      return(true);
     }

   //---------------------------------------------------------------
   // FORMULE - Trade Quality Score (0-100, heuristique de départ,
   // volontairement simple et documentée pour être ajustable).
   // Objectif : distinguer "bonne analyse mais perte normale" de
   // "mauvais trade dès le départ", comme demandé. Fonction STATIQUE
   // et PURE (aucun état, aucun effet de bord) : réutilisable ailleurs
   // (ex: CDiagnostics) sans dépendre d'une instance du tracker.
   //---------------------------------------------------------------
   static double     ComputeTradeQualityScore(const STradeSnapshot &snap)
     {
      double score = 0.0;
      bool isBuy = (snap.signalType == SIGNAL_BUY);

      // +20 : tendance alignée avec la direction du trade
      bool trendAligned = (isBuy && snap.trendState == TREND_BULLISH) ||
                          (!isBuy && snap.trendState == TREND_BEARISH);
      if(trendAligned)
         score += 20.0;

      // +20 : marge de score bien au-dessus du seuil (signal net, pas limite)
      double winningScore = MathMax(snap.scoreBullish, snap.scoreBearish);
      if(snap.scoreThreshold > 0.0)
        {
         double marginRatio = (winningScore - snap.scoreThreshold) / snap.scoreThreshold;
         score += CUtilities::Clamp(marginRatio * 100.0, 0.0, 20.0);
        }

      // +15 : RSI dans une zone cohérente avec la direction (ni plat, ni en extrême opposé)
      bool rsiCoherent = (isBuy && snap.rsi >= 50.0 && snap.rsi <= 80.0) ||
                        (!isBuy && snap.rsi <= 50.0 && snap.rsi >= 20.0);
      if(rsiCoherent)
         score += 15.0;

      // +15 : un pattern de bougie a effectivement été détecté
      if(snap.patternDescription != "" && snap.patternDescription != "Aucun")
         score += 15.0;

      // +15 : breakout confirmé dans le sens du trade
      bool breakoutAligned = (isBuy && snap.breakoutState == BREAKOUT_BULLISH) ||
                            (!isBuy && snap.breakoutState == BREAKOUT_BEARISH);
      if(breakoutAligned)
         score += 15.0;

      // +15 : momentum net dans le sens du trade
      bool momentumAligned = (isBuy && snap.momentum > 20.0) || (!isBuy && snap.momentum < -20.0);
      if(momentumAligned)
         score += 15.0;

      return(CUtilities::Clamp(score, 0.0, 100.0));
     }

   //---------------------------------------------------------------
   // FORMULE - Capture Ratio (%) = profit final / MFE * 100.
   // Fonction statique et pure, réutilisable par CDiagnostics/Logger
   // sans dépendre d'une instance (évite toute duplication de calcul
   // le jour où plusieurs modules ont besoin du même ratio).
   //---------------------------------------------------------------
   static double     ComputeCaptureRatio(const double mfeMoney, const double profitFinal)
     {
      if(mfeMoney <= 0.0)
         return(0.0); // Le trade n'a jamais été en profit flottant : notion de "capture" non applicable
      return(CUtilities::SafeDivide(profitFinal, mfeMoney, 0.0) * 100.0);
     }

   //---------------------------------------------------------------
   // FORMULE - Profit laissé sur la table ($) = MFE - profit final.
   // Peut être négatif si le trade a clôturé au-dessus de son MFE
   // enregistré (cas rare, ex. gap favorable au moment exact de la
   // clôture) - restitué tel quel, sans artificiellement forcer >= 0.
   //---------------------------------------------------------------
   static double     ComputeProfitLeftOnTable(const double mfeMoney, const double profitFinal)
     {
      return(mfeMoney - profitFinal);
     }

   //---------------------------------------------------------------
   // Enregistre une nouvelle position à suivre. À appeler juste après
   // une ouverture réussie (CTradeManager::OpenPosition), avec le
   // même STradeSnapshot déjà construit pour CLogger::LogTradeSnapshot
   // - aucune donnée n'est redemandée deux fois.
   //---------------------------------------------------------------
   void              RegisterNewPosition(const ulong positionId, const STradeSnapshot &snap)
     {
      if(!IsEnabled())
         return;
      if(FindIndex(positionId) >= 0)
         return; // Déjà suivi - sécurité contre un double enregistrement accidentel

      SLiveTrade t;
      t.positionId              = positionId;
      t.symbol                  = snap.symbol;
      t.type                    = snap.signalType;
      t.entryPrice               = snap.entryPrice;
      t.lot                     = snap.lot;
      t.initialSL               = snap.slPrice;
      t.initialTP               = snap.tpPrice;
      t.currentSL               = snap.slPrice;
      t.currentTP               = snap.tpPrice;
      t.openTime                = snap.entryTime;
      t.lastUpdateTime          = snap.entryTime;
      t.mfeMoney                = 0.0;
      t.maeMoney                = 0.0;
      t.timeInProfitSec         = 0;
      t.timeInLossSec           = 0;
      t.slModificationCount     = 0;
      t.slModificationCountBreakEven = 0;
      t.slModificationCountTrailing  = 0;
      t.slModificationCountProfitGuard = 0;
      t.tpModificationCount     = 0;
      t.breakEvenActivatedFlag  = false;
      t.trailingActivatedFlag   = false;
      t.breakEvenActivatedTime  = 0;
      t.trailingActivatedTime   = 0;
      t.tradeQualityScore       = ComputeTradeQualityScore(snap);
      t.newsDuringTradeCount     = 0;
      t.lastNewsLabelSeen        = "";
      t.newsDuringTradeLastDetail = "";
      t.partialCloseCount        = 0;
      ArrayResize(t.events, 0);

      int n = ArraySize(m_trades);
      ArrayResize(m_trades, n + 1);
      m_trades[n] = t;

      PushEvent(n, EVENT_OPENED, "Ouverture", 0.0, snap.entryPrice, 0.0,
               StringFormat("Trade Quality Score = %.0f/100", t.tradeQualityScore));
     }

   //---------------------------------------------------------------
   // Mise à jour "vivante" - à appeler à CHAQUE TICK pour chaque
   // position ouverte suivie (typiquement depuis ManageOpenPositions()
   // dans NexusEdgeEA.mq5, qui boucle déjà sur toutes les positions
   // ouvertes à chaque tick). currentProfitMoney est le profit
   // flottant ACTUEL de la position, en devise du compte
   // (POSITION_PROFIT), lu et transmis par l'appelant - le tracker ne
   // le lit jamais lui-même (voir philosophie en tête de fichier).
   //---------------------------------------------------------------
   void              Update(const ulong positionId, const double currentProfitMoney)
     {
      if(!IsEnabled())
         return;

      int idx = FindIndex(positionId);
      if(idx < 0)
         return; // Position non suivie (ouverte avant le démarrage de l'EA, ou hors périmètre)

      datetime now = TimeCurrent();
      int elapsedSec = (int)(now - m_trades[idx].lastUpdateTime);
      if(elapsedSec > 0)
        {
         if(currentProfitMoney > 0.0)
            m_trades[idx].timeInProfitSec += elapsedSec;
         else if(currentProfitMoney < 0.0)
            m_trades[idx].timeInLossSec += elapsedSec;
         // Profit exactement egal a 0.0 : ni gain ni perte, aucun cumul (cas limite negligeable)
        }
      m_trades[idx].lastUpdateTime = now;

      if(currentProfitMoney > m_trades[idx].mfeMoney)
         m_trades[idx].mfeMoney = currentProfitMoney;

      double adverse = -currentProfitMoney; // positif quand le trade est en perte flottante
      if(adverse > m_trades[idx].maeMoney)
         m_trades[idx].maeMoney = adverse;
     }

   //---------------------------------------------------------------
   // REFONTE (architecture "décision unique") : les trois méthodes
   // RecordBreakEvenApplied/RecordTrailingApplied/RecordProfitGuardApplied
   // sont fusionnées en UNE SEULE, pilotée par ENUM_PROTECTION_SOURCE -
   // cohérent avec CProfitProtectionEngine qui ne produit plus qu'UNE
   // décision par tick, quel que soit le mécanisme gagnant. À appeler
   // juste après un CProfitProtectionEngine::ApplyProtection() qui a
   // réellement modifié le SL (jamais après une tentative refusée).
   //
   // note (nouveau, traçabilité demande explicite) : texte libre
   // fourni par CProfitProtectionEngine::ComputeFinalStopLevel(),
   // contenant le détail complet (structure utilisée, PeakProfit,
   // profit sécurisé, Capture Ratio estimé) - stocké tel quel dans
   // SPositionEvent.note, sans transformation ici.
   //---------------------------------------------------------------
   void              RecordProtectionApplied(const ulong positionId, const ENUM_PROTECTION_SOURCE source,
                                             const string sourceLabel, const double oldSL, const double newSL,
                                             const double currentProfitMoney, const string note = "")
     {
      if(!IsEnabled())
         return;
      int idx = FindIndex(positionId);
      if(idx < 0)
         return;

      ENUM_TRADE_EVENT_TYPE eventType = EVENT_SL_MODIFIED;

      // Détection de PREMIÈRE activation (BreakEven/Trailing uniquement -
      // Structure/PeakPercent/Emergency n'ont pas cette notion "d'activation
      // unique", ils peuvent légitimement gagner puis reperdre la main).
      if(source == PROTECTION_SOURCE_BREAKEVEN && !m_trades[idx].breakEvenActivatedFlag)
        {
         m_trades[idx].breakEvenActivatedFlag = true;
         m_trades[idx].breakEvenActivatedTime = TimeCurrent();
         PushEvent(idx, EVENT_BREAKEVEN_ACTIVATED, sourceLabel, oldSL, newSL, currentProfitMoney, note);
        }
      else if(source == PROTECTION_SOURCE_TRAILING && !m_trades[idx].trailingActivatedFlag)
        {
         m_trades[idx].trailingActivatedFlag = true;
         m_trades[idx].trailingActivatedTime = TimeCurrent();
         PushEvent(idx, EVENT_TRAILING_ACTIVATED, sourceLabel, oldSL, newSL, currentProfitMoney, note);
        }

      m_trades[idx].slModificationCount++;
      switch(source)
        {
         case PROTECTION_SOURCE_BREAKEVEN:
            m_trades[idx].slModificationCountBreakEven++;
            break;
         case PROTECTION_SOURCE_TRAILING:
            m_trades[idx].slModificationCountTrailing++;
            break;
         case PROTECTION_SOURCE_STRUCTURE:
         case PROTECTION_SOURCE_PEAK_PERCENT:
         case PROTECTION_SOURCE_EMERGENCY:
            m_trades[idx].slModificationCountProfitGuard++;
            break;
         default:
            break; // Ne devrait pas arriver (ComputeFinalStopLevel ne retourne jamais PROTECTION_SOURCE_NONE en cas de succès)
        }

      m_trades[idx].currentSL = newSL;
      PushEvent(idx, eventType, sourceLabel, oldSL, newSL, currentProfitMoney, note);
     }

   //---------------------------------------------------------------
   // À appeler après toute modification du TP (aujourd'hui non
   // utilisé par le robot, mais prévu pour une évolution future -
   // multi-TP, prise partielle avec ajustement de cible...).
   //---------------------------------------------------------------
   void              RecordTpModification(const ulong positionId, const string cause,
                                          const double oldTP, const double newTP,
                                          const double currentProfitMoney)
     {
      if(!IsEnabled())
         return;
      int idx = FindIndex(positionId);
      if(idx < 0)
         return;

      m_trades[idx].tpModificationCount++;
      m_trades[idx].currentTP = newTP;
      PushEvent(idx, EVENT_TP_MODIFIED, cause, oldTP, newTP, currentProfitMoney);
     }

   //---------------------------------------------------------------
   // Enregistre un événement de fermeture partielle (prévu pour une
   // évolution future - InpUsePartialClose existe déjà dans Config,
   // mais aucune donnée de vie n'était collectée jusqu'ici). N'ouvre,
   // ne ferme, ni ne calcule aucun volume - se contente d'observer ce
   // que CTradeManager::PartialClose() a déjà fait avec succès.
   //---------------------------------------------------------------
   void              RecordPartialClose(const ulong positionId, const double volumeClosed,
                                        const double currentProfitMoney)
     {
      if(!IsEnabled())
         return;
      int idx = FindIndex(positionId);
      if(idx < 0)
         return;

      PushEvent(idx, EVENT_PARTIAL_CLOSE, "PartialClose", m_trades[idx].lot, volumeClosed, currentProfitMoney);
      m_trades[idx].partialCloseCount++;
     }

   //---------------------------------------------------------------
   // À appeler à chaque tick (depuis ManageOpenPositions) avec le
   // résultat de CNewsFilter::IsNewsBlockActive(). Ne journalise
   // QU'UNE FOIS par fenêtre de news distincte (déduplication via
   // newsDetail, qui inclut le nom de l'annonce et son horodatage -
   // donc naturellement différent d'une annonce à l'autre) : sans ce
   // filtre, un trade ouvert pendant toute une fenêtre de news
   // générerait un événement à chaque tick, ce qui n'apporte rien.
   //---------------------------------------------------------------
   void              RecordNewsDuringTrade(const ulong positionId, const string newsDetail, const double currentProfitMoney)
     {
      if(!IsEnabled())
         return;
      int idx = FindIndex(positionId);
      if(idx < 0)
         return;
      if(newsDetail == "" || newsDetail == m_trades[idx].lastNewsLabelSeen)
         return; // Pas de news active, ou meme fenetre de news deja journalisee

      m_trades[idx].lastNewsLabelSeen         = newsDetail;
      m_trades[idx].newsDuringTradeLastDetail = newsDetail;
      m_trades[idx].newsDuringTradeCount++;
      PushEvent(idx, EVENT_NEWS_DURING_TRADE, "News", 0.0, 0.0, currentProfitMoney, newsDetail);
     }

   //---------------------------------------------------------------
   // Remplit la portion "vie du trade" d'un STradeFullRecord déjà
   // partiellement construit (contexte d'ouverture + clôture déjà
   // renseignés par l'appelant depuis STradeSnapshot/SPositionRecord).
   // Ne fait AUCUNE lecture broker : copie uniquement l'état interne
   // déjà accumulé par Update()/RecordXxx(). Retourne false si le
   // trade n'est pas (ou plus) suivi - l'appelant garde alors les
   // champs de vie à leurs valeurs par défaut (0), signalant
   // clairement l'absence de donnée plutôt qu'une fausse valeur.
   //---------------------------------------------------------------
   bool              FillLifecycleData(const ulong positionId, STradeFullRecord &rec) const
     {
      int idx = FindIndex(positionId);
      if(idx < 0)
         return(false);

      rec.mfeMoney                = m_trades[idx].mfeMoney;
      rec.maeMoney                = m_trades[idx].maeMoney;
      rec.timeInProfitSec         = m_trades[idx].timeInProfitSec;
      rec.timeInLossSec           = m_trades[idx].timeInLossSec;
      rec.slModificationCount     = m_trades[idx].slModificationCount;
      rec.slModificationCountBreakEven = m_trades[idx].slModificationCountBreakEven; // NOUVEAU
      rec.slModificationCountTrailing  = m_trades[idx].slModificationCountTrailing;  // NOUVEAU
      rec.slModificationCountProfitGuard = m_trades[idx].slModificationCountProfitGuard; // NOUVEAU
      rec.tpModificationCount     = m_trades[idx].tpModificationCount;
      rec.breakEvenActivatedTime  = m_trades[idx].breakEvenActivatedTime;
      rec.trailingActivatedTime   = m_trades[idx].trailingActivatedTime;
      rec.tradeQualityScore       = m_trades[idx].tradeQualityScore;
      rec.newsDuringTradeCount    = m_trades[idx].newsDuringTradeCount;
      rec.newsDuringTradeLastDetail = m_trades[idx].newsDuringTradeLastDetail;
      rec.partialCloseCount       = m_trades[idx].partialCloseCount;
      return(true);
     }

   //---------------------------------------------------------------
   // Détermine une raison de clôture AFFINÉE, qui distingue - à la
   // différence du DEAL_REASON brut du broker (voir la limite
   // documentée dans PositionManager.mqh) - un SL jamais modifié d'un
   // SL déplacé par Break Even ou par Trailing. C'est la réponse
   // directe à "le trailing coupe-t-il les trades trop tôt ?".
   //---------------------------------------------------------------
   string            BuildDetailedCloseReason(const ulong positionId, const string rawCloseReason) const
     {
      int idx = FindIndex(positionId);
      if(idx < 0)
         return(rawCloseReason);

      bool looksLikeSLHit = (StringFind(rawCloseReason, "SL") >= 0);
      if(!looksLikeSLHit)
         return(rawCloseReason); // TP atteint, fermeture manuelle, etc. - le brut est déjà clair

      if(m_trades[idx].trailingActivatedFlag)
         return("SL touché - déplacé par Trailing avant clôture");
      if(m_trades[idx].breakEvenActivatedFlag)
         return("SL touché - déplacé par Break Even avant clôture");
      return("SL touché - jamais modifié (SL initial)");
     }

   //---------------------------------------------------------------
   // Nombre d'événements enregistrés pour un trade (pour permettre à
   // l'orchestrateur/Logger d'itérer et d'écrire chaque ligne dans
   // TradeEvents.csv).
   //---------------------------------------------------------------
   int               GetEventCount(const ulong positionId) const
     {
      int idx = FindIndex(positionId);
      if(idx < 0)
         return(0);
      return(ArraySize(m_trades[idx].events));
     }

   SPositionEvent    GetEvent(const ulong positionId, const int eventIndex) const
     {
      SPositionEvent empty;
      ZeroMemory(empty);
      int idx = FindIndex(positionId);
      if(idx < 0 || eventIndex < 0 || eventIndex >= ArraySize(m_trades[idx].events))
         return(empty);
      return(m_trades[idx].events[eventIndex]);
     }

   //---------------------------------------------------------------
   // Construit un résumé texte lisible (façon "timeline"), à partir
   // des événements déjà collectés - AUCUN nouveau stockage créé
   // pour ça, uniquement une mise en forme de events[] à la demande.
   // Utilisable directement par CLogger pour le fichier TXT.
   //---------------------------------------------------------------
   string            BuildTimelineSummary(const ulong positionId) const
     {
      int idx = FindIndex(positionId);
      if(idx < 0)
         return("");

      string result = StringFormat("--- Timeline du trade (positionId=%I64u) ---\n", positionId);
      int total = ArraySize(m_trades[idx].events);
      for(int i = 0; i < total; i++)
        {
         SPositionEvent ev = m_trades[idx].events[i];
         result += StringFormat("%s | %s (%s) | profit courant=%.2f",
                                TimeToString(ev.time, TIME_MINUTES | TIME_SECONDS),
                                EnumToString(ev.eventType), ev.cause, ev.currentProfit);
         if(ev.eventType == EVENT_SL_MODIFIED || ev.eventType == EVENT_TP_MODIFIED)
            result += StringFormat(" | %.5f -> %.5f", ev.previousValue, ev.newValue);
         if(ev.note != "")
            result += " | " + ev.note;
         result += "\n";
        }
      result += StringFormat("MFE=%.2f | MAE(Heat)=%.2f | Temps en gain=%ds | Temps en perte=%ds\n",
                             m_trades[idx].mfeMoney, m_trades[idx].maeMoney,
                             m_trades[idx].timeInProfitSec, m_trades[idx].timeInLossSec);
      return(result);
     }

   //---------------------------------------------------------------
   // Libère un trade du suivi. À appeler UNE FOIS que
   // FillLifecycleData()/GetEvent()/BuildTimelineSummary() ont été
   // exploités par l'appelant pour la clôture (sinon les données sont
   // perdues). Ajoute un dernier événement EVENT_CLOSED avant
   // libération, pour que la timeline soit complète jusqu'au bout.
   //---------------------------------------------------------------
   void              ReleasePosition(const ulong positionId, const double finalProfitMoney)
     {
      if(!IsEnabled())
         return;
      int idx = FindIndex(positionId);
      if(idx < 0)
         return;

      PushEvent(idx, EVENT_CLOSED, "Cloture", 0.0, 0.0, finalProfitMoney);
      // Note : l'événement EVENT_CLOSED est ajouté puis immédiatement
      // perdu avec le reste de events[] lors du RemoveAt() qui suit -
      // c'est voulu : l'appelant doit avoir déjà lu tous les
      // événements via GetEvent()/BuildTimelineSummary() AVANT
      // d'appeler ReleasePosition(). Documenté explicitement pour
      // éviter un bug d'ordre d'appel dans l'orchestrateur.
      RemoveAt(idx);
     }
  };

#endif // TRADELIFECYCLETRACKER_MQH
//+------------------------------------------------------------------+
