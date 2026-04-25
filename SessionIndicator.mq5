//+------------------------------------------------------------------+
//|                                          SessionIndicator.mq5    |
//|   Indicatore sessioni di trading con gestione ora legale IT      |
//|   Sessioni: Asia (Tokyo), Londra, New York + Overlap             |
//|                        Compatible with MetaTrader 5              |
//+------------------------------------------------------------------+
#property copyright   "SessionIndicator"
#property link        ""
#property version     "1.00"
#property indicator_chart_window
#property indicator_plots 0

//--- Input configurabili dall'utente ---
input string   _sep1_              = "=== SESSIONI (ora italiana) ===";
input int      AsiaOpen            = 2;     // Asia apertura (ora IT)
input int      AsiaClose           = 10;    // Asia chiusura (ora IT)
input int      LondonOpen          = 10;    // Londra apertura (ora IT)
input int      LondonClose         = 18;    // Londra chiusura (ora IT)
input int      NewYorkOpen         = 15;    // New York apertura (ora IT)
input int      NewYorkClose        = 23;    // New York chiusura (ora IT)

input string   _sep2_              = "=== COLORI SFONDO ===";
input color    ColorAsia           = clrMidnightBlue;    // Colore Asia
input color    ColorLondon         = clrDarkBlue;        // Colore Londra
input color    ColorNewYork        = clrDarkGreen;       // Colore New York
input color    ColorOverlapLdnNy   = clrDarkSlateBlue;   // Colore Overlap Londra/NY
input color    ColorOverlapAsiaLdn = clrDarkCyan;        // Colore Overlap Asia/Londra
input color    ColorOff            = clrBlack;           // Colore fuori sessione

input string   _sep3_              = "=== LINEE VERTICALI ===";
input bool     ShowVerticalLines   = true;   // Mostra linee verticali
input color    VLineColorAsia      = clrDodgerBlue;      // Colore linea Asia
input color    VLineColorLondon    = clrRoyalBlue;       // Colore linea Londra
input color    VLineColorNewYork   = clrLimeGreen;       // Colore linea New York
input ENUM_LINE_STYLE VLineStyle   = STYLE_DOT;          // Stile linea
input int      VLineWidth          = 1;                  // Spessore linea

input string   _sep4_              = "=== ETICHETTA ===";
input bool     ShowLabel           = true;               // Mostra etichetta sessione
input int      LabelX              = 10;                 // Posizione X etichetta
input int      LabelY              = 30;                 // Posizione Y etichetta
input int      LabelFontSize       = 12;                 // Dimensione font
input color    LabelColor          = clrWhite;           // Colore testo etichetta

input string   _sep5_              = "=== FUSO ORARIO ===";
input bool     AutoDST             = true;  // Gestione automatica ora legale italiana
input int      ManualGmtOffset     = 1;     // Offset GMT manuale (usato se AutoDST=false)

//--- Costanti ---
#define PREFIX_SI "SI_"

//--- Variabili globali ---
color  g_originalBg = clrBlack;
string g_lastItalianDate = "";
string g_lastSessionName = "";
int    g_cachedServerGmtDiff = 0;
bool   g_serverGmtDiffValid  = false;

//+------------------------------------------------------------------+
//| Calcola l'ultimo giorno domenica di un dato mese/anno            |
//+------------------------------------------------------------------+
int LastSundayOfMonth(int year, int month)
{
   int lastDay = 31;
   if(month == 4 || month == 6 || month == 9 || month == 11) lastDay = 30;
   if(month == 2)
   {
      lastDay = 28;
      if(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))
         lastDay = 29;
   }

   // Zeller's algorithm
   int q = lastDay;
   int m = month;
   int y = year;
   if(m < 3) { m += 12; y--; }
   int k = y % 100;
   int j = y / 100;
   int h = (q + (13 * (m + 1)) / 5 + k + k / 4 + j / 4 - 2 * j) % 7;
   if(h < 0) h += 7;
   // h: 0=Sab, 1=Dom, 2=Lun, 3=Mar, 4=Mer, 5=Gio, 6=Ven

   int daysBack = (h == 1) ? 0 : (h == 0) ? 6 : h - 1;
   return lastDay - daysBack;
}

//+------------------------------------------------------------------+
//| Determina se una data/ora GMT e' in ora legale italiana (CEST)   |
//| CET  = UTC+1 (inverno)                                          |
//| CEST = UTC+2 (estate, ultima dom. marzo 01:00 UTC ->            |
//|                        ultima dom. ottobre 01:00 UTC)            |
//+------------------------------------------------------------------+
bool IsItalianDST(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);

   int year = dt.year;

   int marchSunday   = LastSundayOfMonth(year, 3);
   int octoberSunday = LastSundayOfMonth(year, 10);

   datetime dstStart = StringToTime(StringFormat("%d.%02d.%02d 01:00", year, 3, marchSunday));
   datetime dstEnd   = StringToTime(StringFormat("%d.%02d.%02d 01:00", year, 10, octoberSunday));

   return (gmtTime >= dstStart && gmtTime < dstEnd);
}

//+------------------------------------------------------------------+
//| Ritorna l'offset italiano corrente (+1 CET o +2 CEST)           |
//+------------------------------------------------------------------+
int GetItalianGmtOffset(datetime gmtTime)
{
   if(!AutoDST) return ManualGmtOffset;
   return IsItalianDST(gmtTime) ? 2 : 1;
}

//+------------------------------------------------------------------+
//| Converte l'ora del server MT5 in ora italiana                    |
//+------------------------------------------------------------------+
int GetItalianHour()
{
   datetime gmtTime = TimeGMT();
   int offset = GetItalianGmtOffset(gmtTime);
   MqlDateTime dt;
   TimeToStruct(gmtTime + offset * 3600, dt);
   return dt.hour;
}

//+------------------------------------------------------------------+
//| Ritorna il nome della sessione attiva                            |
//+------------------------------------------------------------------+
string GetSessionName(int oraIT)
{
   bool asia    = (oraIT >= AsiaOpen    && oraIT < AsiaClose);
   bool london  = (oraIT >= LondonOpen  && oraIT < LondonClose);
   bool newyork = (oraIT >= NewYorkOpen && oraIT < NewYorkClose);

   if(london && newyork) return "OVERLAP LDN / NY";
   if(asia && london)    return "OVERLAP ASIA / LDN";
   if(newyork)           return "NEW YORK";
   if(london)            return "LONDRA";
   if(asia)              return "ASIA (TOKYO)";
   return "FUORI SESSIONE";
}

//+------------------------------------------------------------------+
//| Ritorna il colore di sfondo per la sessione attiva               |
//+------------------------------------------------------------------+
color GetSessionColor(int oraIT)
{
   bool asia    = (oraIT >= AsiaOpen    && oraIT < AsiaClose);
   bool london  = (oraIT >= LondonOpen  && oraIT < LondonClose);
   bool newyork = (oraIT >= NewYorkOpen && oraIT < NewYorkClose);

   if(london && newyork) return ColorOverlapLdnNy;
   if(asia && london)    return ColorOverlapAsiaLdn;
   if(newyork)           return ColorNewYork;
   if(london)            return ColorLondon;
   if(asia)              return ColorAsia;
   return ColorOff;
}

//+------------------------------------------------------------------+
//| Crea o aggiorna l'etichetta della sessione sul grafico           |
//+------------------------------------------------------------------+
void UpdateSessionLabel(string sessionName, int oraIT)
{
   if(!ShowLabel) return;

   string labelName = PREFIX_SI + "LABEL";
   int offset = GetItalianGmtOffset(TimeGMT());
   string dstStr = (AutoDST) ? ((offset == 2) ? " (CEST)" : " (CET)") : "";
   string text = sessionName + "  |  " + IntegerToString(oraIT) + ":00 IT" + dstStr;

   if(ObjectFind(0, labelName) < 0)
   {
      ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, labelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   }

   ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, LabelX);
   ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, LabelY);
   ObjectSetString(0, labelName, OBJPROP_TEXT, text);
   ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, LabelFontSize);
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, LabelColor);
   ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, labelName, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Disegna una linea verticale per apertura/chiusura sessione       |
//+------------------------------------------------------------------+
void DrawSessionLine(datetime time, string name, color clr, string tooltip)
{
   if(!ShowVerticalLines) return;

   string objName = PREFIX_SI + "VL_" + name + "_" + TimeToString(time, TIME_DATE);

   if(ObjectFind(0, objName) >= 0)
   {
      ObjectSetInteger(0, objName, OBJPROP_TIME, 0, time);
      return;
   }

   ObjectCreate(0, objName, OBJ_VLINE, 0, time, 0);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_STYLE, VLineStyle);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, VLineWidth);
   ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
   ObjectSetString(0, objName, OBJPROP_TOOLTIP, tooltip);
}

//+------------------------------------------------------------------+
//| Calcola la datetime per un'ora italiana di oggi                   |
//| e la converte in ora del server per disegnare le linee           |
//+------------------------------------------------------------------+
datetime ItalianHourToServerTime(int italianHour)
{
   datetime gmtNow = TimeGMT();
   int offset = GetItalianGmtOffset(gmtNow);

   // Calcola la mezzanotte italiana di oggi (in Italian time), poi converti in GMT
   datetime italianNow = gmtNow + offset * 3600;
   MqlDateTime dtIt;
   TimeToStruct(italianNow, dtIt);
   dtIt.hour = 0;
   dtIt.min  = 0;
   dtIt.sec  = 0;
   datetime italianMidnight = StructToTime(dtIt);

   // Ora GMT corrispondente all'ora italiana desiderata
   datetime targetGmt = italianMidnight + (italianHour - offset) * 3600;

   // Differenza server-GMT (usa offset cached aggiornato ad ogni tick)
   int serverGmtDiff = g_serverGmtDiffValid ? g_cachedServerGmtDiff
                                             : (int)(TimeCurrent() - TimeGMT());

   return targetGmt + serverGmtDiff;
}

//+------------------------------------------------------------------+
//| Disegna tutte le linee verticali per la giornata corrente        |
//+------------------------------------------------------------------+
void DrawTodaySessionLines()
{
   if(!ShowVerticalLines) return;

   DrawSessionLine(ItalianHourToServerTime(AsiaOpen),
                   "ASIA_OPEN", VLineColorAsia, "Asia Open " + IntegerToString(AsiaOpen) + ":00 IT");
   DrawSessionLine(ItalianHourToServerTime(AsiaClose),
                   "ASIA_CLOSE", VLineColorAsia, "Asia Close " + IntegerToString(AsiaClose) + ":00 IT");

   DrawSessionLine(ItalianHourToServerTime(LondonOpen),
                   "LDN_OPEN", VLineColorLondon, "Londra Open " + IntegerToString(LondonOpen) + ":00 IT");
   DrawSessionLine(ItalianHourToServerTime(LondonClose),
                   "LDN_CLOSE", VLineColorLondon, "Londra Close " + IntegerToString(LondonClose) + ":00 IT");

   DrawSessionLine(ItalianHourToServerTime(NewYorkOpen),
                   "NY_OPEN", VLineColorNewYork, "New York Open " + IntegerToString(NewYorkOpen) + ":00 IT");
   DrawSessionLine(ItalianHourToServerTime(NewYorkClose),
                   "NY_CLOSE", VLineColorNewYork, "New York Close " + IntegerToString(NewYorkClose) + ":00 IT");
}

//+------------------------------------------------------------------+
//| Pulizia oggetti all'uscita                                       |
//+------------------------------------------------------------------+
void CleanupObjects()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, PREFIX_SI) == 0)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| Custom indicator initialization                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   // Salva il colore di sfondo originale per ripristinarlo in OnDeinit
   g_originalBg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);

   // Aggiorna tutto subito
   UpdateAll();

   // Timer ogni 30 secondi per aggiornamento continuo
   EventSetTimer(30);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   CleanupObjects();
   // Ripristina il colore di sfondo originale
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, g_originalBg);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Ritorna la data italiana corrente come stringa "YYYY.MM.DD"      |
//+------------------------------------------------------------------+
string GetItalianDateStr()
{
   datetime gmtNow = TimeGMT();
   int offset = GetItalianGmtOffset(gmtNow);
   datetime italianNow = gmtNow + offset * 3600;
   return TimeToString(italianNow, TIME_DATE);
}

//+------------------------------------------------------------------+
//| Logica di aggiornamento centralizzata                            |
//+------------------------------------------------------------------+
void UpdateAll()
{
   int oraIT = GetItalianHour();
   string sessionName = GetSessionName(oraIT);

   // Aggiorna colore sfondo
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, GetSessionColor(oraIT));

   // Aggiorna etichetta
   UpdateSessionLabel(sessionName, oraIT);

   // Ridisegna linee se cambio giorno (basato sulla data italiana)
   string currentDate = GetItalianDateStr();
   if(currentDate != g_lastItalianDate)
   {
      DrawTodaySessionLines();
      g_lastItalianDate = currentDate;
   }

   // Log cambio sessione
   if(sessionName != g_lastSessionName)
   {
      Print("[SessionIndicator] Cambio sessione: ", g_lastSessionName, " -> ", sessionName,
            "  (Ora IT: ", oraIT, ":00, DST: ", (GetItalianGmtOffset(TimeGMT()) == 2 ? "CEST" : "CET"), ")");
      g_lastSessionName = sessionName;
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Timer event - aggiornamento periodico                            |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateAll();
}

//+------------------------------------------------------------------+
//| Tick event - aggiornamento ad ogni tick                          |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // Cache server-GMT offset ad ogni tick (TimeCurrent e' fresco qui)
   g_cachedServerGmtDiff = (int)(TimeCurrent() - TimeGMT());
   g_serverGmtDiffValid  = true;

   UpdateAll();
   return(rates_total);
}
//+------------------------------------------------------------------+
