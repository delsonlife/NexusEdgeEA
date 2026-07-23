//+------------------------------------------------------------------+
//|                                        ProfitProtectionEngine.mqh   |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| REFONTE "DÉCISION UNIQUE" (demande explicite de l'utilisateur,     |
//| 18/07/2026) : ce moteur ne calcule plus qu'UNE SEULE proposition   |
//| finale de Stop Loss par tick, quel que soit le nombre de           |
//| mécanismes de protection actifs.                                   |
//|                                                                    |
//|   AVANT : BreakEven, Trailing et Profit Guard tentaient chacun,    |
//|   indépendamment, un PositionModify() - le throttle partagé de    |
//|   CTradeManager empêchait un double envoi au même tick, mais de    |
//|   façon indirecte (par chance de timing), pas par construction.    |
//|                                                                    |
//|   APRÈS :                                                          |
//|     BreakEven   \                                                  |
//|     Trailing     \                                                 |
//|     Structure      >---> ComputeFinalStopLevel() ---> Stop unique  |
//|     PeakPercent   /            (une seule comparaison,             |
//|     Emergency     /             un seul appel ApplyExternalProtection)|
//|                                                                    |
//|   Chaque mécanisme est un CALCULATEUR (IProtectionLevelCalculator),|
//|   appelé de façon UNIFORME via un contexte partagé (SProtectionContext,|
//|   Types.mqh). Le moteur ne connaît AUCUN détail spécifique à un    |
//|   calculateur particulier - il se contente de collecter les        |
//|   candidats et de garder le plus protecteur.                       |
//|                                                                    |
//| EXTENSIBILITÉ SMC (demande explicite, point 3) : ajouter un futur  |
//|   concept (FVG, Order Block, zone de liquidité, Equal High/Low,    |
//|   Premium/Discount, Mitigation Block) = écrire UNE NOUVELLE classe |
//|   qui implémente IProtectionLevelCalculator, puis l'enregistrer    |
//|   dans Init(). AUCUNE ligne de ComputeFinalStopLevel() n'a besoin  |
//|   d'être modifiée - c'est le contrat de cette interface.           |
//|                                                                    |
//| EXCEPTION D'ARCHITECTURE VOLONTAIRE ET DOCUMENTÉE (inchangée      |
//| depuis la version précédente) : CStructureLevelCalculator est la  |
//| SEULE connexion Structure -> Exécution du projet, strictement      |
//| bornée à la protection d'un profit déjà acquis, jamais aux entrées.|
//|                                                                    |
//| TRAÇABILITÉ (demande explicite, point 2) : ComputeFinalStopLevel() |
//| produit désormais, en plus du niveau retenu, une note détaillée    |
//| (structure utilisée, PeakProfit, profit sécurisé, Capture Ratio    |
//| estimé) - voir BuildDetailNote(). Cette note est transmise telle   |
//| quelle au champ "note" de SPositionEvent (déjà prévu à cet effet   |
//| dans Types.mqh, aucune nouvelle structure nécessaire).             |
//|                                                                    |
//| PHILOSOPHIE (inchangée) : module d'EXÉCUTION (comme CTradeManager),|
//|   pas un observateur passif. N'importe jamais <Trade/Trade.mqh> et |
//|   n'appelle jamais PositionModify()/PositionClose() lui-même -     |
//|   uniquement via CTradeManager::ApplyExternalProtection()/         |
//|   ApplyExternalClose(), qui reste le seul point de passage vers    |
//|   le broker dans tout le projet.                                   |
//|                                                                    |
//| LIMITE HONNÊTE DOCUMENTÉE (inchangée) : le "volume" demandé pour   |
//|   la protection d'urgence n'est pas mesurable aujourd'hui (aucun   |
//|   module de volume réel dans le projet). Le momentum de            |
//|   CMarketContext sert de proxy honnête pour l'accélération du prix.|
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef PROFITPROTECTIONENGINE_MQH
#define PROFITPROTECTIONENGINE_MQH

#include "Types.mqh"
#include "Utilities.mqh"
#include "MarketStructure.mqh"
#include "TradeManager.mqh"

//+------------------------------------------------------------------+
//| INTERFACE - Contrat commun à TOUS les calculateurs de niveau de   |
//| protection (BreakEven, Trailing, Structure, PeakPercent, Emergency,|
//| et demain FVG/Order Block/Liquidité/Equal High-Low/Premium-Discount|
//| /Mitigation Block). C'est CETTE interface qui rend le moteur       |
//| extensible sans refonte : ComputeFinalStopLevel() n'appelle que    |
//| ces 3 méthodes, jamais une classe concrète directement.            |
//+------------------------------------------------------------------+
interface IProtectionLevelCalculator
  {
   //---------------------------------------------------------------
   // Calcule un niveau de SL candidat à partir du contexte partagé.
   // Retourne false si ce calculateur n'a rien à proposer ce tick
   // (cas normal la plupart du temps - ex: pas encore de Higher Low
   // confirmé, ou trade pas encore armé). Doit stocker en interne le
   // détail de son calcul (voir GetLastDetail()) s'il gagne.
   //---------------------------------------------------------------
   bool   ComputeLevel(const SProtectionContext &ctx, double &levelOut);

   // Libellé court, utilisé comme "cause" dans TradeEvents.csv
   string GetName() const;

   // Catégorie de haut niveau (pour compter par mécanisme dans TradeFull.csv)
   ENUM_PROTECTION_SOURCE GetSource() const;

   // Détail optionnel du DERNIER calcul réussi de ce calculateur
   // (ex: "Higher Low" / "Lower High" pour CStructureLevelCalculator).
   // Chaîne vide par défaut pour un calculateur qui n'a rien à ajouter.
   string GetLastDetail() const;

   //---------------------------------------------------------------
   // CORRECTIF (bug de régression détecté par analyse de backtest -
   // BreakEven/Trailing à 0% d'activation sur toute une année alors
   // qu'ils sont activés par défaut). Distingue :
   //   - false (BreakEven, Trailing) : mécanismes à SEUIL PROPRE,
   //     évalués dès le premier tick, indépendamment de l'armement du
   //     Profit Guard (1R de profit par défaut) - c'est leur
   //     comportement historique, jamais censé changer avec ce refactor.
   //   - true (Structure, PeakPercent, Emergency) : nécessitent que
   //     le trade soit armé (Niveau 1) avant d'être évalués - c'est
   //     la hiérarchie originale demandée (Niveau 1 = préalable
   //     UNIQUEMENT aux Niveaux 2-4, jamais à BreakEven/Trailing).
   //---------------------------------------------------------------
   bool   RequiresArming() const;

   //---------------------------------------------------------------
   // NOUVEAU (demande explicite point 1). Raison précise du DERNIER
   // échec de ComputeLevel() (ex: "profit actuel 210 pts < seuil 300
   // pts"). Chaîne vide si le dernier appel a réussi, ou si aucun
   // appel n'a encore eu lieu. Consultée uniquement en mode diagnostic
   // (InpProfitGuardDiagnosticMode) - coût nul sinon, la construction
   // de la chaîne se fait de toute façon à chaque appel de ComputeLevel
   // (peu coûteux : quelques StringFormat courts, pas de boucle).
   //---------------------------------------------------------------
   string GetLastIneligibilityReason() const;
  };

//+------------------------------------------------------------------+
//| CALCULATEUR - Break Even                                           |
//+------------------------------------------------------------------+
class CBreakEvenLevelCalculator : public IProtectionLevelCalculator
  {
private:
   CTradeManager    *m_tradeManager; // Référence non propriétaire
   double            m_triggerPoints;
   double            m_lockPoints;
   string            m_lastReason; // NOUVEAU

public:
                     CBreakEvenLevelCalculator(CTradeManager *tradeManager, const double triggerPoints, const double lockPoints)
     {
      m_tradeManager  = tradeManager;
      m_triggerPoints = triggerPoints;
      m_lockPoints    = lockPoints;
      m_lastReason    = "";
     }

   bool              ComputeLevel(const SProtectionContext &ctx, double &levelOut)
     {
      if(m_tradeManager == NULL)
        {
         m_lastReason = "CTradeManager non disponible";
         return(false);
        }
      return(m_tradeManager.ComputeBreakEvenLevel(ctx.ticket, m_triggerPoints, m_lockPoints, levelOut, m_lastReason));
     }

   string            GetName() const { return("BreakEven"); }
   ENUM_PROTECTION_SOURCE GetSource() const { return(PROTECTION_SOURCE_BREAKEVEN); }
   string            GetLastDetail() const { return(""); }
   bool              RequiresArming() const { return(false); }
   string            GetLastIneligibilityReason() const { return(m_lastReason); }
  };

//+------------------------------------------------------------------+
//| CALCULATEUR - Trailing (classique ou ATR, selon la configuration) |
//+------------------------------------------------------------------+
class CTrailingLevelCalculator : public IProtectionLevelCalculator
  {
private:
   CTradeManager    *m_tradeManager;
   bool              m_useATR;
   double            m_startPoints;
   double            m_distancePoints; // Classique uniquement
   double            m_stepPoints;
   double            m_atrMultiplier;  // ATR uniquement
   string            m_lastDetail;
   string            m_lastReason; // NOUVEAU

public:
                     CTrailingLevelCalculator(CTradeManager *tradeManager, const bool useATR,
                                              const double startPoints, const double distancePoints,
                                              const double stepPoints, const double atrMultiplier)
     {
      m_tradeManager    = tradeManager;
      m_useATR          = useATR;
      m_startPoints     = startPoints;
      m_distancePoints  = distancePoints;
      m_stepPoints      = stepPoints;
      m_atrMultiplier   = atrMultiplier;
      m_lastDetail      = "";
      m_lastReason      = "";
     }

   bool              ComputeLevel(const SProtectionContext &ctx, double &levelOut)
     {
      if(m_tradeManager == NULL)
        {
         m_lastReason = "CTradeManager non disponible";
         return(false);
        }

      bool ok;
      if(m_useATR)
        {
         ok = m_tradeManager.ComputeTrailingATRLevel(ctx.ticket, ctx.atrValue, m_atrMultiplier,
                                                      m_startPoints, m_stepPoints, levelOut, m_lastReason);
         m_lastDetail = "TrailingATR";
        }
      else
        {
         ok = m_tradeManager.ComputeTrailingLevel(ctx.ticket, m_startPoints, m_distancePoints, m_stepPoints, levelOut, m_lastReason);
         m_lastDetail = "TrailingClassique";
        }
      return(ok);
     }

   string            GetName() const { return(m_useATR ? "TrailingATR" : "TrailingClassique"); }
   ENUM_PROTECTION_SOURCE GetSource() const { return(PROTECTION_SOURCE_TRAILING); }
   string            GetLastDetail() const { return(m_lastDetail); }
   bool              RequiresArming() const { return(false); }
   string            GetLastIneligibilityReason() const { return(m_lastReason); }
  };

//+------------------------------------------------------------------+
//| CALCULATEUR - Structure (Niveau 2, priorité la plus haute une     |
//| fois disponible). SEULE CONNEXION Structure -> Exécution du       |
//| projet (voir exception documentée en tête de fichier).             |
//+------------------------------------------------------------------+
class CStructureLevelCalculator : public IProtectionLevelCalculator
  {
private:
   CMarketStructure *m_structure; // Référence non propriétaire
   double            m_bufferATRMult;
   string            m_lastDetail;
   string            m_lastReason; // NOUVEAU

public:
                     CStructureLevelCalculator(CMarketStructure *structure, const double bufferATRMult)
     {
      m_structure     = structure;
      m_bufferATRMult = bufferATRMult;
      m_lastDetail    = "";
      m_lastReason    = "";
     }

   bool              ComputeLevel(const SProtectionContext &ctx, double &levelOut)
     {
      levelOut = 0.0;
      if(m_structure == NULL)
        {
         m_lastReason = "CMarketStructure non disponible";
         return(false);
        }
      if(ctx.atrValue <= 0.0 || ctx.atrValue == EMPTY_VALUE)
        {
         m_lastReason = "ATR indisponible";
         return(false);
        }

      double buffer = ctx.atrValue * m_bufferATRMult;

      if(ctx.type == SIGNAL_BUY)
        {
         double higherLow = m_structure.GetLastSwingLowPrice();
         double prevLow    = m_structure.GetPrevSwingLowPrice();
         if(higherLow <= 0.0 || prevLow <= 0.0)
           {
            m_lastReason = "aucun swing low confirme pour l'instant";
            return(false);
           }
         if(higherLow <= prevLow)
           {
            m_lastReason = "dernier swing low n'est pas un Higher Low";
            return(false);
           }
         if(m_structure.GetCurrentBias() != STRUCTURE_BIAS_BULLISH)
           {
            m_lastReason = "Higher Low trouve mais BOS haussier non confirme (biais structure pas encore BULLISH)";
            return(false);
           }
         levelOut     = higherLow - buffer;
         m_lastDetail = "Higher Low";
         return(true);
        }
      else // SIGNAL_SELL
        {
         double lowerHigh = m_structure.GetLastSwingHighPrice();
         double prevHigh   = m_structure.GetPrevSwingHighPrice();
         if(lowerHigh <= 0.0 || prevHigh <= 0.0)
           {
            m_lastReason = "aucun swing high confirme pour l'instant";
            return(false);
           }
         if(lowerHigh >= prevHigh)
           {
            m_lastReason = "dernier swing high n'est pas un Lower High";
            return(false);
           }
         if(m_structure.GetCurrentBias() != STRUCTURE_BIAS_BEARISH)
           {
            m_lastReason = "Lower High trouve mais BOS baissier non confirme (biais structure pas encore BEARISH)";
            return(false);
           }
         levelOut     = lowerHigh + buffer;
         m_lastDetail = "Lower High";
         return(true);
        }
     }

   string            GetName() const { return("ProfitGuard_Structure"); }
   ENUM_PROTECTION_SOURCE GetSource() const { return(PROTECTION_SOURCE_STRUCTURE); }
   string            GetLastDetail() const { return(m_lastDetail); }
   bool              RequiresArming() const { return(true); }
   string            GetLastIneligibilityReason() const { return(m_lastReason); }
  };

//+------------------------------------------------------------------+
//| CALCULATEUR - Filet PeakProfit (Niveau 3)                          |
//+------------------------------------------------------------------+
class CPeakPercentLevelCalculator : public IProtectionLevelCalculator
  {
private:
   double            m_minRetainPercent;
   string            m_lastReason; // NOUVEAU

   double            MoneyToPriceLevel(const ENUM_SIGNAL_TYPE type, const double entryPrice, const double moneyToRetain,
                                       const double tickValue, const double tickSize, const double lot) const
     {
      if(tickValue <= 0.0 || tickSize <= 0.0 || lot <= 0.0)
         return(0.0);
      double moneyPerPricePoint = (tickValue / tickSize) * lot;
      if(moneyPerPricePoint <= 0.0)
         return(0.0);
      double priceDistance = moneyToRetain / moneyPerPricePoint;
      return((type == SIGNAL_BUY) ? (entryPrice + priceDistance) : (entryPrice - priceDistance));
     }

public:
                     CPeakPercentLevelCalculator(const double minRetainPercent)
     {
      m_minRetainPercent = minRetainPercent;
      m_lastReason        = "";
     }

   bool              ComputeLevel(const SProtectionContext &ctx, double &levelOut)
     {
      levelOut = 0.0;
      if(ctx.peakProfitMoney <= 0.0)
        {
         m_lastReason = "PeakProfit nul (le trade n'a jamais ete en profit flottant)";
         return(false);
        }

      double retainMoney = ctx.peakProfitMoney * (m_minRetainPercent / 100.0);
      double level = MoneyToPriceLevel(ctx.type, ctx.entryPrice, retainMoney, ctx.tickValue, ctx.tickSize, ctx.lot);
      if(level <= 0.0)
        {
         m_lastReason = "conversion argent->prix impossible (tickValue/tickSize/lot invalides)";
         return(false);
        }

      levelOut = level;
      return(true);
     }

   string            GetName() const { return("ProfitGuard_PeakPercent"); }
   ENUM_PROTECTION_SOURCE GetSource() const { return(PROTECTION_SOURCE_PEAK_PERCENT); }
   string            GetLastDetail() const { return(""); }
   bool              RequiresArming() const { return(true); }
   string            GetLastIneligibilityReason() const { return(m_lastReason); }
  };

//+------------------------------------------------------------------+
//| CALCULATEUR - Urgence (Niveau 4)                                    |
//|                                                                    |
//| NOTE HONNÊTE : le critère "volume" n'est pas inclus - voir la      |
//| limite documentée en tête de fichier.                              |
//+------------------------------------------------------------------+
class CEmergencyLevelCalculator : public IProtectionLevelCalculator
  {
private:
   CMarketStructure *m_structure;
   bool              m_enabled;
   double            m_drawdownPercent;
   double            m_momentumThreshold;
   bool              m_closeImmediately;
   double            m_retainPercent;
   bool              m_lastCloseNow;
   string            m_lastReason; // NOUVEAU

   double            MoneyToPriceLevel(const ENUM_SIGNAL_TYPE type, const double entryPrice, const double moneyToRetain,
                                       const double tickValue, const double tickSize, const double lot) const
     {
      if(tickValue <= 0.0 || tickSize <= 0.0 || lot <= 0.0)
         return(0.0);
      double moneyPerPricePoint = (tickValue / tickSize) * lot;
      if(moneyPerPricePoint <= 0.0)
         return(0.0);
      double priceDistance = moneyToRetain / moneyPerPricePoint;
      return((type == SIGNAL_BUY) ? (entryPrice + priceDistance) : (entryPrice - priceDistance));
     }

public:
                     CEmergencyLevelCalculator(CMarketStructure *structure, const bool enabled,
                                               const double drawdownPercent, const double momentumThreshold,
                                               const bool closeImmediately, const double retainPercent)
     {
      m_structure         = structure;
      m_enabled           = enabled;
      m_drawdownPercent   = drawdownPercent;
      m_momentumThreshold = momentumThreshold;
      m_closeImmediately  = closeImmediately;
      m_retainPercent     = retainPercent;
      m_lastCloseNow      = false;
      m_lastReason        = "";
     }

   bool              ComputeLevel(const SProtectionContext &ctx, double &levelOut)
     {
      levelOut = 0.0;
      m_lastCloseNow = false;
      if(!m_enabled)
        {
         m_lastReason = "desactive (InpProfitGuardEmergencyEnabled=false)";
         return(false);
        }
      if(m_structure == NULL)
        {
         m_lastReason = "CMarketStructure non disponible";
         return(false);
        }
      if(ctx.peakProfitMoney <= 0.0)
        {
         m_lastReason = "PeakProfit nul";
         return(false);
        }

      string lastEvent = m_structure.GetLastEventDescription();
      bool chochAgainst = (ctx.type == SIGNAL_BUY  && lastEvent == "CHOCH_BEARISH") ||
                         (ctx.type == SIGNAL_SELL && lastEvent == "CHOCH_BULLISH");
      if(!chochAgainst)
        {
         m_lastReason = "aucun CHOCH contraire detecte";
         return(false); // Condition nécessaire, pas suffisante seule
        }

      double drawdownFromPeakPercent = CUtilities::SafeDivide(ctx.peakProfitMoney - ctx.currentProfitMoney, ctx.peakProfitMoney, 0.0) * 100.0;
      bool severeDrawdown = (drawdownFromPeakPercent >= m_drawdownPercent);

      bool momentumReversal = (ctx.type == SIGNAL_BUY  && ctx.currentMomentum <= -m_momentumThreshold) ||
                             (ctx.type == SIGNAL_SELL && ctx.currentMomentum >=  m_momentumThreshold);

      if(!severeDrawdown && !momentumReversal)
        {
         m_lastReason = StringFormat("CHOCH contraire detecte mais ni drawdown severe (%.0f%% < seuil %.0f%%) ni retournement momentum",
                                     drawdownFromPeakPercent, m_drawdownPercent);
         return(false);
        }

      if(m_closeImmediately)
        {
         m_lastCloseNow = true;
         levelOut = ctx.currentSL; // Non utilisé si fermeture immédiate, mais évite un niveau à 0.0 ambigu
         return(true);
        }

      double emergencyRetain = ctx.currentProfitMoney * (m_retainPercent / 100.0);
      double level = MoneyToPriceLevel(ctx.type, ctx.entryPrice, emergencyRetain, ctx.tickValue, ctx.tickSize, ctx.lot);
      if(level <= 0.0)
        {
         m_lastReason = "conversion argent->prix impossible (tickValue/tickSize/lot invalides)";
         return(false);
        }

      levelOut = level;
      return(true);
     }

   string            GetName() const { return("ProfitGuard_Emergency"); }
   ENUM_PROTECTION_SOURCE GetSource() const { return(PROTECTION_SOURCE_EMERGENCY); }
   string            GetLastDetail() const { return(""); }
   bool              RequiresArming() const { return(true); }
   string            GetLastIneligibilityReason() const { return(m_lastReason); }
   bool              IsLastCloseNow() const { return(m_lastCloseNow); } // Consulté séparément par ComputeFinalStopLevel
  };

//+------------------------------------------------------------------+
//| Classe CProfitProtectionEngine                                       |
//+------------------------------------------------------------------+
class CProfitProtectionEngine
  {
private:
   //---------------------------------------------------------------
   // État par trade suivi (armement + PeakProfit). Structure INTERNE.
   //---------------------------------------------------------------
   struct SGuardState
     {
      ulong    positionId;
      ENUM_SIGNAL_TYPE type;
      double   entryPrice;
      double   lot;
      double   riskMoneyPerR;
      double   peakProfitMoney;
      bool     armed;
      datetime openTime;             // NOUVEAU (point 2) - pour calculer le temps avant activation
      bool     firstActivationDone[]; // NOUVEAU (point 2) - un booleen par calculateur (index = position dans m_calculators)
      int      lastWinningIndex;      // NOUVEAU (point 3) - dernier calculateur retenu pour ce trade (-1 = aucun)
     };

   SGuardState       m_states[];
   bool              m_enabled;
   bool              m_initialized;

   ENUM_PROFIT_GUARD_ACTIVATION_MODE m_activationMode;
   double            m_activationR;
   double            m_activationMoney;

   // --- Calculateurs enregistrés (ordre = ordre de calcul, PAS un
   // ordre de priorité : le plus protecteur gagne toujours, quel que
   // soit l'ordre dans ce tableau) ---
   IProtectionLevelCalculator *m_calculators[];
   CEmergencyLevelCalculator  *m_emergencyCalculator; // Référence typée séparée, pour consulter IsLastCloseNow()

   // --- NOUVEAU (demande explicite) : statistiques par calculateur,
   // parallèles à m_calculators (même index). Trois compteurs distincts
   // et complémentaires :
   //   proposed  : nombre de fois où ComputeLevel() a retourné true
   //               (le calculateur AVAIT quelque chose à proposer ce tick)
   //   retained  : nombre de fois où ce candidat a été le plus protecteur
   //               (a "gagné" la comparaison face aux autres)
   //   applied   : nombre de fois où la modification a RÉELLEMENT été
   //               envoyée au broker avec succès (peut être < retained
   //               si le throttle partagé de CTradeManager a bloqué la
   //               tentative - cas rare mais réel, voir RecordApplied())
   int               m_proposedCount[];
   int               m_retainedCount[];
   int               m_appliedCount[];

   // --- NOUVEAU (demande explicite point 2) : temps de réaction.
   // Sommes accumulées à la PREMIÈRE activation de chaque calculateur
   // sur chaque trade (voir m_states[].firstActivationDone[]) -
   // divisées par m_countFirstActivation[i] pour obtenir des moyennes
   // dans GetActivationReport().
   long              m_sumTimeToActivationSec[];
   double            m_sumProfitAtActivation[];
   int               m_countFirstActivation[];

   // --- NOUVEAU (demande explicite point 3) : efficacité réelle.
   // DÉFINITION RETENUE (documentée pour éviter toute ambiguïté) :
   // une modification par le calculateur X est comptée "efficace" si
   // ce calculateur était le DERNIER à avoir modifié le SL au moment
   // de la clôture du trade, ET que le trade s'est clôturé sur un SL
   // touché (pas TP, pas fermeture manuelle/EA), ET que le profit
   // final était >= 0. LIMITE ASSUMÉE : un mécanisme qui a sécurisé un
   // gain puis a été remplacé par une protection encore plus stricte
   // (qui, elle, a fini par être touchée) n'est PAS crédité ici - seul
   // le DERNIER mécanisme actif au moment de la clôture est évalué.
   // Voir RecordTradeClosed().
   int               m_effectiveCount[];

   bool              m_diagnosticMode; // NOUVEAU - trace détaillée par tick (voir ComputeFinalStopLevel)

   int               FindIndex(const ulong positionId) const
     {
      int total = ArraySize(m_states);
      for(int i = 0; i < total; i++)
        {
         if(m_states[i].positionId == positionId)
            return(i);
        }
      return(-1);
     }

   bool              IsMoreProtective(const ENUM_SIGNAL_TYPE type, const double candidatePrice, const double referencePrice) const
     {
      if(candidatePrice <= 0.0)
         return(false);
      return((type == SIGNAL_BUY) ? (candidatePrice > referencePrice) : (candidatePrice < referencePrice));
     }

   //---------------------------------------------------------------
   // NOUVEAU (demande explicite point 2 - temps de réaction). Appelée
   // à chaque victoire d'un calculateur ; n'accumule les statistiques
   // QUE la toute PREMIÈRE fois qu'un calculateur donné gagne sur un
   // trade donné (m_states[idx].firstActivationDone[calcIdx]) - les
   // activations suivantes du même mécanisme sur le même trade ne
   // biaisent pas la moyenne "temps avant activation" (qui n'a de sens
   // que pour la PREMIÈRE fois).
   //---------------------------------------------------------------
   void              RecordFirstActivationIfNeeded(const int stateIdx, const int calcIdx, const double currentProfitMoney)
     {
      if(calcIdx < 0 || calcIdx >= ArraySize(m_states[stateIdx].firstActivationDone))
         return;
      if(m_states[stateIdx].firstActivationDone[calcIdx])
         return; // Déjà comptabilisé pour ce trade - pas une "première" activation

      m_states[stateIdx].firstActivationDone[calcIdx] = true;
      long elapsedSec = (long)(TimeCurrent() - m_states[stateIdx].openTime);
      m_sumTimeToActivationSec[calcIdx] += elapsedSec;
      m_sumProfitAtActivation[calcIdx]  += currentProfitMoney;
      m_countFirstActivation[calcIdx]++;
     }

   //---------------------------------------------------------------
   // NOUVEAU (traçabilité, demande explicite point 2). Construit la
   // note détaillée jointe à l'événement TradeEvents.csv - reprend
   // exactement le format demandé.
   //---------------------------------------------------------------
   string            BuildDetailNote(const string mechanismName, const string mechanismDetail,
                                     const double peakProfitMoney, const double securedProfitMoney) const
     {
      double captureRatioEstimate = (peakProfitMoney > 0.0)
                                    ? CUtilities::SafeDivide(securedProfitMoney, peakProfitMoney, 0.0) * 100.0
                                    : 0.0;

      string note = StringFormat("Mecanisme=%s", mechanismName);
      if(mechanismDetail != "")
         note += StringFormat(" | Structure=%s", mechanismDetail);
      note += StringFormat(" | PeakProfit=%.2f$ | ProfitSecurise=%.2f$ | CaptureRatioEstime=%.1f%%",
                           peakProfitMoney, securedProfitMoney, captureRatioEstimate);
      return(note);
     }

public:
                     CProfitProtectionEngine()
     {
      m_enabled              = true;
      m_initialized          = false;
      m_emergencyCalculator  = NULL;
      m_diagnosticMode       = false;
     }

                    ~CProfitProtectionEngine()
     {
      int total = ArraySize(m_calculators);
      for(int i = 0; i < total; i++)
        {
         if(CheckPointer(m_calculators[i]) == POINTER_DYNAMIC)
            delete m_calculators[i];
        }
     }

   //---------------------------------------------------------------
   // Initialise le moteur ET construit tous les calculateurs. C'est
   // ICI, et UNIQUEMENT ici, qu'un futur calculateur SMC (FVG, Order
   // Block, Liquidité, Equal High/Low, Premium/Discount, Mitigation
   // Block) devra être ajouté - une ligne "new CXxxCalculator(...)"
   // suivie d'un ArrayResize/assignation, rien d'autre à toucher dans
   // tout le fichier.
   //---------------------------------------------------------------
   bool              Init(CTradeManager *tradeManager, CMarketStructure *structure,
                          const bool useBreakEven, const double breakEvenTrigger, const double breakEvenLock,
                          const bool useTrailingATR, const bool useTrailingClassic,
                          const double trailingStart, const double trailingDistance, const double trailingStep,
                          const double atrMultiplier,
                          const bool useProfitGuardLevels,
                          const ENUM_PROFIT_GUARD_ACTIVATION_MODE activationMode,
                          const double activationR, const double activationMoney,
                          const double structureBufferATR, const double minRetainPercent,
                          const bool emergencyEnabled, const double emergencyDrawdownPercent,
                          const double emergencyMomentumThreshold, const bool emergencyCloseImmediately,
                          const double emergencyRetainPercent, const bool diagnosticMode = false)
     {
      // Le moteur lui-même est TOUJOURS actif structurellement - c'est
      // chaque calculateur qui est individuellement enregistré ou non,
      // selon SON PROPRE interrupteur (InpUseBreakEven, InpUseTrailingStop,
      // InpUseProfitGuard...). Ainsi, désactiver le Profit Guard
      // (useProfitGuardLevels=false) n'a AUCUN effet de bord sur
      // BreakEven/Trailing, qui restent gérés par leurs propres flags.
      m_enabled         = true;
      m_activationMode  = activationMode;
      m_activationR     = activationR;
      m_activationMoney = activationMoney;
      m_diagnosticMode  = diagnosticMode; // NOUVEAU
      m_initialized     = true;
      ArrayResize(m_states, 0);

      // --- Construction des calculateurs (ordre indifférent, voir IsMoreProtective) ---
      ArrayResize(m_calculators, 0);
      int n = 0;

      if(useBreakEven)
        {
         ArrayResize(m_calculators, n + 1);
         m_calculators[n] = new CBreakEvenLevelCalculator(tradeManager, breakEvenTrigger, breakEvenLock);
         n++;
        }

      if(useTrailingATR || useTrailingClassic)
        {
         ArrayResize(m_calculators, n + 1);
         m_calculators[n] = new CTrailingLevelCalculator(tradeManager, useTrailingATR, trailingStart,
                                                          trailingDistance, trailingStep, atrMultiplier);
         n++;
        }

      if(useProfitGuardLevels)
        {
         ArrayResize(m_calculators, n + 1);
         m_calculators[n] = new CStructureLevelCalculator(structure, structureBufferATR);
         n++;

         ArrayResize(m_calculators, n + 1);
         m_calculators[n] = new CPeakPercentLevelCalculator(minRetainPercent);
         n++;

         m_emergencyCalculator = new CEmergencyLevelCalculator(structure, emergencyEnabled, emergencyDrawdownPercent,
                                                                emergencyMomentumThreshold, emergencyCloseImmediately,
                                                                emergencyRetainPercent);
         ArrayResize(m_calculators, n + 1);
         m_calculators[n] = m_emergencyCalculator;
         n++;
        }

      // NOUVEAU : dimensionnement des compteurs par calculateur, une fois
      // TOUS les calculateurs construits (n final = ArraySize(m_calculators)).
      ArrayResize(m_proposedCount, n);
      ArrayResize(m_retainedCount, n);
      ArrayResize(m_appliedCount, n);
      ArrayResize(m_sumTimeToActivationSec, n);
      ArrayResize(m_sumProfitAtActivation, n);
      ArrayResize(m_countFirstActivation, n);
      ArrayResize(m_effectiveCount, n);
      for(int i = 0; i < n; i++)
        {
         m_proposedCount[i]          = 0;
         m_retainedCount[i]          = 0;
         m_appliedCount[i]           = 0;
         m_sumTimeToActivationSec[i] = 0;
         m_sumProfitAtActivation[i]  = 0.0;
         m_countFirstActivation[i]   = 0;
         m_effectiveCount[i]         = 0;
        }

      return(true);
     }

   bool              IsEnabled() const { return(m_enabled && m_initialized); }
   bool              IsTracked(const ulong positionId) const { return(FindIndex(positionId) >= 0); }

   //---------------------------------------------------------------
   // À appeler à l'ouverture du trade. Calcule et stocke 1R en $.
   //---------------------------------------------------------------
   void              RegisterTrade(const ulong positionId, const ENUM_SIGNAL_TYPE type,
                                   const double entryPrice, const double slInitial, const double lot,
                                   const double tickValue, const double tickSize)
     {
      if(!IsEnabled())
         return;
      if(FindIndex(positionId) >= 0)
         return;

      double riskPriceDistance = MathAbs(entryPrice - slInitial);
      double riskMoney = 0.0;
      if(tickSize > 0.0)
         riskMoney = (riskPriceDistance / tickSize) * tickValue * lot;

      SGuardState s;
      s.positionId     = positionId;
      s.type            = type;
      s.entryPrice      = entryPrice;
      s.lot             = lot;
      s.riskMoneyPerR   = riskMoney;
      s.peakProfitMoney = 0.0;
      s.armed           = false;
      s.openTime        = TimeCurrent(); // NOUVEAU (point 2)
      s.lastWinningIndex = -1;            // NOUVEAU (point 3)
      ArrayResize(s.firstActivationDone, ArraySize(m_calculators)); // NOUVEAU (point 2)
      for(int i = 0; i < ArraySize(s.firstActivationDone); i++)
         s.firstActivationDone[i] = false;

      int n = ArraySize(m_states);
      ArrayResize(m_states, n + 1);
      m_states[n] = s;
     }

   //---------------------------------------------------------------
   // À appeler à CHAQUE TICK. Met à jour le PeakProfit et l'armement -
   // même principe que CTradeLifecycleTracker::Update() (observation
   // pure, aucun calcul de protection ici).
   //---------------------------------------------------------------
   void              Update(const ulong positionId, const double currentProfitMoney)
     {
      if(!IsEnabled())
         return;
      int idx = FindIndex(positionId);
      if(idx < 0)
         return;

      if(currentProfitMoney > m_states[idx].peakProfitMoney)
         m_states[idx].peakProfitMoney = currentProfitMoney;

      if(!m_states[idx].armed)
        {
         bool shouldArm = (m_activationMode == ACTIVATION_BY_R)
                         ? (m_states[idx].riskMoneyPerR > 0.0 && currentProfitMoney >= m_states[idx].riskMoneyPerR * m_activationR)
                         : (currentProfitMoney >= m_activationMoney);
         if(shouldArm)
            m_states[idx].armed = true;
        }
     }

   bool              IsArmed(const ulong positionId) const
     {
      int idx = FindIndex(positionId);
      if(idx < 0)
         return(false);
      return(m_states[idx].armed);
     }

   //---------------------------------------------------------------
   // DÉCISION UNIQUE - Interroge TOUS les calculateurs enregistrés,
   // ne retient que le plus protecteur, produit la note détaillée de
   // traçabilité. C'est la SEULE méthode de calcul appelée par
   // l'orchestrateur - elle ne connaît jamais le détail interne d'un
   // calculateur particulier.
   //---------------------------------------------------------------
   bool              ComputeFinalStopLevel(const ulong positionId, const double currentSL, const double currentTP,
                                           const double currentProfitMoney,
                                           CMarketStructure &structure, const double atrValue, const double currentMomentum,
                                           const double tickValue, const double tickSize,
                                           double &finalSLOut, ENUM_PROTECTION_SOURCE &sourceOut,
                                           string &noteOut, bool &closeNowOut, string &diagnosticTraceOut)
     {
      finalSLOut  = currentSL;
      sourceOut   = PROTECTION_SOURCE_NONE;
      noteOut     = "";
      closeNowOut = false;
      diagnosticTraceOut = "";

      if(!IsEnabled())
         return(false);

      int idx = FindIndex(positionId);
      if(idx < 0)
         return(false); // Trade non enregistré - rien à calculer, aucune donnée disponible

      SProtectionContext ctx;
      ctx.ticket             = positionId;
      ctx.type                = m_states[idx].type;
      ctx.entryPrice          = m_states[idx].entryPrice;
      ctx.currentSL           = currentSL;
      ctx.currentTP           = currentTP;
      ctx.peakProfitMoney     = m_states[idx].peakProfitMoney;
      ctx.currentProfitMoney  = currentProfitMoney;
      ctx.atrValue            = atrValue;
      ctx.currentMomentum     = currentMomentum;
      ctx.tickValue           = tickValue;
      ctx.tickSize            = tickSize;
      ctx.lot                 = m_states[idx].lot;

      double bestCandidate = currentSL;
      int    bestIdx       = -1; // Index du calculateur gagnant dans m_calculators

      // NOUVEAU (mode diagnostic, demande explicite) : en-tête de la trace,
      // uniquement construite si m_diagnosticMode est actif - coût nul
      // sinon (aucune concaténation de chaîne inutile).
      if(m_diagnosticMode)
         diagnosticTraceOut = StringFormat("Trade PositionID=%I64u\r\nTick %s\r\n", positionId, TimeToString(TimeCurrent(), TIME_SECONDS));

      int total = ArraySize(m_calculators);
      for(int i = 0; i < total; i++)
        {
         // CORRECTIF (régression détectée par analyse de backtest réel :
         // BreakEven/Trailing à 0% d'activation sur toute une année) :
         // seuls les calculateurs Structure/PeakPercent/Emergency exigent
         // que le trade soit armé (Niveau 1). BreakEven/Trailing ont leur
         // PROPRE seuil (300/150 points par défaut) et doivent être
         // évalués dès le premier tick, comme avant ce moteur unifié.
         if(m_calculators[i].RequiresArming() && !m_states[idx].armed)
           {
            if(m_diagnosticMode)
               diagnosticTraceOut += StringFormat("%s :\r\n  non eligible (Profit Guard pas encore arme)\r\n", m_calculators[i].GetName());
            continue;
           }

         double candidateLevel;
         bool hasCandidate = m_calculators[i].ComputeLevel(ctx, candidateLevel);

         if(!hasCandidate)
           {
            if(m_diagnosticMode)
               diagnosticTraceOut += StringFormat("%s :\r\n  non eligible\r\n  Cause : %s\r\n", m_calculators[i].GetName(), m_calculators[i].GetLastIneligibilityReason());
            continue;
           }

         // NOUVEAU (demande explicite point 1) : ce calculateur AVAIT
         // quelque chose à proposer ce tick - comptabilisé, qu'il gagne
         // ou non la comparaison finale.
         m_proposedCount[i]++;

         if(m_diagnosticMode)
            diagnosticTraceOut += StringFormat("%s :\r\n  eligible\r\n  SL propose = %.5f\r\n", m_calculators[i].GetName(), candidateLevel);

         // Cas particulier : l'urgence en mode "fermeture immédiate" ne
         // produit pas un niveau de prix comparable - elle surclasse tout.
         // NOTE : comparaison via GetSource() plutôt que par identité de
         // pointeur (m_calculators[i] == m_emergencyCalculator) - cette
         // dernière comparerait deux types de pointeurs différents
         // (IProtectionLevelCalculator* vs CEmergencyLevelCalculator*),
         // non garantie de compiler selon les versions de MQL5. GetSource()
         // est fiable car un seul calculateur enregistré porte cette
         // source (voir Init() - un seul CEmergencyLevelCalculator créé).
         if(m_calculators[i].GetSource() == PROTECTION_SOURCE_EMERGENCY &&
            m_emergencyCalculator != NULL && m_emergencyCalculator.IsLastCloseNow())
           {
            closeNowOut = true;
            sourceOut   = PROTECTION_SOURCE_EMERGENCY;
            noteOut     = BuildDetailNote(m_emergencyCalculator.GetName(), "", ctx.peakProfitMoney, ctx.currentProfitMoney);
            m_retainedCount[i]++;
            m_states[idx].lastWinningIndex = i; // NOUVEAU (point 3)
            RecordFirstActivationIfNeeded(idx, i, currentProfitMoney); // NOUVEAU (point 2)
            if(m_diagnosticMode)
               diagnosticTraceOut += StringFormat("\r\nDecision finale : %s retenu (URGENCE - fermeture immediate)\r\n", m_calculators[i].GetName());
            return(true);
           }

         if(IsMoreProtective(ctx.type, candidateLevel, bestCandidate))
           {
            bestCandidate = candidateLevel;
            bestIdx       = i;
           }
        }

      if(bestIdx < 0)
        {
         if(m_diagnosticMode)
            diagnosticTraceOut += "\r\nDecision finale : aucune (aucun candidat plus protecteur que le SL actuel)\r\n";
         return(false); // Aucune amélioration disponible ce tick
        }

      // NOUVEAU (demande explicite point 1) : le calculateur bestIdx a
      // REMPORTE la comparaison ce tick.
      m_retainedCount[bestIdx]++;
      m_states[idx].lastWinningIndex = bestIdx; // NOUVEAU (point 3)
      RecordFirstActivationIfNeeded(idx, bestIdx, currentProfitMoney); // NOUVEAU (point 2)

      finalSLOut = bestCandidate;
      sourceOut  = m_calculators[bestIdx].GetSource();

      // --- Note de traçabilité (demande explicite point 2, existant) ---
      double securedProfitMoney = 0.0;
      if(ctx.tickSize > 0.0 && ctx.tickValue > 0.0)
        {
         double priceDistance = (ctx.type == SIGNAL_BUY) ? (finalSLOut - ctx.entryPrice) : (ctx.entryPrice - finalSLOut);
         securedProfitMoney = (priceDistance / ctx.tickSize) * ctx.tickValue * ctx.lot;
        }
      noteOut = BuildDetailNote(m_calculators[bestIdx].GetName(), m_calculators[bestIdx].GetLastDetail(),
                                ctx.peakProfitMoney, securedProfitMoney);

      if(m_diagnosticMode)
         diagnosticTraceOut += StringFormat("\r\nDecision finale : %s retenu\r\nPourquoi ? SL le plus protecteur (%.5f)\r\n",
                                            m_calculators[bestIdx].GetName(), finalSLOut);

      return(true);
     }

   //---------------------------------------------------------------
   // NOUVEAU (demande explicite point 1). À appeler par l'orchestrateur
   // juste après un ApplyProtection() qui a RÉELLEMENT réussi (broker
   // confirmé) - permet de distinguer "retenu" (a gagné la comparaison)
   // de "appliqué" (a réellement atteint le broker). Peut différer si
   // le throttle partagé de CTradeManager a bloqué la tentative.
   //---------------------------------------------------------------
   void              RecordApplied(const ENUM_PROTECTION_SOURCE source)
     {
      int total = ArraySize(m_calculators);
      for(int i = 0; i < total; i++)
        {
         if(m_calculators[i].GetSource() == source)
           {
            m_appliedCount[i]++;
            return;
           }
        }
     }

   //---------------------------------------------------------------
   // NOUVEAU (demande explicite point 1). Rapport global (depuis le
   // démarrage de l'EA) : pour chaque calculateur enregistré, combien
   // de fois il a été proposé / retenu / réellement appliqué. Permet
   // de répondre objectivement à "qui agit réellement, et est-il
   // toujours écrasé par un autre ?" - à appeler dans OnDeinit(), même
   // pattern que CStatistics::GenerateReport()/CDiagnostics::GenerateReport().
   //---------------------------------------------------------------
   string            GetActivationReport() const
     {
      string r = "===== PROFIT PROTECTION ENGINE - Activations par mecanisme =====\n";
      int total = ArraySize(m_calculators);
      if(total == 0)
         r += "(Aucun calculateur enregistre - Profit Guard entierement desactive)\n";
      for(int i = 0; i < total; i++)
        {
         r += StringFormat("%s :\n", m_calculators[i].GetName());
         r += StringFormat("   Propose=%-4d | Retenu=%-4d | Applique=%-4d | Efficace=%-4d\n",
                           m_proposedCount[i], m_retainedCount[i], m_appliedCount[i], m_effectiveCount[i]);

         // NOUVEAU (demande explicite point 2) : temps de réaction
         if(m_countFirstActivation[i] > 0)
           {
            double avgMinutes = (double)m_sumTimeToActivationSec[i] / m_countFirstActivation[i] / 60.0;
            double avgProfit  = m_sumProfitAtActivation[i] / m_countFirstActivation[i];
            r += StringFormat("   Temps moyen avant 1ere activation : %.1f min | Profit moyen a l'activation : %.2f $\n",
                              avgMinutes, avgProfit);
           }
         else
            r += "   Temps moyen avant 1ere activation : N/A (jamais active)\n";
        }
      r += "-------------------------------------------------------------------\n";
      r += "Definition de \"Efficace\" : le DERNIER mecanisme a avoir modifie le SL\n";
      r += "avant que le trade ne se cloture sur ce SL touche, avec un profit final >= 0.\n";
      r += "Un mecanisme peut etre applique souvent sans etre \"efficace\" (surclasse\n";
      r += "ensuite par un autre), et inversement.\n";
      r += "===================================================================";
      return(r);
     }

   //---------------------------------------------------------------
   // EXÉCUTION - Unique méthode qui déclenche un appel vers
   // CTradeManager (jamais vers CTrade directement).
   //---------------------------------------------------------------
   bool              ApplyProtection(CTradeManager &tradeManager, const ulong ticket, const double currentTP,
                                     const double finalSL, const bool closeNow, const int minIntervalSeconds)
     {
      if(closeNow)
         return(tradeManager.ApplyExternalClose(ticket));

      return(tradeManager.ApplyExternalProtection(ticket, finalSL, currentTP, minIntervalSeconds));
     }

   //---------------------------------------------------------------
   // Accesseurs pour la journalisation (STradeFullRecord). Le libellé
   // du dernier mécanisme gagnant est reconstruit à partir de
   // ENUM_PROTECTION_SOURCE au moment de l'appel (pas stocké tel quel
   // en interne, pour rester une source unique de vérité).
   //---------------------------------------------------------------
   static string     SourceToString(const ENUM_PROTECTION_SOURCE source)
     {
      switch(source)
        {
         case PROTECTION_SOURCE_BREAKEVEN:    return("BreakEven");
         case PROTECTION_SOURCE_TRAILING:     return("Trailing");
         case PROTECTION_SOURCE_STRUCTURE:    return("ProfitGuard_Structure");
         case PROTECTION_SOURCE_PEAK_PERCENT: return("ProfitGuard_PeakPercent");
         case PROTECTION_SOURCE_EMERGENCY:    return("ProfitGuard_Emergency");
         default:                             return("Aucune");
        }
     }

   bool              FillGuardData(const ulong positionId, bool &armedOut, double &peakProfitOut) const
     {
      armedOut = false; peakProfitOut = 0.0;
      int idx = FindIndex(positionId);
      if(idx < 0)
         return(false);
      armedOut      = m_states[idx].armed;
      peakProfitOut = m_states[idx].peakProfitMoney;
      return(true);
     }

   //---------------------------------------------------------------
   // NOUVEAU (demande explicite point 3 - mesure d'efficacité réelle).
   // À appeler par l'orchestrateur À LA CLÔTURE du trade, AVANT
   // ReleaseTrade() (qui efface l'état, dont lastWinningIndex).
   //
   // DÉFINITION EXACTE de "efficace" (voir aussi le commentaire sur
   // m_effectiveCount en tête de classe) : le DERNIER calculateur à
   // avoir remporté la comparaison sur ce trade est crédité d'une
   // activation "efficace" SI le trade s'est clôturé sur un SL touché
   // (closeReasonRaw contient "SL") ET que le profit final est >= 0.
   // Un trade clôturé par TP, par fermeture manuelle/EA, ou par un SL
   // touché en perte, n'est jamais compté comme "efficace" ici - même
   // si des mécanismes de protection ont techniquement fonctionné.
   //---------------------------------------------------------------
   void              RecordTradeClosed(const ulong positionId, const string closeReasonRaw, const double finalProfit)
     {
      int idx = FindIndex(positionId);
      if(idx < 0)
         return;

      int winIdx = m_states[idx].lastWinningIndex;
      if(winIdx < 0 || winIdx >= ArraySize(m_effectiveCount))
         return; // Aucun mécanisme de protection n'a jamais gagné sur ce trade

      bool closedViaSL = (StringFind(closeReasonRaw, "SL") >= 0);
      if(closedViaSL && finalProfit >= 0.0)
         m_effectiveCount[winIdx]++;
     }

   //---------------------------------------------------------------
   // Libère l'état d'un trade clôturé.
   //---------------------------------------------------------------
   void              ReleaseTrade(const ulong positionId)
     {
      int idx = FindIndex(positionId);
      if(idx < 0)
         return;
      int last = ArraySize(m_states) - 1;
      if(idx != last)
         m_states[idx] = m_states[last];
      ArrayResize(m_states, last);
     }
  };

#endif // PROFITPROTECTIONENGINE_MQH
//+------------------------------------------------------------------+
