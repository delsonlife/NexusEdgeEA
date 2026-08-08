//+------------------------------------------------------------------+
//|                                 Test_ResearchDataLayer.mq5          |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.9 - Incrément I1 : tests unitaires, de lecture,           |
//| d'intégrité et de round-trip de la Research Data Layer.             |
//| SPRINT V3.9.3.4 - Ajout des tests obligatoires du correctif          |
//| d'intégrité du payload (5 cas explicitement requis).                 |
//| SPRINT V3.9.3.5 - Migration JSON Lines : tests inchangés dans leur    |
//| logique (le contrat SResearchEvent et les signatures publiques ne     |
//| changent pas) - seuls le Test 3 (plus d'en-tête à vérifier) et le     |
//| nom de fichier par défaut ont été adaptés au nouveau format.          |
//|                                                                    |
//| Script MQL5 autonome, volontairement séparé de tout Expert Advisor -|
//| conforme à l'exigence "aucun branchement au Trading Engine" de      |
//| l'incrément I1. Utilise UNIQUEMENT des événements synthétiques.     |
//|                                                                    |
//| Exécuter ce script (glisser sur un graphique, ou via le Navigateur  |
//| MetaEditor) affiche un résumé PASS/FAIL pour chaque test dans       |
//| l'onglet "Experts" du terminal.                                      |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict
#property script_show_inputs

#include <NexusEdgeEA/ResearchDataLayer.mqh>

input string InpTestFileName = "Test_ResearchDataLayer_I1.jsonl"; // Nom du fichier de test (isole de tout fichier de production)

int g_testsRun    = 0;
int g_testsPassed = 0;

//+------------------------------------------------------------------+
//| Assertion minimaliste - imprime PASS/FAIL, incremente les          |
//| compteurs. Pas de dependance a un framework de test externe        |
//| (aucun n'existe nativement en MQL5) - suffisant pour ce perimetre.  |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Nettoie le fichier de test avant chaque scenario, pour garantir    |
//| un etat initial connu et reproductible (aucun residu d'une         |
//| execution precedente).                                             |
//+------------------------------------------------------------------+
void CleanTestFile(const string fileName)
  {
   if(FileIsExist(fileName))
      FileDelete(fileName);
  }

//+------------------------------------------------------------------+
//| TEST 1 - Round-trip simple : ecrire N evenements synthetiques,     |
//| les relire, verifier l'egalite champ par champ.                    |
//+------------------------------------------------------------------+
void Test_RoundTrip_SimpleEvents()
  {
   string fileName = "RT1_" + InpTestFileName;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   bool initOk = rdl.Init(fileName);
   TestAssert(initOk, "RoundTrip - Init reussi");
   if(!initOk)
      return;

   SResearchEvent written[3];
   bool w1 = rdl.WriteEvent("SYNTHETIC_A", "STRAT_TEST", "ACC_TEST", "XAUUSD", "CORR_001", "cle1=valeur1;cle2=valeur2", written[0]);
   bool w2 = rdl.WriteEvent("SYNTHETIC_B", "STRAT_TEST", "ACC_TEST", "XAUUSD", "CORR_002", "cle1=autre;cle2=42", written[1]);
   bool w3 = rdl.WriteEvent("SYNTHETIC_A", "STRAT_TEST", "ACC_TEST", "EURUSD", "CORR_001", "payload avec espaces", written[2]);

   TestAssert(w1 && w2 && w3, "RoundTrip - 3 ecritures reussies");
   TestAssert(rdl.GetWrittenCount() == 3, "RoundTrip - compteur d'ecriture = 3",
              StringFormat("obtenu=%d", rdl.GetWrittenCount()));

   // Forcer la fermeture pour garantir que la lecture se fait sur un fichier reellement flush sur disque
   rdl = CResearchDataLayer(); // reinitialise l'objet -> destructeur ferme le handle

   SResearchEvent readBack[];
   int readCount = CResearchDataReader::ReadAllEvents(fileName, readBack);

   TestAssert(readCount == 3, "RoundTrip - nombre d'evenements relus = 3", StringFormat("obtenu=%d", readCount));
   if(readCount != 3)
      return;

   bool fieldsMatch = true;
   for(int i = 0; i < 3; i++)
     {
      if(readBack[i].eventId != written[i].eventId) fieldsMatch = false;
      if(readBack[i].eventFamily != written[i].eventFamily) fieldsMatch = false;
      if(readBack[i].strategyId != written[i].strategyId) fieldsMatch = false;
      if(readBack[i].accountId != written[i].accountId) fieldsMatch = false;
      if(readBack[i].symbolId != written[i].symbolId) fieldsMatch = false;
      if(readBack[i].correlationId != written[i].correlationId) fieldsMatch = false;
      if(readBack[i].payload != written[i].payload) fieldsMatch = false;
      if(readBack[i].schemaVersion != written[i].schemaVersion) fieldsMatch = false;
     }
   TestAssert(fieldsMatch, "RoundTrip - egalite champ par champ ecrit/relu");

   // Ordre d'ecriture preserve (pas seulement le contenu, mais la sequence)
   bool orderPreserved = (readBack[0].eventFamily == "SYNTHETIC_A" && readBack[0].correlationId == "CORR_001"
                       && readBack[1].eventFamily == "SYNTHETIC_B"
                       && readBack[2].correlationId == "CORR_001" && readBack[2].symbolId == "EURUSD");
   TestAssert(orderPreserved, "RoundTrip - ordre d'ecriture preserve a la lecture");

   CleanTestFile(fileName);
  }

//+------------------------------------------------------------------+
//| TEST 2 - Identifiants d'evenement monotones et uniques, y compris  |
//| sur un grand nombre d'ecritures.                                    |
//+------------------------------------------------------------------+
void Test_EventId_Monotone()
  {
   string fileName = "RT2_" + InpTestFileName;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   rdl.Init(fileName);

   ulong lastId = 0;
   bool monotone = true;
   for(int i = 0; i < 50; i++)
     {
      SResearchEvent ev;
      rdl.WriteEvent("SYNTHETIC_LOOP", "STRAT_TEST", "ACC_TEST", "XAUUSD", IntegerToString(i), "n=" + IntegerToString(i), ev);
      if(ev.eventId <= lastId)
         monotone = false;
      lastId = ev.eventId;
     }
   TestAssert(monotone, "Monotone - 50 identifiants strictement croissants");
   TestAssert(lastId == 50, "Monotone - dernier identifiant = 50", StringFormat("obtenu=%d", (int)lastId));

   rdl = CResearchDataLayer();
   CleanTestFile(fileName);
  }

//+------------------------------------------------------------------+
//| TEST 3 - Integrite append-only : fermer le fichier, le rouvrir,    |
//| ecrire de nouveaux evenements, verifier qu'AUCUN evenement         |
//| precedent n'est perdu ni modifie. SPRINT V3.9.3.5 : le JSON Lines   |
//| n'a plus d'en-tete (chaque ligne est auto-descriptive) - la         |
//| verification "en-tete jamais duplique" est remplacee par un         |
//| controle du nombre EXACT de lignes brutes du fichier (aucune ligne  |
//| parasite ajoutee a la reouverture).                                  |
//+------------------------------------------------------------------+
void Test_Integrity_AppendAcrossReopen()
  {
   string fileName = "RT3_" + InpTestFileName;
   CleanTestFile(fileName);

   // --- Premiere "session" : 2 evenements ---
   CResearchDataLayer rdl1;
   rdl1.Init(fileName);
   SResearchEvent e1, e2;
   rdl1.WriteEvent("SESSION_1", "STRAT_TEST", "ACC_TEST", "XAUUSD", "A", "premiere-session-1", e1);
   rdl1.WriteEvent("SESSION_1", "STRAT_TEST", "ACC_TEST", "XAUUSD", "B", "premiere-session-2", e2);
   rdl1 = CResearchDataLayer(); // fermeture explicite (simule un redemarrage)

   // --- Deuxieme "session" : reouverture du MEME fichier, nouveaux evenements ---
   CResearchDataLayer rdl2;
   bool reopenOk = rdl2.Init(fileName);
   TestAssert(reopenOk, "Integrite - reouverture du fichier existant reussie");

   SResearchEvent e3, e4;
   rdl2.WriteEvent("SESSION_2", "STRAT_TEST", "ACC_TEST", "XAUUSD", "C", "deuxieme-session-1", e3);
   rdl2.WriteEvent("SESSION_2", "STRAT_TEST", "ACC_TEST", "XAUUSD", "D", "deuxieme-session-2", e4);

   // L'identifiant reprend a 1 en memoire pour la nouvelle instance (comportement documente,
   // pas un defaut : voir audit critique) - ce test verifie uniquement que le FICHIER conserve
   // bien les 4 lignes, pas que les identifiants memoire soient globalement uniques entre sessions.
   rdl2 = CResearchDataLayer();

   SResearchEvent allEvents[];
   int total = CResearchDataReader::ReadAllEvents(fileName, allEvents);

   TestAssert(total == 4, "Integrite - 4 evenements presents apres reouverture", StringFormat("obtenu=%d", total));

   if(total == 4)
     {
      bool session1Intact = (allEvents[0].payload == "premiere-session-1" && allEvents[1].payload == "premiere-session-2");
      bool session2Present = (allEvents[2].payload == "deuxieme-session-1" && allEvents[3].payload == "deuxieme-session-2");
      TestAssert(session1Intact, "Integrite - evenements de la premiere session non perdus/non modifies");
      TestAssert(session2Present, "Integrite - evenements de la deuxieme session correctement ajoutes");
     }

   // Verifier qu'exactement 4 lignes brutes existent - aucune ligne
   // parasite (en-tete ou autre) n'a ete inseree a la reouverture.
   int handle = FileOpen(fileName, FILE_READ | FILE_TXT | FILE_ANSI);
   int rawLineCount = 0;
   if(handle != INVALID_HANDLE)
     {
      while(!FileIsEnding(handle))
        {
         string line = FileReadString(handle);
         if(StringLen(line) > 0)
            rawLineCount++;
        }
      FileClose(handle);
     }
   TestAssert(rawLineCount == 4, "Integrite - exactement 4 lignes brutes, aucune ligne parasite sur reouverture (JSONL, pas d'en-tete)",
              StringFormat("obtenu=%d", rawLineCount));

   CleanTestFile(fileName);
  }

//+------------------------------------------------------------------+
//| TEST 4 - Lecture d'un fichier vide/inexistant : doit echouer       |
//| proprement, jamais planter ni retourner une donnee inventee.        |
//+------------------------------------------------------------------+
void Test_Read_MissingFile()
  {
   string fileName = "RT4_inexistant_" + InpTestFileName;
   CleanTestFile(fileName); // s'assurer qu'il n'existe vraiment pas

   SResearchEvent events[];
   int result = CResearchDataReader::ReadAllEvents(fileName, events);

   TestAssert(result == -1, "Lecture - fichier inexistant retourne -1 explicitement", StringFormat("obtenu=%d", result));
   TestAssert(ArraySize(events) == 0, "Lecture - tableau de sortie vide sur echec");
  }

//+------------------------------------------------------------------+
//| TEST 5 - Ecriture avant Init() (mauvais usage) : doit echouer      |
//| proprement, jamais planter.                                        |
//+------------------------------------------------------------------+
void Test_Write_BeforeInit()
  {
   CResearchDataLayer rdl; // jamais initialisee
   SResearchEvent ev;
   bool result = rdl.WriteEvent("SYNTHETIC", "S", "A", "X", "C", "payload", ev);
   TestAssert(!result, "Ecriture avant Init() - echoue proprement, pas de crash");
   TestAssert(rdl.GetWrittenCount() == 0, "Ecriture avant Init() - compteur reste a 0");
  }

//+------------------------------------------------------------------+
//| TEST 6 - Payload contenant des caracteres speciaux JSON (guillemets,|
//| virgule, guillemets) - verifier que le round-trip reste correct.    |
//+------------------------------------------------------------------+
void Test_RoundTrip_SpecialCharacters()
  {
   string fileName = "RT6_" + InpTestFileName;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   rdl.Init(fileName);

   SResearchEvent ev;
   string trickyPayload = "cle=valeur; autre=test, encore\"des guillemets\"";
   rdl.WriteEvent("SYNTHETIC_SPECIAL", "STRAT_TEST", "ACC_TEST", "XAUUSD", "CORR_SPECIAL", trickyPayload, ev);
   rdl = CResearchDataLayer();

   SResearchEvent readBack[];
   int count = CResearchDataReader::ReadAllEvents(fileName, readBack);

   TestAssert(count == 1, "Caracteres speciaux - un evenement relu", StringFormat("obtenu=%d", count));
   if(count == 1)
     {
      TestAssert(readBack[0].payload == trickyPayload, "Caracteres speciaux - payload preserve a l'identique",
                 StringFormat("attendu='%s' obtenu='%s'", trickyPayload, readBack[0].payload));
     }

   CleanTestFile(fileName);
  }

//+------------------------------------------------------------------+
//| SPRINT V3.9.3.4 - Les 5 tests obligatoires du correctif d'intégrité |
//| du payload, chacun isolé et nommé explicitement selon la mission.   |
//+------------------------------------------------------------------+

//---------------------------------------------------------------
// TEST OBLIGATOIRE 1 - Payload simple : "key=value".
//---------------------------------------------------------------
void Test_Payload_Simple()
  {
   string fileName = "Fix1_" + InpTestFileName;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   rdl.Init(fileName);
   SResearchEvent written;
   string payload = "key=value";
   rdl.WriteEvent("SYNTHETIC", "S", "A", "X", "C1", payload, written);
   rdl = CResearchDataLayer();

   SResearchEvent readBack[];
   int count = CResearchDataReader::ReadAllEvents(fileName, readBack);
   TestAssert(count == 1, "Correctif payload - Test 1 (simple) : un evenement relu", StringFormat("obtenu=%d", count));
   if(count == 1)
      TestAssert(readBack[0].payload == payload, "Correctif payload - Test 1 (simple) : payload identique",
                 StringFormat("attendu='%s' obtenu='%s'", payload, readBack[0].payload));

   CleanTestFile(fileName);
  }

//---------------------------------------------------------------
// TEST OBLIGATOIRE 2 - Payload avec separateur interne :
// "key1=value1;key2=value2" - c'est EXACTEMENT le cas qui a
// provoque le defaut decouvert sur donnees reelles (I3).
//---------------------------------------------------------------
void Test_Payload_WithSeparator()
  {
   string fileName = "Fix2_" + InpTestFileName;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   rdl.Init(fileName);
   SResearchEvent written;
   string payload = "key1=value1;key2=value2;key3=value3";
   rdl.WriteEvent("SYNTHETIC", "S", "A", "X", "C2", payload, written);
   // Deuxieme evenement APRES celui a payload multi-cles - verifie que
   // la ligne suivante n'est pas desynchronisee par la precedente.
   SResearchEvent written2;
   rdl.WriteEvent("SYNTHETIC", "S", "A", "X", "C3", "sentinelle=apres", written2);
   rdl = CResearchDataLayer();

   SResearchEvent readBack[];
   int count = CResearchDataReader::ReadAllEvents(fileName, readBack);
   TestAssert(count == 2, "Correctif payload - Test 2 (separateur) : 2 evenements relus, pas de desynchronisation",
              StringFormat("obtenu=%d", count));
   if(count == 2)
     {
      TestAssert(readBack[0].payload == payload, "Correctif payload - Test 2 (separateur) : payload complet preserve",
                 StringFormat("attendu='%s' obtenu='%s'", payload, readBack[0].payload));
      TestAssert(readBack[1].payload == "sentinelle=apres", "Correctif payload - Test 2 (separateur) : ligne suivante non contaminee",
                 StringFormat("obtenu='%s'", readBack[1].payload));
      TestAssert(readBack[1].correlationId == "C3", "Correctif payload - Test 2 (separateur) : correlationId de la ligne suivante intact");
     }

   CleanTestFile(fileName);
  }

//---------------------------------------------------------------
// TEST OBLIGATOIRE 3 - Payload avec guillemets : message="test".
//---------------------------------------------------------------
void Test_Payload_WithQuotes()
  {
   string fileName = "Fix3_" + InpTestFileName;
   CleanTestFile(fileName);

   CResearchDataLayer rdl;
   rdl.Init(fileName);
   SResearchEvent written;
   string payload = "message=\"test\"";
   rdl.WriteEvent("SYNTHETIC", "S", "A", "X", "C4", payload, written);
   rdl = CResearchDataLayer();

   SResearchEvent readBack[];
   int count = CResearchDataReader::ReadAllEvents(fileName, readBack);
   TestAssert(count == 1, "Correctif payload - Test 3 (guillemets) : un evenement relu", StringFormat("obtenu=%d", count));
   if(count == 1)
      TestAssert(readBack[0].payload == payload, "Correctif payload - Test 3 (guillemets) : payload identique, guillemets preserves",
                 StringFormat("attendu='%s' obtenu='%s'", payload, readBack[0].payload));

   CleanTestFile(fileName);
  }

//---------------------------------------------------------------
// TEST OBLIGATOIRE 4 - Payload long (plusieurs milliers de
// caracteres) - verifie l'absence de troncature.
//---------------------------------------------------------------
void Test_Payload_Long()
  {
   string fileName = "Fix4_" + InpTestFileName;
   CleanTestFile(fileName);

   string longPayload = "";
   for(int i = 0; i < 500; i++)
      longPayload += StringFormat("cle%d=valeur%d;", i, i); // > 6000 caracteres, points-virgules internes partout
   int expectedLen = StringLen(longPayload);

   CResearchDataLayer rdl;
   rdl.Init(fileName);
   SResearchEvent written;
   rdl.WriteEvent("SYNTHETIC", "S", "A", "X", "C5", longPayload, written);
   rdl = CResearchDataLayer();

   SResearchEvent readBack[];
   int count = CResearchDataReader::ReadAllEvents(fileName, readBack);
   TestAssert(count == 1, "Correctif payload - Test 4 (long) : un evenement relu", StringFormat("obtenu=%d", count));
   if(count == 1)
     {
      TestAssert(StringLen(readBack[0].payload) == expectedLen,
                 "Correctif payload - Test 4 (long) : longueur preservee, aucune troncature",
                 StringFormat("attendu=%d caracteres, obtenu=%d", expectedLen, StringLen(readBack[0].payload)));
      TestAssert(readBack[0].payload == longPayload, "Correctif payload - Test 4 (long) : contenu integralement identique");
     }

   CleanTestFile(fileName);
  }

//---------------------------------------------------------------
// TEST OBLIGATOIRE 5 - Lecture apres fermeture/reouverture du
// fichier, avec un payload a caracteres speciaux ecrit AVANT la
// fermeture.
//---------------------------------------------------------------
void Test_Read_AfterCloseReopen()
  {
   string fileName = "Fix5_" + InpTestFileName;
   CleanTestFile(fileName);

   CResearchDataLayer rdl1;
   rdl1.Init(fileName);
   SResearchEvent w1;
   rdl1.WriteEvent("SYNTHETIC", "S", "A", "X", "C6", "avant=fermeture;avec=separateur", w1);
   rdl1 = CResearchDataLayer(); // fermeture explicite

   SResearchEvent readBack[];
   int count = CResearchDataReader::ReadAllEvents(fileName, readBack);
   TestAssert(count == 1, "Correctif payload - Test 5 (reouverture) : evenement present apres fermeture/reouverture",
              StringFormat("obtenu=%d", count));
   if(count == 1)
      TestAssert(readBack[0].payload == "avant=fermeture;avec=separateur",
                 "Correctif payload - Test 5 (reouverture) : payload a separateur interne toujours correct apres reouverture");

   CleanTestFile(fileName);
  }

//+------------------------------------------------------------------+
//| Point d'entree du script                                            |
//+------------------------------------------------------------------+
void OnStart()
  {
   Print("========================================================");
   Print("  Sprint V3.9 - Increment I1 - Tests Research Data Layer");
   Print("  Evenements SYNTHETIQUES uniquement - aucun lien EA");
   Print("========================================================");

   Test_RoundTrip_SimpleEvents();
   Test_EventId_Monotone();
   Test_Integrity_AppendAcrossReopen();
   Test_Read_MissingFile();
   Test_Write_BeforeInit();
   Test_RoundTrip_SpecialCharacters();

   Print("--- Sprint V3.9.3.4 : tests obligatoires du correctif payload ---");
   Test_Payload_Simple();
   Test_Payload_WithSeparator();
   Test_Payload_WithQuotes();
   Test_Payload_Long();
   Test_Read_AfterCloseReopen();

   Print("========================================================");
   PrintFormat("  RESULTAT : %d/%d tests reussis", g_testsPassed, g_testsRun);
   Print(g_testsPassed == g_testsRun ? "  TOUS LES TESTS SONT PASSES" : "  ECHECS DETECTES - voir [FAIL] ci-dessus");
   Print("========================================================");
  }
//+------------------------------------------------------------------+