//+------------------------------------------------------------------+
//|                                          SessionIndicator.mq5    |
//|   Indicatore sessioni di trading con rettangoli colorati         |
//|   Sydney, Asia/Tokyo, Europe/London, New York                    |
//|   + Gestione automatica ora legale italiana (CET/CEST)           |
//|   + Linea verticale al cambio ora legale                         |
//|                        Compatible with MetaTrader 5              |
//+------------------------------------------------------------------+
#property copyright   "SessionIndicator"
#property link        ""
#property version     "2.00"
#property indicator_chart_window
#property indicator_plots 0

//--- Sessioni (ora italiana) ---
input string   _sep1_              = "=== SESSIONI (ora italiana) ===";
input int      SydneyOpen          = 23;    // Sydney apertura (ora IT)
input int      SydneyClose         = 8;     // Sydney chiusura (ora IT)
input int      AsiaOpen            = 2;     // Asia/Tokyo apertura (ora IT)
input int      AsiaClose           = 10;    // Asia/Tokyo chiusura (ora IT)
input int      EuropeOpen          = 9;     // Europe/London apertura (ora IT)
input int      EuropeClose         = 18;    // Europe/London chiusura (ora IT)
input int      NewYorkOpen         = 15;    // New York apertura (ora IT)
input int      NewYorkClose        = 23;    // New York chiusura (ora IT)

//--- Colori rettangoli ---
input string   _sep2_              = "=== COLORI RETTANGOLI ===";
input color    ColorSydney         = clrMistyRose;       // Colore Sydney
input color    ColorAsia           = clrLightCyan;       // Colore Asia/Tokyo
input color    ColorEurope         = clrHoneydew;        // Colore Europe/London
input color    ColorNewYork        = clrLavender;        // Colore New York

//--- Colori etichette ---
input string   _sep3_              = "=== COLORI ETICHETTE ===";
input color    LabelColorSydney    = clrCoral;           // Etichetta Sydney
input color    LabelColorAsia      = clrDarkCyan;        // Etichetta Asia/Tokyo
input color    LabelColorEurope    = clrGreen;           // Etichetta Europe/London
input color    LabelColorNewYork   = clrMediumSlateBlue; // Etichetta New York
input int      LabelFontSize       = 10;                 // Dimensione font etichette

//--- Linea cambio ora legale ---
input string   _sep4_              = "=== LINEA CAMBIO ORA LEGALE ===";
input bool     ShowDSTLine         = true;               // Mostra linea cambio ora legale
input color    DSTLineColor        = clrRed;             // Colore linea DST
input int      DSTLineWidth        = 2;                  // Spessore linea DST

//--- Fuso orario ---
input string   _sep5_              = "=== FUSO ORARIO ===";
input bool     AutoDST             = true;  // Gestione automatica ora legale italiana
input int      ManualGmtOffset     = 1;     // Offset GMT manuale (se AutoDST=false)

//--- Quanti giorni di sessioni disegnare ---
input int      DaysToShow          = 30;    // Giorni di sessioni da mostrare

//--- Costanti ---
#define PREFIX_SI "SI_"

//--- Variabili globali ---
int    g_cachedServerGmtDiff = 0;
bool   g_serverGmtDiffValid  = false;
int    g_lastDrawnBars = 0;

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

   int q = lastDay, m = month, y = year;
   if(m < 3) { m += 12; y--; }
   int k = y % 100;
   int j = y / 100;
   int h = (q + (13 * (m + 1)) / 5 + k + k / 4 + j / 4 - 2 * j) % 7;
   if(h < 0) h += 7;

   int daysBack = (h == 1) ? 0 : (h == 0) ? 6 : h - 1;
   return lastDay - daysBack;
}

//+------------------------------------------------------------------+
//| Determina se una data/ora GMT e' in ora legale italiana (CEST)   |
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
//| Converte ora italiana in server time per un dato giorno          |
//| dayBase = mezzanotte server del giorno di riferimento            |
//+------------------------------------------------------------------+
datetime ItalianHourToServerTime(int italianHour, datetime serverMidnight)
{
   datetime gmtMidnight = serverMidnight - g_cachedServerGmtDiff;
   int offset = GetItalianGmtOffset(gmtMidnight);

   // GMT target per l'ora italiana richiesta
   datetime targetGmt = gmtMidnight + (italianHour - offset) * 3600;

   // Raffina offset DST per l'ora target
   int correctedOffset = GetItalianGmtOffset(targetGmt);
   if(correctedOffset != offset)
      targetGmt = gmtMidnight + (italianHour - correctedOffset) * 3600;

   return targetGmt + g_cachedServerGmtDiff;
}

//+------------------------------------------------------------------+
//| Trova high e low del prezzo in un range di tempo                 |
//+------------------------------------------------------------------+
void GetPriceRange(datetime tStart, datetime tEnd, double &high, double &low)
{
   high = 0;
   low  = DBL_MAX;

   int barStart = iBarShift(_Symbol, PERIOD_CURRENT, tStart, false);
   int barEnd   = iBarShift(_Symbol, PERIOD_CURRENT, tEnd, false);

   if(barStart < 0) barStart = 0;
   if(barEnd < 0)   barEnd = 0;

   // barStart e' il piu' vecchio (indice alto), barEnd il piu' recente (indice basso)
   int from = MathMin(barStart, barEnd);
   int to   = MathMax(barStart, barEnd);

   if(to - from > 500) to = from + 500;

   double highs[], lows[];
   int copied_h = CopyHigh(_Symbol, PERIOD_CURRENT, from, to - from + 1, highs);
   int copied_l = CopyLow(_Symbol, PERIOD_CURRENT, from, to - from + 1, lows);

   if(copied_h <= 0 || copied_l <= 0)
   {
      high = iHigh(_Symbol, PERIOD_CURRENT, from);
      low  = iLow(_Symbol, PERIOD_CURRENT, from);
      return;
   }

   int count = MathMin(copied_h, copied_l);
   for(int i = 0; i < count; i++)
   {
      if(highs[i] > high) high = highs[i];
      if(lows[i] < low)   low  = lows[i];
   }

   if(high <= 0 || low >= DBL_MAX)
   {
      high = iHigh(_Symbol, PERIOD_CURRENT, 0);
      low  = iLow(_Symbol, PERIOD_CURRENT, 0);
   }
}

//+------------------------------------------------------------------+
//| Disegna un rettangolo sessione con etichetta                     |
//+------------------------------------------------------------------+
void DrawSessionRect(string name, datetime tStart, datetime tEnd,
                     color rectColor, color labelColor, string labelText)
{
   double high, low;
   GetPriceRange(tStart, tEnd, high, low);

   // Aggiungi un po' di margine
   double range = high - low;
   if(range <= 0) range = high * 0.001;
   high += range * 0.02;
   low  -= range * 0.02;

   // Rettangolo
   string rectName = PREFIX_SI + "RECT_" + name;
   if(ObjectFind(0, rectName) >= 0)
   {
      ObjectSetInteger(0, rectName, OBJPROP_TIME, 0, tStart);
      ObjectSetDouble(0, rectName, OBJPROP_PRICE, 0, high);
      ObjectSetInteger(0, rectName, OBJPROP_TIME, 1, tEnd);
      ObjectSetDouble(0, rectName, OBJPROP_PRICE, 1, low);
   }
   else
   {
      ObjectCreate(0, rectName, OBJ_RECTANGLE, 0, tStart, high, tEnd, low);
      ObjectSetInteger(0, rectName, OBJPROP_COLOR, rectColor);
      ObjectSetInteger(0, rectName, OBJPROP_FILL, true);
      ObjectSetInteger(0, rectName, OBJPROP_BACK, true);
      ObjectSetInteger(0, rectName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, rectName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, rectName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, rectName, OBJPROP_STYLE, STYLE_DOT);
   }

   // Etichetta (testo ancorato al tempo, in alto)
   string lblName = PREFIX_SI + "LBL_" + name;
   if(ObjectFind(0, lblName) >= 0)
   {
      ObjectSetInteger(0, lblName, OBJPROP_TIME, 0, tStart);
      ObjectSetDouble(0, lblName, OBJPROP_PRICE, 0, high);
   }
   else
   {
      ObjectCreate(0, lblName, OBJ_TEXT, 0, tStart, high);
      ObjectSetString(0, lblName, OBJPROP_TEXT, labelText);
      ObjectSetString(0, lblName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, LabelFontSize);
      ObjectSetInteger(0, lblName, OBJPROP_COLOR, labelColor);
      ObjectSetInteger(0, lblName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lblName, OBJPROP_HIDDEN, true);
   }
}

//+------------------------------------------------------------------+
//| Disegna le sessioni per un singolo giorno                        |
//+------------------------------------------------------------------+
void DrawDaySessions(datetime serverMidnight, string daySuffix)
{
   // Sydney (attraversa la mezzanotte: open giorno-1, close giorno corrente)
   if(SydneyOpen > SydneyClose)
   {
      datetime prevMidnight = serverMidnight - 86400;
      datetime sydOpen  = ItalianHourToServerTime(SydneyOpen, prevMidnight);
      datetime sydClose = ItalianHourToServerTime(SydneyClose, serverMidnight);
      DrawSessionRect("SYD_" + daySuffix, sydOpen, sydClose,
                      ColorSydney, LabelColorSydney, "Sydney");
   }
   else
   {
      datetime sydOpen  = ItalianHourToServerTime(SydneyOpen, serverMidnight);
      datetime sydClose = ItalianHourToServerTime(SydneyClose, serverMidnight);
      DrawSessionRect("SYD_" + daySuffix, sydOpen, sydClose,
                      ColorSydney, LabelColorSydney, "Sydney");
   }

   // Asia / Tokyo
   datetime asiaOpen  = ItalianHourToServerTime(AsiaOpen, serverMidnight);
   datetime asiaClose = ItalianHourToServerTime(AsiaClose, serverMidnight);
   DrawSessionRect("ASIA_" + daySuffix, asiaOpen, asiaClose,
                   ColorAsia, LabelColorAsia, "Asia    Tokyo");

   // Europe / London
   datetime euroOpen  = ItalianHourToServerTime(EuropeOpen, serverMidnight);
   datetime euroClose = ItalianHourToServerTime(EuropeClose, serverMidnight);
   DrawSessionRect("EUR_" + daySuffix, euroOpen, euroClose,
                   ColorEurope, LabelColorEurope, "Europe    London");

   // New York
   datetime nyOpen  = ItalianHourToServerTime(NewYorkOpen, serverMidnight);
   datetime nyClose = ItalianHourToServerTime(NewYorkClose, serverMidnight);
   DrawSessionRect("NY_" + daySuffix, nyOpen, nyClose,
                   ColorNewYork, LabelColorNewYork, "New York");
}

//+------------------------------------------------------------------+
//| Disegna la linea verticale al cambio ora legale                  |
//+------------------------------------------------------------------+
void DrawDSTLines()
{
   if(!ShowDSTLine) return;

   datetime gmtNow = TimeGMT();
   MqlDateTime dtNow;
   TimeToStruct(gmtNow, dtNow);
   int year = dtNow.year;

   // Controlla anno corrente e precedente
   for(int y = year - 1; y <= year; y++)
   {
      int marchSun   = LastSundayOfMonth(y, 3);
      int octoberSun = LastSundayOfMonth(y, 10);

      // Inizio CEST (ultima domenica di marzo alle 01:00 UTC)
      datetime dstStartGmt = StringToTime(StringFormat("%d.%02d.%02d 01:00", y, 3, marchSun));
      datetime dstStartServer = dstStartGmt + g_cachedServerGmtDiff;

      string nameStart = PREFIX_SI + "DST_START_" + IntegerToString(y);
      if(ObjectFind(0, nameStart) < 0)
      {
         ObjectCreate(0, nameStart, OBJ_VLINE, 0, dstStartServer, 0);
         ObjectSetInteger(0, nameStart, OBJPROP_COLOR, DSTLineColor);
         ObjectSetInteger(0, nameStart, OBJPROP_WIDTH, DSTLineWidth);
         ObjectSetInteger(0, nameStart, OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, nameStart, OBJPROP_BACK, false);
         ObjectSetInteger(0, nameStart, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nameStart, OBJPROP_HIDDEN, true);
         ObjectSetString(0, nameStart, OBJPROP_TOOLTIP,
                         "Inizio ora legale (CEST) " + IntegerToString(y));
      }

      // Fine CEST (ultima domenica di ottobre alle 01:00 UTC)
      datetime dstEndGmt = StringToTime(StringFormat("%d.%02d.%02d 01:00", y, 10, octoberSun));
      datetime dstEndServer = dstEndGmt + g_cachedServerGmtDiff;

      string nameEnd = PREFIX_SI + "DST_END_" + IntegerToString(y);
      if(ObjectFind(0, nameEnd) < 0)
      {
         ObjectCreate(0, nameEnd, OBJ_VLINE, 0, dstEndServer, 0);
         ObjectSetInteger(0, nameEnd, OBJPROP_COLOR, DSTLineColor);
         ObjectSetInteger(0, nameEnd, OBJPROP_WIDTH, DSTLineWidth);
         ObjectSetInteger(0, nameEnd, OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, nameEnd, OBJPROP_BACK, false);
         ObjectSetInteger(0, nameEnd, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nameEnd, OBJPROP_HIDDEN, true);
         ObjectSetString(0, nameEnd, OBJPROP_TOOLTIP,
                         "Fine ora legale (CET) " + IntegerToString(y));
      }
   }
}

//+------------------------------------------------------------------+
//| Disegna tutte le sessioni per i giorni visibili                  |
//+------------------------------------------------------------------+
void DrawAllSessions()
{
   if(!g_serverGmtDiffValid) return;

   // Calcola la mezzanotte server di oggi
   MqlDateTime dtServer;
   TimeToStruct(TimeCurrent(), dtServer);
   dtServer.hour = 0;
   dtServer.min  = 0;
   dtServer.sec  = 0;
   datetime todayMidnight = StructToTime(dtServer);

   // Disegna per N giorni indietro + oggi
   for(int d = -DaysToShow; d <= 0; d++)
   {
      datetime dayMidnight = todayMidnight + d * 86400;

      // Salta weekend (sabato=6, domenica=0)
      MqlDateTime dtDay;
      TimeToStruct(dayMidnight, dtDay);
      if(dtDay.day_of_week == 0 || dtDay.day_of_week == 6) continue;

      string daySuffix = TimeToString(dayMidnight, TIME_DATE);
      DrawDaySessions(dayMidnight, daySuffix);
   }

   // Disegna linee cambio ora legale
   DrawDSTLines();
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
   EventSetTimer(60);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   CleanupObjects();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Timer event                                                      |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_serverGmtDiffValid)
   {
      DrawAllSessions();
      ChartRedraw(0);
   }
}

//+------------------------------------------------------------------+
//| Tick event                                                       |
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
   // Cache server-GMT offset
   g_cachedServerGmtDiff = (int)(TimeCurrent() - TimeGMT());
   if(!g_serverGmtDiffValid)
   {
      g_serverGmtDiffValid = true;
      DrawAllSessions();
      ChartRedraw(0);
      g_lastDrawnBars = rates_total;
      return(rates_total);
   }

   // Ridisegna se nuove barre
   if(rates_total != g_lastDrawnBars)
   {
      DrawAllSessions();
      ChartRedraw(0);
      g_lastDrawnBars = rates_total;
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
