//+------------------------------------------------------------------+
//|                                   Test_ObservationLayer.mq5         |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.9.2 - Incrément I2 : tests de CObservationLayer.          |
//|                                                                    |
//| Valide la logique de traduction et le pont de corrélation en        |
//| isolation, avec des verdicts et tickets SYNTHÉTIQUES - ne se        |
//| connecte à aucun broker reel, ne depend d'aucun signal reel.        |
//| Le Test 1 (non-regression baseline) de la mission V3.9.2 reste a    |
//| executer separement, en backtest reel dans MetaTrader - ce script   |
//| couvre les Tests 2 et 3 (capture Decision, liaison Decision ->      |
//| Execution, Cas A et Cas B) et le Test 4 (desactivation) au niveau   |
//| du module lui-meme, avant tout backtest.                            |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict
#property script_show_inputs

#include <NexusEdgeEA/ObservationLayer.mqh>

input string InpTestFileBase = "Test_ObservationLayer_I2.csv";

int g_testsRun    = 0;
int g_testsPassed = 0;

void TestAssert(const bool condition, const string testName, const string detail = "")
  {
   g_testsRun++;
   if(condition)
     {
      g_testsPassed++;
      PrintFormat("[PASS] %s", testName);
     }
   else
     {
      PrintFormat("[FAIL] %s %s", testName, (detail != "") ? ("- " + detail) : "");
     }
  }

void CleanTestFile(const string fileName)
  {
   if(FileIsExist(fileName))
      FileDelete(fileName);
  }

SScenarioVerdict BuildSyntheticVerdict(const bool authorized)
  {
   SScenarioVerdict v;
   v.status           = SCENARIO_UNKNOWN;
   v.confidence        = authorized ? 1.0 : 0.5;
   v.reason           = "Verdict synthetique de test";
   v.evaluatedAt       = TimeCurrent();
   v.authorized       = authorized;
   v.scenarioStrength  = authorized ? "STRONG" : "MEDIUM";
   v.htfOk             = true;
   v.structureOk       = true;
   v.orderBlockOk      = authorized;
   v.fvgOk             = authorized;
   return(v);
  }

//+------------------------------------------------------------------+
//| TEST — Cas A : verdict autorise + trade reellement execute.        |
//| Attendu : DECISION, EXECUTION_OPEN, EXECUTION_CLOSE partagent le    |
//| meme correlationId.                                                 |
//+------------------------------------------------------------------+
void Test_CasA_DecisionToExecutionComplete()
  {
   string fileName = "CasA_" + InpTestFileBase;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   rdl.Init(fileName);

   CObservationLayer ol;
   ol.Init(GetPointer(rdl), true, "STRAT_TEST", "ACC_TEST");

   SScenarioVerdict verdict = BuildSyntheticVerdict(true);
   string opportunityId = ol.CaptureDecision(verdict, SIGNAL_BUY, "XAUUSD");
   TestAssert(opportunityId != "", "Cas A - opportunityId genere (non vide)");

   ulong syntheticTicket = 999001;
   ol.CaptureExecutionOpen(opportunityId, syntheticTicket, "XAUUSD", 1.0, 2000.0, 1990.0, 2020.0, SIGNAL_BUY);
   ol.CaptureExecutionClose(syntheticTicket, "XAUUSD", 2015.0, true, 150.0, "TP atteint (synthetique)");

   rdl = CResearchDataLayer(); // force la fermeture/flush avant lecture

   SResearchEvent events[];
   int count = CResearchDataReader::ReadAllEvents(fileName, events);
   TestAssert(count == 3, "Cas A - 3 evenements persistes (DECISION/OPEN/CLOSE)", StringFormat("obtenu=%d", count));

   if(count == 3)
     {
      TestAssert(events[0].eventFamily == "DECISION", "Cas A - 1er evenement = DECISION");
      TestAssert(events[1].eventFamily == "EXECUTION_OPEN", "Cas A - 2e evenement = EXECUTION_OPEN");
      TestAssert(events[2].eventFamily == "EXECUTION_CLOSE", "Cas A - 3e evenement = EXECUTION_CLOSE");

      bool sameCorrelation = (events[0].correlationId == opportunityId)
                          && (events[1].correlationId == opportunityId)
                          && (events[2].correlationId == opportunityId);
      TestAssert(sameCorrelation, "Cas A - correlationId identique sur les 3 evenements (exigence explicite V3.9.2)",
                 StringFormat("DECISION=%s OPEN=%s CLOSE=%s", events[0].correlationId, events[1].correlationId, events[2].correlationId));

      bool ticketPresent = (StringFind(events[1].payload, "ticket=999001") >= 0)
                        && (StringFind(events[2].payload, "ticket=999001") >= 0);
      TestAssert(ticketPresent, "Cas A - tradeId (ticket) present dans le payload d'OPEN et de CLOSE");
     }

   CleanTestFile(fileName);
  }

//+------------------------------------------------------------------+
//| TEST — Cas B : verdict autorise mais AUCUN trade execute (refus    |
//| broker/Validator simule en ne appelant jamais CaptureExecutionOpen).|
//| Attendu : evenement DECISION present, AUCUNE erreur, AUCUN         |
//| evenement d'execution.                                              |
//+------------------------------------------------------------------+
void Test_CasB_DecisionSansExecution()
  {
   string fileName = "CasB_" + InpTestFileBase;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   rdl.Init(fileName);

   CObservationLayer ol;
   ol.Init(GetPointer(rdl), true, "STRAT_TEST", "ACC_TEST");

   SScenarioVerdict verdict = BuildSyntheticVerdict(true);
   string opportunityId = ol.CaptureDecision(verdict, SIGNAL_SELL, "XAUUSD");
   // Volontairement : aucun appel a CaptureExecutionOpen/Close - simule un refus broker/Validator

   rdl = CResearchDataLayer();

   SResearchEvent events[];
   int count = CResearchDataReader::ReadAllEvents(fileName, events);

   TestAssert(count == 1, "Cas B - un seul evenement present (DECISION uniquement)", StringFormat("obtenu=%d", count));
   if(count == 1)
     {
      TestAssert(events[0].eventFamily == "DECISION", "Cas B - l'unique evenement est bien DECISION");
      TestAssert(events[0].correlationId == opportunityId, "Cas B - correlationId de la decision preserve");
     }

   CleanTestFile(fileName);
  }

//+------------------------------------------------------------------+
//| TEST — Desactivation complete (Test 4, V3.9.2) : aucune ecriture,  |
//| aucune erreur, opportunityId toujours retourne (signature stable). |
//+------------------------------------------------------------------+
void Test_Disabled_NoWriteAtAll()
  {
   string fileName = "Disabled_" + InpTestFileBase;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   rdl.Init(fileName);

   CObservationLayer ol;
   ol.Init(GetPointer(rdl), false, "STRAT_TEST", "ACC_TEST"); // DESACTIVE

   SScenarioVerdict verdict = BuildSyntheticVerdict(true);
   string opportunityId = ol.CaptureDecision(verdict, SIGNAL_BUY, "XAUUSD");
   TestAssert(opportunityId != "", "Desactive - opportunityId toujours genere (signature d'appel stable)");

   ol.CaptureExecutionOpen(opportunityId, 999002, "XAUUSD", 1.0, 2000.0, 1990.0, 2020.0, SIGNAL_BUY);
   ol.CaptureExecutionClose(999002, "XAUUSD", 2015.0, true, 150.0, "TP atteint");

   rdl = CResearchDataLayer();

   SResearchEvent events[];
   int count = CResearchDataReader::ReadAllEvents(fileName, events);
   TestAssert(count == 0, "Desactive - AUCUN evenement ecrit malgre 3 appels de capture", StringFormat("obtenu=%d", count));

   CleanTestFile(fileName);
  }

//+------------------------------------------------------------------+
//| TEST — Plusieurs opportunites concurrentes : verifier que le pont  |
//| de correlation ne mele jamais deux tickets differents entre eux.   |
//+------------------------------------------------------------------+
void Test_MultipleOpportunities_NoCrossTalk()
  {
   string fileName = "Multi_" + InpTestFileBase;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   rdl.Init(fileName);
   CObservationLayer ol;
   ol.Init(GetPointer(rdl), true, "STRAT_TEST", "ACC_TEST");

   SScenarioVerdict v1 = BuildSyntheticVerdict(true);
   SScenarioVerdict v2 = BuildSyntheticVerdict(true);
   string opp1 = ol.CaptureDecision(v1, SIGNAL_BUY, "XAUUSD");
   string opp2 = ol.CaptureDecision(v2, SIGNAL_SELL, "XAUUSD");

   TestAssert(opp1 != opp2, "Multi - deux opportunityId distincts pour deux decisions");

   ol.CaptureExecutionOpen(opp1, 111, "XAUUSD", 1.0, 2000.0, 1990.0, 2020.0, SIGNAL_BUY);
   ol.CaptureExecutionOpen(opp2, 222, "XAUUSD", 1.0, 2000.0, 2010.0, 1980.0, SIGNAL_SELL);
   // Cloture dans l'ordre inverse - le pont ne doit pas dependre de l'ordre d'ouverture
   ol.CaptureExecutionClose(222, "XAUUSD", 1985.0, true, 250.0, "TP atteint");
   ol.CaptureExecutionClose(111, "XAUUSD", 1995.0, false, -50.0, "SL touche");

   rdl = CResearchDataLayer();
   SResearchEvent events[];
   int count = CResearchDataReader::ReadAllEvents(fileName, events);
   TestAssert(count == 6, "Multi - 6 evenements au total (2x DECISION/OPEN/CLOSE)", StringFormat("obtenu=%d", count));

   if(count == 6)
     {
      // events[4] = CLOSE du ticket 222 (opp2), events[5] = CLOSE du ticket 111 (opp1)
      bool noCrossTalk = (StringFind(events[4].payload, "ticket=222") >= 0) && (events[4].correlationId == opp2)
                      && (StringFind(events[5].payload, "ticket=111") >= 0) && (events[5].correlationId == opp1);
      TestAssert(noCrossTalk, "Multi - aucune confusion entre les deux opportunites malgre la cloture inversee");
     }

   CleanTestFile(fileName);
  }

void OnStart()
  {
   Print("========================================================");
   Print("  Sprint V3.9.2 - Increment I2 - Tests Observation Layer");
   Print("  Verdicts et tickets SYNTHETIQUES - isolation complete");
   Print("========================================================");

   Test_CasA_DecisionToExecutionComplete();
   Test_CasB_DecisionSansExecution();
   Test_Disabled_NoWriteAtAll();
   Test_MultipleOpportunities_NoCrossTalk();

   Print("========================================================");
   PrintFormat("  RESULTAT : %d/%d tests reussis", g_testsPassed, g_testsRun);
   Print(g_testsPassed == g_testsRun ? "  TOUS LES TESTS SONT PASSES" : "  ECHECS DETECTES - voir [FAIL] ci-dessus");
   Print("  Rappel : le Test 1 (non-regression baseline officielle)");
   Print("  reste a executer en backtest reel dans MetaTrader.");
   Print("========================================================");
  }
//+------------------------------------------------------------------+