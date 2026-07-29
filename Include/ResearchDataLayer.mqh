//+------------------------------------------------------------------+
//|                                          ResearchDataLayer.mqh     |
//|                                              NexusEdgeEA           |
//|                                                                    |
//| SPRINT V3.9 - Incrément I1 : Research Data Layer Foundation.        |
//| SPRINT V3.9.3.4 - Correctif d'intégrité du champ "payload" (CSV).   |
//| SPRINT V3.9.3.5 - STABILISATION DÉFINITIVE : migration JSON Lines.  |
//|                                                                    |
//| POURQUOI CETTE MIGRATION : le correctif V3.9.3.4 a résolu le        |
//| défaut de collision de délimiteur en implémentant un échappement    |
//| CSV (RFC4180) fait main. Ça fonctionnait, mais chaque nouvelle       |
//| famille d'événement (Protection en I4, Broker/Diagnostic/Erreur en  |
//| I5) aurait exigé de faire à nouveau confiance à cet échappement      |
//| artisanal. Le format JSON Lines élimine structurellement cette       |
//| classe de défaut : chaque ligne est un objet JSON autonome,          |
//| auto-descriptif, dont l'échappement (guillemets, antislash,          |
//| caractères de contrôle) suit une norme largement outillée - et       |
//| directement exploitable par les futurs outils d'analyse (Python      |
//| pandas.read_json(lines=True), sans aucune étape de conversion).      |
//| C'était déjà la trajectoire envisagée dès la conception initiale     |
//| de la Research Data Layer (Phase 2 : JSONL "si la rigidité du CSV    |
//| devient un frein réel") - simplement anticipée maintenant plutôt     |
//| que remise en jeu à chaque nouvelle famille d'événement.              |
//|                                                                    |
//| CE QUI NE CHANGE PAS (garanti par cette migration) :                 |
//|   - Le contrat SResearchEvent (9 champs) - identique, au bit près.   |
//|   - Les signatures publiques de WriteEvent()/ReadAllEvents() -       |
//|     aucun appelant (ObservationLayer.mqh) n'a besoin d'être modifié. |
//|   - L'append-only strict (V3.8.3 §7) - une ligne JSON par événement, |
//|     jamais de réécriture, toujours en fin de fichier.                |
//|   - Les 4 familles déjà en production (DECISION, CONTEXT,            |
//|     EXECUTION_OPEN, EXECUTION_CLOSE) - contenu identique, seule la   |
//|     représentation sur disque change.                                 |
//|                                                                    |
//| CE QUI CHANGE : l'extension de fichier (.jsonl au lieu de .csv,       |
//| mise à jour dans NexusEdgeEA.mq5 - un seul littéral de nom de         |
//| fichier, aucune logique de trading concernée) et l'implémentation     |
//| interne d'écriture/lecture, entièrement contenue dans ce fichier.     |
//|                                                                    |
//| STATUT : cette couche de persistance est désormais considérée        |
//| GELÉE. Toute évolution future du format de stockage (SQLite, base     |
//| externe) devra être une décision explicite et justifiée par un       |
//| besoin démontré (V3.8, trajectoire Phase 3) - pas une correction      |
//| réactive à un nouveau défaut découvert au fil des incréments I4/I5.  |
//+------------------------------------------------------------------+
#property copyright "NexusEdgeEA"
#property strict

#ifndef RESEARCHDATALAYER_MQH
#define RESEARCHDATALAYER_MQH

//+------------------------------------------------------------------+
//| SResearchEvent - le contrat générique entre l'Observation Layer   |
//| et la Research Data Layer. INCHANGÉ par la migration V3.9.3.5.     |
//+------------------------------------------------------------------+
struct SResearchEvent
  {
   int      schemaVersion;   // Version du schéma
   ulong    eventId;         // Identifiant de SESSION (V3.9.1) - monotone au sein d'une seule instance/session, jamais entre sessions - voir correlationId pour ce besoin
   string   eventFamily;     // Famille de l'événement (V3.8.3 §3)
   datetime timestamp;       // Horodatage de la capture, pas de la lecture
   string   strategyId;      // V3.8.3 §6
   string   accountId;       // Idem
   string   symbolId;        // Idem
   string   correlationId;   // Relie plusieurs événements entre eux (V3.8.3 §6)
   string   payload;         // Contenu métier, opaque à cette couche (V3.8.3 §1)
  };

//+------------------------------------------------------------------+
//| Encodage/décodage JSON - STRICTEMENT internes à ce fichier, jamais |
//| exposés à l'appelant. Volontairement un encodeur/décodeur minimal   |
//| et ciblé sur le schéma FIXE de SResearchEvent (9 clés connues à     |
//| l'avance) - pas une bibliothèque JSON générale, qui serait hors de  |
//| proportion avec le besoin réel (cohérent avec la discipline "ne pas |
//| sur-engineerer" déjà appliquée à chaque décision de ce projet).      |
//+------------------------------------------------------------------+
string ResearchJson_EscapeString(const string value)
  {
   string escaped = value;
   StringReplace(escaped, "\\", "\\\\"); // Antislash EN PREMIER, sinon les echappements suivants seraient eux-memes doublement echappes
   StringReplace(escaped, "\"", "\\\"");
   StringReplace(escaped, "\n", "\\n");
   StringReplace(escaped, "\r", "\\r");
   StringReplace(escaped, "\t", "\\t");
   return(escaped);
  }

//+------------------------------------------------------------------+
//| ResearchJson_ExtractString - retrouve la valeur associee a une cle  |
//| chaine connue ("clé":"valeur") dans une ligne JSON, en respectant   |
//| les sequences d'echappement. Symetrique exact de EscapeString.      |
//+------------------------------------------------------------------+
string ResearchJson_ExtractString(const string json, const string key)
  {
   string searchKey = "\"" + key + "\":\"";
   int    pos       = StringFind(json, searchKey);
   if(pos < 0)
      return("");

   int    i      = pos + StringLen(searchKey);
   int    len    = StringLen(json);
   string result = "";

   while(i < len)
     {
      string ch = StringSubstr(json, i, 1);
      if(ch == "\\" && i + 1 < len)
        {
         string next = StringSubstr(json, i + 1, 1);
         if(next == "n")       result += "\n";
         else if(next == "r")  result += "\r";
         else if(next == "t")  result += "\t";
         else if(next == "\"") result += "\"";
         else if(next == "\\") result += "\\";
         else                  result += next;
         i += 2;
         continue;
        }
      if(ch == "\"")
         break; // Guillemet non echappe = fin de la valeur
      result += ch;
      i++;
     }
   return(result);
  }

//+------------------------------------------------------------------+
//| ResearchJson_ExtractLong - retrouve la valeur numerique associee a  |
//| une cle connue ("clé":123).                                         |
//+------------------------------------------------------------------+
long ResearchJson_ExtractLong(const string json, const string key)
  {
   string searchKey = "\"" + key + "\":";
   int    pos       = StringFind(json, searchKey);
   if(pos < 0)
      return(0);

   int    i      = pos + StringLen(searchKey);
   int    len    = StringLen(json);
   string numStr = "";

   while(i < len)
     {
      string ch = StringSubstr(json, i, 1);
      if((ch >= "0" && ch <= "9") || ch == "-")
        {
         numStr += ch;
         i++;
        }
      else
         break;
     }
   return(StringToInteger(numStr));
  }

//+------------------------------------------------------------------+
//| CResearchDataLayer - la primitive de persistance elle-même.       |
//| Interface publique STRICTEMENT INCHANGÉE par la migration V3.9.3.5.|
//+------------------------------------------------------------------+
class CResearchDataLayer
  {
private:
   int    m_fileHandle;
   bool   m_initialized;
   ulong  m_nextEventId;
   string m_fileName;

   static const int SCHEMA_VERSION_CURRENT;

public:
                     CResearchDataLayer()
     {
      m_fileHandle  = INVALID_HANDLE;
      m_initialized = false;
      m_nextEventId = 1;
      m_fileName    = "";
     }

                    ~CResearchDataLayer()
     {
      if(m_fileHandle != INVALID_HANDLE)
        {
         FileFlush(m_fileHandle);
         FileClose(m_fileHandle);
         m_fileHandle = INVALID_HANDLE;
        }
     }

   //---------------------------------------------------------------
   // Init - ouvre (ou crée) le fichier .jsonl. Aucun en-tête de
   // colonnes n'existe plus en JSON Lines (chaque ligne est
   // auto-descriptive) - la notion d'en-tête disparaît, elle
   // n'appartenait qu'au format CSV. Append-only strict conservé.
   //---------------------------------------------------------------
   bool              Init(const string fileName)
     {
      m_fileName   = fileName;
      m_fileHandle = FileOpen(fileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(m_fileHandle == INVALID_HANDLE)
        {
         PrintFormat("CResearchDataLayer::Init - echec d'ouverture de %s (erreur %d)", fileName, GetLastError());
         return(false);
        }

      FileSeek(m_fileHandle, 0, SEEK_END); // Garantit l'ajout en fin de fichier, jamais une réécriture
      m_nextEventId = 1;
      m_initialized = true;
      return(true);
     }

   bool              IsInitialized() const { return(m_initialized); }

   //---------------------------------------------------------------
   // WriteEvent - écrit un événement de façon immédiate et
   // irréversible, sous la forme d'une ligne JSON autonome. Chaque
   // champ texte passe par ResearchJson_EscapeString() avant écriture.
   //---------------------------------------------------------------
   bool              WriteEvent(const string eventFamily, const string strategyId, const string accountId,
                                const string symbolId, const string correlationId, const string payload,
                                SResearchEvent &eventOut)
     {
      eventOut.schemaVersion = 0;
      eventOut.eventId       = 0;
      eventOut.eventFamily   = eventFamily;
      eventOut.timestamp     = 0;
      eventOut.strategyId    = strategyId;
      eventOut.accountId     = accountId;
      eventOut.symbolId      = symbolId;
      eventOut.correlationId = correlationId;
      eventOut.payload       = payload;

      if(!m_initialized)
         return(false);

      eventOut.schemaVersion = SCHEMA_VERSION_CURRENT;
      eventOut.eventId       = m_nextEventId;
      eventOut.timestamp     = TimeCurrent();

      string line = StringFormat(
         "{\"schemaVersion\":%d,\"eventId\":%I64u,\"eventFamily\":\"%s\",\"timestamp\":\"%s\",\"strategyId\":\"%s\",\"accountId\":\"%s\",\"symbolId\":\"%s\",\"correlationId\":\"%s\",\"payload\":\"%s\"}\r\n",
         eventOut.schemaVersion,
         eventOut.eventId,
         ResearchJson_EscapeString(eventOut.eventFamily),
         ResearchJson_EscapeString(TimeToString(eventOut.timestamp, TIME_DATE | TIME_SECONDS)),
         ResearchJson_EscapeString(eventOut.strategyId),
         ResearchJson_EscapeString(eventOut.accountId),
         ResearchJson_EscapeString(eventOut.symbolId),
         ResearchJson_EscapeString(eventOut.correlationId),
         ResearchJson_EscapeString(eventOut.payload));

      uint written = FileWriteString(m_fileHandle, line);
      if(written == 0)
        {
         PrintFormat("CResearchDataLayer::WriteEvent - echec d'ecriture (erreur %d)", GetLastError());
         return(false);
        }

      FileFlush(m_fileHandle); // Ecriture immediate sur disque
      m_nextEventId++;
      return(true);
     }

   int               GetWrittenCount() const { return((int)(m_nextEventId - 1)); }

   string            GetFileName() const { return(m_fileName); }
  };

const int CResearchDataLayer::SCHEMA_VERSION_CURRENT = 1;

//+------------------------------------------------------------------+
//| CResearchDataReader - lecture de validation UNIQUEMENT. Interface  |
//| publique STRICTEMENT INCHANGÉE par la migration V3.9.3.5.           |
//+------------------------------------------------------------------+
class CResearchDataReader
  {
public:
   //---------------------------------------------------------------
   // ReadAllEvents - relit l'intégralité d'un fichier .jsonl déjà
   // persisté, dans l'ordre d'écriture. Une ligne = un objet JSON =
   // un événement, aucun en-tête à ignorer (contrairement au CSV).
   //---------------------------------------------------------------
   static int        ReadAllEvents(const string fileName, SResearchEvent &eventsOut[])
     {
      ArrayResize(eventsOut, 0);
      int handle = FileOpen(fileName, FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle == INVALID_HANDLE)
        {
         PrintFormat("CResearchDataReader::ReadAllEvents - echec d'ouverture de %s (erreur %d)", fileName, GetLastError());
         return(-1);
        }

      int count = 0;
      while(!FileIsEnding(handle))
        {
         string line = FileReadString(handle);
         if(StringLen(line) == 0)
            continue; // Ligne finale vide eventuelle - garde-fou, pas une donnee reelle

         SResearchEvent ev;
         ev.schemaVersion = (int)ResearchJson_ExtractLong(line, "schemaVersion");
         ev.eventId       = (ulong)ResearchJson_ExtractLong(line, "eventId");
         ev.eventFamily   = ResearchJson_ExtractString(line, "eventFamily");
         ev.timestamp     = StringToTime(ResearchJson_ExtractString(line, "timestamp"));
         ev.strategyId    = ResearchJson_ExtractString(line, "strategyId");
         ev.accountId     = ResearchJson_ExtractString(line, "accountId");
         ev.symbolId      = ResearchJson_ExtractString(line, "symbolId");
         ev.correlationId = ResearchJson_ExtractString(line, "correlationId");
         ev.payload       = ResearchJson_ExtractString(line, "payload");

         int n = ArraySize(eventsOut);
         ArrayResize(eventsOut, n + 1);
         eventsOut[n] = ev;
         count++;
        }

      FileClose(handle);
      return(count);
     }
  };

#endif // RESEARCHDATALAYER_MQH
//+------------------------------------------------------------------+