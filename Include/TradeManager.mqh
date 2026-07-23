//+------------------------------------------------------------------+
//|                                                TradeManager.mqh    |
//|                                              NexusEdgeEA        |
//|                                                                    |
//| Description : Exécution et gestion des positions.                 |
//|   CTradeManager encapsule la classe standard CTrade (MQL5) pour   |
//|   ouvrir, fermer, modifier des positions, et implémente Break     |
//|   Even, Trailing Stop (points ou ATR), et Fermeture Partielle.    |
//|                                                                    |
//|   Scaling In/Out et Pyramiding sont orchestrés au niveau du       |
//|   module principal (NexusEdgeEA.mq5) en appelant plusieurs fois   |
//|   OpenPosition()/ClosePartial() - pas besoin de logique dédiée    |
//|   ici, ce serait dupliquer les mêmes primitives.                  |
//|                                                                    |
//| MODIFIÉ (correctif Trailing "professionnel", demande explicite    |
//|   et documentée de l'utilisateur après observation d'un trade      |
//|   réel où le SL était resserré à 200 points DÈS LE PREMIER TICK,  |
//|   sans aucun seuil de profit ni limite de fréquence) :             |
//|                                                                    |
//|   AVANT : ApplyTrailingStop()/ApplyTrailingATR() modifiaient le   |
//|   SL dès la moindre amélioration de prix, à N'IMPORTE QUEL         |
//|   moment (même à profit nul ou négatif), sans limite de           |
//|   fréquence -> jusqu'à 60+ PositionModify() en 2 minutes observés  |
//|   en compte démo live, et une perte de -1380$ sur un trade fermé   |
//|   en 3,6 secondes par un SL resserré prématurément.                 |
//|                                                                    |
//|   APRÈS : trois garde-fous cumulatifs, tous requis pour qu'une    |
//|   modification ait lieu :                                          |
//|     1. TrailingStart  : le trailing ne s'active QUE si le profit  |
//|        flottant a atteint un seuil minimum (en points).            |
//|     2. TrailingStep   : le nouveau SL doit améliorer l'ancien      |
//|        d'AU MOINS ce nombre de points (pas la moindre amélioration |
//|        infinitésimale).                                            |
//|     3. MinimumModifyInterval : au moins N secondes doivent s'être  |
//|        écoulées depuis la DERNIÈRE modification de CETTE position  |
//|        (tous mécanismes confondus - BreakEven ET Trailing partagent|
//|        le même throttle par ticket, ce qui empêche mécaniquement   |
//|        deux PositionModify() sur le même tick pour la même         |
//|        position - voir CanModifyNow()/MarkModified() ci-dessous).  |
//|                                                                    |
//|   Aucune règle de STRATÉGIE (quand acheter/vendre, calcul du SL/TP |
//|   initial) n'a été touchée - uniquement la CADENCE et le SEUIL     |
//|   d'ajustement d'un SL déjà décidé. Modification explicitement     |
//|   autorisée par l'utilisateur (voir échange du jour du correctif). |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef TRADEMANAGER_MQH
#define TRADEMANAGER_MQH

#include <Trade/Trade.mqh>
#include "Types.mqh"
#include "Utilities.mqh"

//+------------------------------------------------------------------+
//| Classe CTradeManager                                                 |
//+------------------------------------------------------------------+
class CTradeManager
  {
private:
   CTrade            m_trade;
   string            m_symbol;
   long              m_magicNumber;
   string            m_comment;
   bool              m_initialized;

   // --- NOUVEAU : throttle de modification, par ticket. Partagé par
   // BreakEven ET Trailing (classique et ATR) - c'est ce partage qui
   // empêche mécaniquement deux PositionModify() sur la même position
   // au même tick (voir la doc en tête de fichier, point 6 de la
   // demande utilisateur "aucune boucle ne doit appeler PositionModify
   // plusieurs fois sur le même tick").
   ulong             m_modifyTrackTicket[];
   datetime          m_modifyTrackTime[];

   //---------------------------------------------------------------
   // Trouve l'index d'un ticket dans le tableau de throttle interne.
   // Retourne -1 si ce ticket n'a encore jamais été modifié par ce
   // module depuis le démarrage de l'EA.
   //---------------------------------------------------------------
   int               FindModifyTrackIndex(const ulong ticket) const
     {
      int total = ArraySize(m_modifyTrackTicket);
      for(int i = 0; i < total; i++)
        {
         if(m_modifyTrackTicket[i] == ticket)
            return(i);
        }
      return(-1);
     }

   //---------------------------------------------------------------
   // Vrai si au moins minIntervalSeconds se sont écoulées depuis la
   // dernière modification connue de ce ticket (ou si ce ticket n'a
   // jamais été modifié - dans ce cas, toujours autorisé).
   //---------------------------------------------------------------
   bool              CanModifyNow(const ulong ticket, const int minIntervalSeconds) const
     {
      if(minIntervalSeconds <= 0)
         return(true); // Throttle désactivé (0 ou négatif) - comportement pré-correctif si jamais requis
      int idx = FindModifyTrackIndex(ticket);
      if(idx < 0)
         return(true);
      return((TimeCurrent() - m_modifyTrackTime[idx]) >= minIntervalSeconds);
     }

   //---------------------------------------------------------------
   // Enregistre l'instant présent comme dernière modification connue
   // pour ce ticket. Appelé UNIQUEMENT après un ModifyPosition() qui a
   // réellement réussi (jamais après une tentative refusée par le
   // broker), pour ne pas pénaliser inutilement la prochaine tentative
   // légitime si le broker avait momentanément rejeté l'ordre.
   //---------------------------------------------------------------
   void              MarkModified(const ulong ticket)
     {
      int idx = FindModifyTrackIndex(ticket);
      if(idx < 0)
        {
         int n = ArraySize(m_modifyTrackTicket);
         ArrayResize(m_modifyTrackTicket, n + 1);
         ArrayResize(m_modifyTrackTime, n + 1);
         m_modifyTrackTicket[n] = ticket;
         m_modifyTrackTime[n]   = TimeCurrent();
         return;
        }
      m_modifyTrackTime[idx] = TimeCurrent();
     }

public:
                     CTradeManager()
     {
      m_symbol      = "";
      m_magicNumber = 0;
      m_comment     = "";
      m_initialized = false;
     }

   //---------------------------------------------------------------
   // Initialise le gestionnaire de trades pour un symbole et un
   // Magic Number donnés.
   //---------------------------------------------------------------
   bool              Init(const string symbol, const long magicNumber, const string comment,
                          const ulong deviationPoints = 10)
     {
      m_symbol      = symbol;
      m_magicNumber = magicNumber;
      m_comment     = comment;

      m_trade.SetExpertMagicNumber(magicNumber);
      m_trade.SetDeviationInPoints(deviationPoints);
      m_trade.SetTypeFillingBySymbol(symbol);

      m_initialized = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // Expose le retcode de la dernière opération CTrade, pour le
   // logging diagnostic complet (succès ET échec), sans dupliquer la
   // logique déjà présente dans CTrade.
   //---------------------------------------------------------------
   uint              GetLastRetcode() const { return(m_trade.ResultRetcode()); }
   string            GetLastRetcodeDescription() const { return(m_trade.ResultRetcodeDescription()); }

   //---------------------------------------------------------------
   // Ticket du DEAL d'entrée de la dernière opération réussie.
   //
   // ATTENTION - PIÈGE CONFIRMÉ (diagnostic du 2026-07-17, voir
   // NexusEdgeEA.mq5) : CE N'EST PAS le POSITION_ID/POSITION_IDENTIFIER.
   // Le ticket du deal et le ticket de l'ordre qui l'a généré sont DEUX
   // NOMBRES DIFFÉRENTS en MT5 (ex. observé en live : ordre #9597195360,
   // deal #9278287729). CPositionManager indexe ses trades clôturés par
   // DEAL_POSITION_ID, qui correspond au TICKET DE L'ORDRE d'entrée
   // (déjà disponible via le paramètre ticketOut de OpenPosition()),
   // PAS au ticket retourné ici. N'utilisez JAMAIS cette méthode comme
   // clé de corrélation pour retrouver une position - utilisez le
   // ticket retourné par OpenPosition().
   //---------------------------------------------------------------
   ulong             GetLastDealTicket() const { return(m_trade.ResultDeal()); }

   //---------------------------------------------------------------
   // Ouvre une position BUY ou SELL. Retourne true en cas de succès
   // et fournit le ticket via le paramètre de sortie.
   //---------------------------------------------------------------
   bool              OpenPosition(const ENUM_SIGNAL_TYPE signalType, const double lot,
                                  const double sl, const double tp, ulong &ticketOut)
     {
      ticketOut = 0;
      if(!m_initialized || signalType == SIGNAL_NONE)
         return(false);

      bool success;
      if(signalType == SIGNAL_BUY)
         success = m_trade.Buy(lot, m_symbol, 0.0, sl, tp, m_comment);
      else
         success = m_trade.Sell(lot, m_symbol, 0.0, sl, tp, m_comment);

      if(!success)
        {
         PrintFormat("CTradeManager::OpenPosition - échec %s %s lot=%.2f (retcode=%d, %s)",
                     CUtilities::SignalTypeToString(signalType), m_symbol, lot,
                     m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         return(false);
        }

      ticketOut = m_trade.ResultOrder();
      return(true);
     }

   //---------------------------------------------------------------
   // Ferme intégralement une position par son ticket.
   //---------------------------------------------------------------
   bool              ClosePosition(const ulong ticket)
     {
      if(!m_initialized)
         return(false);

      if(!m_trade.PositionClose(ticket))
        {
         PrintFormat("CTradeManager::ClosePosition - échec ticket=%I64u (retcode=%d, %s)",
                     ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         return(false);
        }
      return(true);
     }

   //---------------------------------------------------------------
   // Ferme toutes les positions ouvertes sous ce Magic Number pour le
   // symbole configuré (utile pour Stop Trading / mode sécurité).
   //---------------------------------------------------------------
   int               CloseAllPositions()
     {
      int closedCount = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magicNumber)
            continue;

         if(ClosePosition(ticket))
            closedCount++;
        }
      return(closedCount);
     }

   //---------------------------------------------------------------
   // Modifie le SL/TP d'une position existante.
   //---------------------------------------------------------------
   bool              ModifyPosition(const ulong ticket, const double newSL, const double newTP)
     {
      if(!m_initialized)
         return(false);

      if(!m_trade.PositionModify(ticket, newSL, newTP))
        {
         PrintFormat("CTradeManager::ModifyPosition - échec ticket=%I64u (retcode=%d, %s)",
                     ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         return(false);
        }
      return(true);
     }

   //---------------------------------------------------------------
   // Ferme partiellement une position (closePercent % du volume
   // actuel), normalisé au step de volume du broker.
   //---------------------------------------------------------------
   bool              PartialClose(const ulong ticket, const double closePercent)
     {
      if(!m_initialized || closePercent <= 0.0 || closePercent >= 100.0)
         return(false);

      if(!PositionSelectByTicket(ticket))
         return(false);

      double currentVolume = PositionGetDouble(POSITION_VOLUME);
      double volStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double volMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);

      double volumeToClose = currentVolume * (closePercent / 100.0);
      if(volStep > 0.0)
         volumeToClose = MathFloor(volumeToClose / volStep) * volStep;

      if(volumeToClose < volMin || volumeToClose >= currentVolume)
         return(false); // Rien à fermer, ou fermeture partielle équivaudrait à une fermeture totale

      if(!m_trade.PositionClosePartial(ticket, volumeToClose))
        {
         PrintFormat("CTradeManager::PartialClose - échec ticket=%I64u volume=%.2f (retcode=%d, %s)",
                     ticket, volumeToClose, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         return(false);
        }
      return(true);
     }

   //---------------------------------------------------------------
   // NOUVEAU (Profit Guard). Point d'entrée public dédié aux modules
   // de protection EXTERNES à CTradeManager (ProfitProtectionEngine)
   // qui ont déjà calculé eux-mêmes le SL le plus protecteur (fusion
   // Structure/PeakPercent/Emergency) et n'ont plus qu'à le soumettre.
   //
   // Passe VOLONTAIREMENT par le même throttle interne
   // (CanModifyNow/MarkModified) que ApplyBreakEven/ApplyTrailingStop/
   // ApplyTrailingATR - c'est ce partage qui garantit qu'AUCUNE
   // combinaison de mécanismes de protection ne peut jamais générer
   // deux PositionModify() sur la même position au même tick, même en
   // ajoutant ce 5ème niveau de protection. CTradeManager reste ainsi
   // le SEUL point de passage vers CTrade, comme pour tout le reste
   // du projet - ProfitProtectionEngine ne connaît jamais CTrade.
   //
   // Ne vérifie PAS "improves" ici (contrairement à ApplyBreakEven/
   // ApplyTrailingStop) : l'appelant (ProfitProtectionEngine) a déjà
   // la responsabilité de n'appeler cette méthode qu'avec un niveau
   // réellement plus protecteur que le SL actuel - c'est le contrat
   // explicite de ComputeFinalStopLevel(). Un simple garde-fou
   // défensif est conservé malgré tout (voir ci-dessous).
   //---------------------------------------------------------------
   bool              ApplyExternalProtection(const ulong ticket, const double newSL, const double currentTP,
                                             const int minIntervalSeconds = 1)
     {
      if(!PositionSelectByTicket(ticket))
         return(false);

      double currentSL = PositionGetDouble(POSITION_SL);
      if(newSL == currentSL)
         return(false); // Rien à faire - évite un ordre au broker pour un SL identique

      if(!CanModifyNow(ticket, minIntervalSeconds))
         return(false);

      bool modified = ModifyPosition(ticket, newSL, currentTP);
      if(modified)
         MarkModified(ticket);
      return(modified);
     }

   //---------------------------------------------------------------
   // NOUVEAU (Profit Guard - Niveau 4 "Protection d'urgence", option
   // fermeture immédiate). Simple relais vers ClosePosition() - pas
   // de throttle nécessaire pour une fermeture (opération terminale,
   // aucun risque de boucle contrairement à une modification de SL).
   //---------------------------------------------------------------
   bool              ApplyExternalClose(const ulong ticket)
     {
      return(ClosePosition(ticket));
     }

   //---------------------------------------------------------------
   // REFONTE (architecture "décision unique", demande explicite de
   // l'utilisateur) : ApplyBreakEven/ApplyTrailingStop/ApplyTrailingATR
   // combinaient CALCUL et EXÉCUTION en une seule méthode - chacune
   // pouvait donc tenter un PositionModify() indépendamment des autres
   // mécanismes de protection (Profit Guard), avec le risque que
   // plusieurs mécanismes concurrents modifient la même position au
   // même tick (évité jusqu'ici par le throttle partagé, mais de
   // façon indirecte plutôt que par construction).
   //
   // Ces trois méthodes sont remplacées par des versions CALCUL PUR
   // (aucun appel à ModifyPosition, aucun throttle) : elles retournent
   // un CANDIDAT de SL, rien de plus. C'est ProfitProtectionEngine qui
   // rassemble TOUS les candidats (BreakEven, Trailing, Structure,
   // PeakPercent, Emergency), ne retient que le plus protecteur, et
   // déclenche UNE SEULE modification via ApplyExternalProtection().
   // Le throttle (CanModifyNow/MarkModified) ne s'applique donc plus
   // qu'à CE point d'exécution unique - plus besoin qu'il soit dupliqué
   // dans chaque mécanisme de calcul.
   //---------------------------------------------------------------

   //---------------------------------------------------------------
   // Calcule le niveau Break Even (sans l'appliquer). Retourne false
   // si le seuil de déclenchement n'est pas atteint, ou si le SL
   // actuel est déjà au moins aussi favorable.
   //---------------------------------------------------------------
   bool              ComputeBreakEvenLevel(const ulong ticket, const double triggerPoints, const double lockPoints,
                                           double &levelOut, string &reasonOut) const
     {
      levelOut = 0.0;
      reasonOut = "";
      if(!PositionSelectByTicket(ticket))
        {
         reasonOut = "position introuvable";
         return(false);
        }

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);

      double currentPrice = (posType == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(m_symbol, SYMBOL_BID)
                            : SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      double profitPoints = (posType == POSITION_TYPE_BUY)
                            ? (currentPrice - openPrice) / point
                            : (openPrice - currentPrice) / point;

      if(profitPoints < triggerPoints)
        {
         reasonOut = StringFormat("profit actuel %.0f pts < seuil %.0f pts", profitPoints, triggerPoints);
         return(false);
        }

      double lockDistance = CUtilities::PointsToPrice(m_symbol, lockPoints);
      double newSL = (posType == POSITION_TYPE_BUY) ? (openPrice + lockDistance) : (openPrice - lockDistance);
      newSL = CUtilities::NormalizePriceToTick(m_symbol, newSL);

      bool alreadyBetter = (posType == POSITION_TYPE_BUY) ? (currentSL >= newSL) : (currentSL <= newSL && currentSL != 0.0);
      if(currentSL != 0.0 && alreadyBetter)
        {
         reasonOut = "SL actuel deja au moins aussi favorable";
         return(false);
        }

      levelOut = newSL;
      return(true);
     }

   //---------------------------------------------------------------
   // Calcule le niveau Trailing Stop classique (sans l'appliquer).
   //---------------------------------------------------------------
   bool              ComputeTrailingLevel(const ulong ticket, const double startPoints, const double distancePoints,
                                          const double stepPoints, double &levelOut, string &reasonOut) const
     {
      levelOut = 0.0;
      reasonOut = "";
      if(!PositionSelectByTicket(ticket))
        {
         reasonOut = "position introuvable";
         return(false);
        }

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);

      double currentPrice = (posType == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(m_symbol, SYMBOL_BID)
                            : SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      double profitPoints = (posType == POSITION_TYPE_BUY)
                            ? (currentPrice - openPrice) / point
                            : (openPrice - currentPrice) / point;
      if(profitPoints < startPoints)
        {
         reasonOut = StringFormat("profit actuel %.0f pts < seuil %.0f pts", profitPoints, startPoints);
         return(false);
        }

      double distance = CUtilities::PointsToPrice(m_symbol, distancePoints);
      double candidateSL = (posType == POSITION_TYPE_BUY) ? (currentPrice - distance) : (currentPrice + distance);
      candidateSL = CUtilities::NormalizePriceToTick(m_symbol, candidateSL);

      bool improves = (posType == POSITION_TYPE_BUY)
                      ? (currentSL == 0.0 || candidateSL > currentSL)
                      : (currentSL == 0.0 || candidateSL < currentSL);
      if(!improves)
        {
         reasonOut = "nouveau SL moins protecteur que le SL actuel";
         return(false);
        }

      if(currentSL != 0.0)
        {
         double improvementPoints = CUtilities::PriceToPoints(m_symbol, MathAbs(candidateSL - currentSL));
         if(improvementPoints < stepPoints)
           {
            reasonOut = StringFormat("amelioration insuffisante (%.0f pts < step %.0f pts)", improvementPoints, stepPoints);
            return(false);
           }
        }

      levelOut = candidateSL;
      return(true);
     }

   //---------------------------------------------------------------
   // Calcule le niveau Trailing Stop basé sur l'ATR (sans l'appliquer).
   //---------------------------------------------------------------
   bool              ComputeTrailingATRLevel(const ulong ticket, const double atrValue, const double atrMultiplier,
                                             const double startPoints, const double stepPoints,
                                             double &levelOut, string &reasonOut) const
     {
      levelOut = 0.0;
      reasonOut = "";
      if(atrValue == EMPTY_VALUE || atrValue <= 0.0)
        {
         reasonOut = "ATR indisponible";
         return(false);
        }
      if(!PositionSelectByTicket(ticket))
        {
         reasonOut = "position introuvable";
         return(false);
        }

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);

      double currentPrice = (posType == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(m_symbol, SYMBOL_BID)
                            : SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      double profitPoints = (posType == POSITION_TYPE_BUY)
                            ? (currentPrice - openPrice) / point
                            : (openPrice - currentPrice) / point;
      if(profitPoints < startPoints)
        {
         reasonOut = StringFormat("profit actuel %.0f pts < seuil %.0f pts", profitPoints, startPoints);
         return(false);
        }

      double distance = atrValue * atrMultiplier;
      double candidateSL = (posType == POSITION_TYPE_BUY) ? (currentPrice - distance) : (currentPrice + distance);
      candidateSL = CUtilities::NormalizePriceToTick(m_symbol, candidateSL);

      bool improves = (posType == POSITION_TYPE_BUY)
                      ? (currentSL == 0.0 || candidateSL > currentSL)
                      : (currentSL == 0.0 || candidateSL < currentSL);
      if(!improves)
        {
         reasonOut = "nouveau SL moins protecteur que le SL actuel";
         return(false);
        }

      if(currentSL != 0.0)
        {
         double improvementPoints = CUtilities::PriceToPoints(m_symbol, MathAbs(candidateSL - currentSL));
         if(improvementPoints < stepPoints)
           {
            reasonOut = StringFormat("amelioration insuffisante (%.0f pts < step %.0f pts)", improvementPoints, stepPoints);
            return(false);
           }
        }

      levelOut = candidateSL;
      return(true);
     }

   //---------------------------------------------------------------
   // NOUVEAU : purge le suivi de throttle pour un ticket clôturé.
   // Évite une croissance illimitée des tableaux internes sur la
   // durée (compte réel, des centaines/milliers de trades). À
   // appeler par l'orchestrateur quand une position est détectée
   // clôturée (LogNewlyClosedTrades).
   //---------------------------------------------------------------
   void              ClearModifyTracking(const ulong ticket)
     {
      int idx = FindModifyTrackIndex(ticket);
      if(idx < 0)
         return;
      int last = ArraySize(m_modifyTrackTicket) - 1;
      if(idx != last)
        {
         m_modifyTrackTicket[idx] = m_modifyTrackTicket[last];
         m_modifyTrackTime[idx]   = m_modifyTrackTime[last];
        }
      ArrayResize(m_modifyTrackTicket, last);
      ArrayResize(m_modifyTrackTime, last);
     }

   //---------------------------------------------------------------
   // Compte les positions ouvertes sous ce Magic Number pour le
   // symbole configuré (utilisé pour alimenter CValidator).
   //---------------------------------------------------------------
   int               CountOpenPositions() const
     {
      int count = 0;
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magicNumber)
            continue;
         count++;
        }
      return(count);
     }
  };

#endif // TRADEMANAGER_MQH
//+------------------------------------------------------------------+
