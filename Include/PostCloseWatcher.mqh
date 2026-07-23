//+------------------------------------------------------------------+
//|                                            PostCloseWatcher.mqh    |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| Description : Analyse du marché APRÈS la clôture d'un trade.      |
//|   CPostCloseWatcher répond directement à une question posée dès   |
//|   le départ : "le trailing coupe-t-il les trades trop tôt ?".     |
//|   Pour chaque trade clôturé, il mesure le mouvement de prix       |
//|   5 / 15 / 30 minutes puis 1h et 4h après la clôture. Si le prix  |
//|   continue largement dans le sens du trade après une sortie       |
//|   modeste, le trailing/BE a probablement coupé trop tôt. Si le    |
//|   marché se retourne fort après la clôture, la sortie a au        |
//|   contraire bien protégé le capital.                               |
//|                                                                    |
//|   MÊME PHILOSOPHIE que CTradeLifecycleTracker : observateur pur,  |
//|   aucune action sur aucune position (le trade est déjà clôturé de |
//|   toute façon). N'écrit aucun fichier lui-même (délégué à         |
//|   CLogger).                                                        |
//|                                                                    |
//|   DIFFÉRENCE avec CSignalRecorder : SignalRecorder suit un SIGNAL |
//|   (exécuté ou non) sur des fenêtres en NOMBRE DE BOUGIES.          |
//|   PostCloseWatcher suit un TRADE RÉELLEMENT CLÔTURÉ sur des        |
//|   fenêtres en TEMPS RÉEL (minutes), car la question posée se pose |
//|   en minutes ("le trailing a-t-il coupé 30 minutes trop tôt ?"),  |
//|   pas en nombre de bougies H1 (une bougie H1 = 60 minutes, bien   |
//|   trop grossier pour les fenêtres courtes de 5/15 minutes).        |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef POSTCLOSEWATCHER_MQH
#define POSTCLOSEWATCHER_MQH

#include "Types.mqh"

// SPostCloseReview (résultat complet d'une revue post-clôture) est
// désormais défini dans Types.mqh - CORRECTIF COMPILATION : ce struct
// est nécessaire à CLogger::LogPostCloseReview(), et Logger.mqh ne
// doit jamais dépendre de PostCloseWatcher.mqh (mauvais sens de
// dépendance, module de bas niveau vs module de haut niveau). Voir
// Types.mqh pour la définition et les commentaires associés.

//+------------------------------------------------------------------+
//| Classe CPostCloseWatcher                                            |
//+------------------------------------------------------------------+
class CPostCloseWatcher
  {
private:
   //---------------------------------------------------------------
   // Entrée en attente de revue (interne, pas exposée hors classe).
   //---------------------------------------------------------------
   struct SPendingReview
     {
      ulong             positionId;
      string            symbol;
      ENUM_SIGNAL_TYPE  type;
      double            exitPrice;
      double            exitProfitMoney;
      datetime          exitTime;
      bool              done5, done15, done30, done1h, done4h;
      double            move5, move15, move30, move1h4, move4h;
     };

   SPendingReview    m_pending[];
   bool              m_enabled;
   bool              m_initialized;

   //---------------------------------------------------------------
   // Mouvement de prix signé dans le sens favorable au trade : pour
   // un BUY, prix actuel - prix de sortie (positif = le marché a
   // continué à monter après la clôture). Pour un SELL, l'inverse.
   // C'est ce signe qui permet de répondre directement à "a-t-on
   // coupé trop tôt ?" sans que l'utilisateur ait à retenir le sens
   // du trade pour interpréter chaque ligne du CSV.
   //---------------------------------------------------------------
   double            SignedMove(const string symbol, const ENUM_SIGNAL_TYPE type, const double exitPrice) const
     {
      double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(currentPrice <= 0.0)
         return(0.0); // Symbole indisponible - ne devrait pas arriver en pratique

      return((type == SIGNAL_BUY) ? (currentPrice - exitPrice) : (exitPrice - currentPrice));
     }

   void              RemovePendingAt(const int index)
     {
      int last = ArraySize(m_pending) - 1;
      if(index != last)
         m_pending[index] = m_pending[last];
      ArrayResize(m_pending, last);
     }

public:
                     CPostCloseWatcher()
     {
      m_enabled     = true;
      m_initialized = false;
     }

   //---------------------------------------------------------------
   // Initialise le watcher. enabled correspond typiquement à
   // InpTrackPostClose (Config.mqh).
   //---------------------------------------------------------------
   bool              Init(const bool enabled = true)
     {
      m_enabled     = enabled;
      m_initialized = true;
      ArrayResize(m_pending, 0);
      return(true);
     }

   bool              IsEnabled() const { return(m_enabled && m_initialized); }

   int               GetPendingCount() const { return(ArraySize(m_pending)); }

   //---------------------------------------------------------------
   // Enregistre un trade venant de clôturer, à suivre pendant les 4
   // prochaines heures. À appeler juste après la détection d'une
   // nouvelle clôture (LogNewlyClosedTrades dans NexusEdgeEA.mq5).
   //---------------------------------------------------------------
   void              RegisterClosedTrade(const ulong positionId, const string symbol, const ENUM_SIGNAL_TYPE type,
                                         const double exitPrice, const double exitProfitMoney, const datetime exitTime)
     {
      if(!IsEnabled())
         return;

      SPendingReview p;
      p.positionId      = positionId;
      p.symbol          = symbol;
      p.type            = type;
      p.exitPrice       = exitPrice;
      p.exitProfitMoney = exitProfitMoney;
      p.exitTime        = exitTime;
      p.done5 = p.done15 = p.done30 = p.done1h = p.done4h = false;
      p.move5 = p.move15 = p.move30 = p.move1h4 = p.move4h = 0.0;

      int n = ArraySize(m_pending);
      ArrayResize(m_pending, n + 1);
      m_pending[n] = p;
     }

   //---------------------------------------------------------------
   // À appeler à chaque tick (opération légère : une boucle sur les
   // trades en attente de revue, avec une simple comparaison de
   // datetime - négligeable en performance, contrairement à un calcul
   // par bougie qui serait trop grossier pour des fenêtres de 5/15
   // minutes). Retourne le nombre de revues COMPLÈTES (les 5 fenêtres
   // atteintes) fraîchement terminées lors de cet appel, pour que
   // l'appelant sache combien de lignes CLogger doit écrire.
   //---------------------------------------------------------------
   int               Update()
     {
      if(!IsEnabled())
         return(0);

      int completedCount = 0;
      datetime now = TimeCurrent();

      for(int i = ArraySize(m_pending) - 1; i >= 0; i--)
        {
         long elapsedSec = (long)(now - m_pending[i].exitTime);

         if(!m_pending[i].done5 && elapsedSec >= 300)
           {
            m_pending[i].move5  = SignedMove(m_pending[i].symbol, m_pending[i].type, m_pending[i].exitPrice);
            m_pending[i].done5  = true;
           }
         if(!m_pending[i].done15 && elapsedSec >= 900)
           {
            m_pending[i].move15 = SignedMove(m_pending[i].symbol, m_pending[i].type, m_pending[i].exitPrice);
            m_pending[i].done15 = true;
           }
         if(!m_pending[i].done30 && elapsedSec >= 1800)
           {
            m_pending[i].move30 = SignedMove(m_pending[i].symbol, m_pending[i].type, m_pending[i].exitPrice);
            m_pending[i].done30 = true;
           }
         if(!m_pending[i].done1h && elapsedSec >= 3600)
           {
            m_pending[i].move1h4 = SignedMove(m_pending[i].symbol, m_pending[i].type, m_pending[i].exitPrice);
            m_pending[i].done1h  = true;
           }
         if(!m_pending[i].done4h && elapsedSec >= 14400)
           {
            m_pending[i].move4h = SignedMove(m_pending[i].symbol, m_pending[i].type, m_pending[i].exitPrice);
            m_pending[i].done4h = true;
           }

         if(m_pending[i].done5 && m_pending[i].done15 && m_pending[i].done30 &&
            m_pending[i].done1h && m_pending[i].done4h)
            completedCount++; // Compté ici, retiré/consommé via PopCompletedReview()
        }

      return(completedCount);
     }

   //---------------------------------------------------------------
   // Extrait et retire UNE revue complète (les 5 fenêtres atteintes),
   // pour que l'appelant l'écrive via CLogger::LogPostCloseReview().
   // Retourne false s'il n'y a plus de revue complète disponible.
   // Conçu pour être appelé en boucle après Update() jusqu'à ce qu'il
   // retourne false, plutôt que de retourner un tableau (plus simple
   // à consommer côté orchestrateur, même pattern que GetRecord() sur
   // CPositionManager).
   //---------------------------------------------------------------
   bool              PopCompletedReview(SPostCloseReview &reviewOut)
     {
      int total = ArraySize(m_pending);
      for(int i = 0; i < total; i++)
        {
         if(m_pending[i].done5 && m_pending[i].done15 && m_pending[i].done30 &&
            m_pending[i].done1h && m_pending[i].done4h)
           {
            reviewOut.positionId      = m_pending[i].positionId;
            reviewOut.symbol          = m_pending[i].symbol;
            reviewOut.type            = m_pending[i].type;
            reviewOut.exitPrice       = m_pending[i].exitPrice;
            reviewOut.exitProfitMoney = m_pending[i].exitProfitMoney;
            reviewOut.exitTime        = m_pending[i].exitTime;
            reviewOut.move5min        = m_pending[i].move5;
            reviewOut.move15min       = m_pending[i].move15;
            reviewOut.move30min       = m_pending[i].move30;
            reviewOut.move1h          = m_pending[i].move1h4;
            reviewOut.move4h          = m_pending[i].move4h;

            RemovePendingAt(i);
            return(true);
           }
        }
      return(false);
     }
  };

#endif // POSTCLOSEWATCHER_MQH
//+------------------------------------------------------------------+
