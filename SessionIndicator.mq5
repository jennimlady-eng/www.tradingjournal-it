//+------------------------------------------------------------------+
//|                                          SessionIndicator.mq5    |
//|   Indicatore sessioni di trading v3                              |
//|   Rettangoli: London, New York                                   |
//|   Tabella FOREX Session in alto a destra                         |
//|   Linea verticale rosso fuoco al cambio ora legale italiana      |
//|   Funziona su tutti i simboli e timeframe                        |
//+------------------------------------------------------------------+
#property copyright   "SessionIndicator"
#property link        ""
#property version     "3.00"
#property indicator_chart_window
#property indicator_plots 0

//--- Rettangoli sessione (ora italiana) ---
input string   _sep1_              = "=== RETTANGOLI (ora italiana) ===";
input int      LondonOpenIT        = 10;                  // Londra apertura IT
input int      LondonCloseIT       = 18;                  // Londra chiusura IT
input int      NewYorkOpenIT       = 15;                  // New York apertura IT
input int      NewYorkCloseIT      = 23;                  // New York chiusura IT
input color    ColorLondon         = C'15,50,15';         // Riempimento Londra
input color    ColorNewYork        = C'35,15,55';         // Riempimento New York
input color    BorderLondon        = C'0,160,0';          // Bordo Londra
input color    BorderNewYork       = C'120,80,200';       // Bordo New York
input color    LblColorLondon      = clrLime;             // Etichetta Londra
input color    LblColorNewYork     = C'180,130,255';      // Etichetta New York
input int      LabelFontSize       = 10;                  // Font etichette

//--- Linea cambio ora legale ---
input string   _sep2_              = "=== LINEA ORA LEGALE ===";
input bool     ShowDSTLine         = true;                // Mostra linea DST
input color    DSTLineColor        = clrRed;              // Rosso fuoco
input int      DSTLineWidth        = 3;                   // Spessore
input ENUM_LINE_STYLE DSTLineStyle = STYLE_DASH;          // Tratteggiata

//--- Tabella ---
input string   _sep3_              = "=== TABELLA SESSIONI ===";
input bool     ShowTable           = true;                // Mostra tabella

//--- Generale ---
input string   _sep4_              = "=== GENERALE ===";
input int      DaysToShow          = 30;                  // Giorni rettangoli
input bool     AutoDST             = true;                // DST automatica
input int      ManualGmtOffset     = 1;                   // Offset manuale

//--- Costanti ---
#define PREFIX "SI_"
#define NUM_SESS 7

// Layout tabella (CORNER_RIGHT_UPPER)
#define TBL_MARGIN   10
#define TBL_W        460
#define TBL_X        (TBL_MARGIN + TBL_W)
#define TBL_TITLE_H  24
#define TBL_HDR_H    20
#define TBL_ROW_H    20
#define COL_S        8
#define COL_D        85
#define COL_T1       230
#define COL_T2       320
#define COL_ST       400

//--- Variabili globali ---
int    g_srvDiff  = 0;
bool   g_diffOk   = false;
int    g_lastBars = 0;
bool   g_tblOk    = false;

//--- Dati sessioni per tabella ---
string g_sName[NUM_SESS];
int    g_sWinS[NUM_SESS], g_sWinE[NUM_SESS];
int    g_sDstS[NUM_SESS], g_sDstE[NUM_SESS];
int    g_sDstType[NUM_SESS];

//+------------------------------------------------------------------+
//| Inizializza dati sessioni                                        |
//+------------------------------------------------------------------+
void InitSessData()
{
   //             name        winS winE  dstS dstE  type
   // type: 0=none, 1=EU, 2=US, 3=AU
   g_sName[0]="Asia";      g_sWinS[0]=22; g_sWinE[0]=7;  g_sDstS[0]=21; g_sDstE[0]=6;  g_sDstType[0]=3;
   g_sName[1]="Sydney";    g_sWinS[1]=22; g_sWinE[1]=6;  g_sDstS[1]=21; g_sDstE[1]=5;  g_sDstType[1]=3;
   g_sName[2]="Tokyo";     g_sWinS[2]=23; g_sWinE[2]=7;  g_sDstS[2]=23; g_sDstE[2]=7;  g_sDstType[2]=0;
   g_sName[3]="Shanghai";  g_sWinS[3]=1;  g_sWinE[3]=9;  g_sDstS[3]=1;  g_sDstE[3]=9;  g_sDstType[3]=0;
   g_sName[4]="Europe";    g_sWinS[4]=7;  g_sWinE[4]=16; g_sDstS[4]=6;  g_sDstE[4]=15; g_sDstType[4]=1;
   g_sName[5]="London";    g_sWinS[5]=8;  g_sWinE[5]=16; g_sDstS[5]=7;  g_sDstE[5]=15; g_sDstType[5]=1;
   g_sName[6]="New York";  g_sWinS[6]=13; g_sWinE[6]=21; g_sDstS[6]=12; g_sDstE[6]=20; g_sDstType[6]=2;
}

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
   int k = y % 100, j = y / 100;
   int h = (q + (13*(m+1))/5 + k + k/4 + j/4 - 2*j) % 7;
   if(h < 0) h += 7;
   int db = (h == 1) ? 0 : (h == 0) ? 6 : h - 1;
   return lastDay - db;
}

//+------------------------------------------------------------------+
//| Primo giorno della settimana del 1 del mese (0=Dom)              |
//+------------------------------------------------------------------+
int DowOf1st(int year, int month)
{
   int m = month, y = year;
   if(m < 3) { m += 12; y--; }
   int k = y % 100, j = y / 100;
   int h = (1 + (13*(m+1))/5 + k + k/4 + j/4 - 2*j) % 7;
   if(h < 0) h += 7;
   return (h + 6) % 7;
}

int FirstSundayOfMonth(int year, int month)
{
   int dow = DowOf1st(year, month);
   return 1 + (7 - dow) % 7;
}

int SecondSundayOfMonth(int year, int month)
{
   return FirstSundayOfMonth(year, month) + 7;
}

//+------------------------------------------------------------------+
//| DST italiana (CET/CEST) - ultima dom. marzo/ottobre 01:00 UTC    |
//+------------------------------------------------------------------+
bool IsItalianDST(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);
   int yr = dt.year;
   int ms = LastSundayOfMonth(yr, 3);
   int os = LastSundayOfMonth(yr, 10);
   datetime s = StringToTime(StringFormat("%d.%02d.%02d 01:00", yr, 3, ms));
   datetime e = StringToTime(StringFormat("%d.%02d.%02d 01:00", yr, 10, os));
   return (gmtTime >= s && gmtTime < e);
}

//+------------------------------------------------------------------+
//| DST europea (uguale all'italiana)                                |
//+------------------------------------------------------------------+
bool IsEuDST(datetime gmtTime) { return IsItalianDST(gmtTime); }

//+------------------------------------------------------------------+
//| DST USA - 2a dom. marzo 07:00 UTC -> 1a dom. novembre 06:00 UTC |
//+------------------------------------------------------------------+
bool IsUsDST(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);
   int yr = dt.year;
   int ms2 = SecondSundayOfMonth(yr, 3);
   int ns1 = FirstSundayOfMonth(yr, 11);
   datetime s = StringToTime(StringFormat("%d.%02d.%02d 07:00", yr, 3, ms2));
   datetime e = StringToTime(StringFormat("%d.%02d.%02d 06:00", yr, 11, ns1));
   return (gmtTime >= s && gmtTime < e);
}

//+------------------------------------------------------------------+
//| DST Australia - 1a dom. ottobre -> 1a dom. aprile                |
//+------------------------------------------------------------------+
bool IsAuDST(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);
   int yr = dt.year, mo = dt.mon;

   if(mo >= 5 && mo <= 9) return false;
   if(mo >= 1 && mo <= 3) return true;
   if(mo >= 11) return true;

   if(mo == 4)
   {
      int d = FirstSundayOfMonth(yr, 4);
      datetime e = StringToTime(StringFormat("%d.%02d.%02d 16:00", yr, 4, d)) - 86400;
      return (gmtTime < e);
   }
   if(mo == 10)
   {
      int d = FirstSundayOfMonth(yr, 10);
      datetime s = StringToTime(StringFormat("%d.%02d.%02d 16:00", yr, 10, d)) - 86400;
      return (gmtTime >= s);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Verifica DST per tipo                                            |
//+------------------------------------------------------------------+
bool IsDstActive(int dstType, datetime gmtTime)
{
   if(dstType == 1) return IsEuDST(gmtTime);
   if(dstType == 2) return IsUsDST(gmtTime);
   if(dstType == 3) return IsAuDST(gmtTime);
   return false;
}

//+------------------------------------------------------------------+
//| Offset italiano (+1 CET / +2 CEST)                              |
//+------------------------------------------------------------------+
int GetItGmtOffset(datetime gmtTime)
{
   if(!AutoDST) return ManualGmtOffset;
   return IsItalianDST(gmtTime) ? 2 : 1;
}

//+------------------------------------------------------------------+
//| Ora italiana -> server time per un dato giorno                   |
//+------------------------------------------------------------------+
datetime ItHourToSrv(int itHour, datetime srvMidnight)
{
   datetime gmtMid = srvMidnight - g_srvDiff;
   int off = GetItGmtOffset(gmtMid);
   datetime tgt = gmtMid + (itHour - off) * 3600;
   int off2 = GetItGmtOffset(tgt);
   if(off2 != off)
      tgt = gmtMid + (itHour - off2) * 3600;
   return tgt + g_srvDiff;
}

//+------------------------------------------------------------------+
//| Trova high/low del prezzo in un intervallo                       |
//+------------------------------------------------------------------+
void GetPriceRange(datetime t1, datetime t2, double &hi, double &lo)
{
   hi = 0;
   lo = DBL_MAX;

   double hs[], ls[];
   int ch = CopyHigh(_Symbol, PERIOD_CURRENT, t1, t2, hs);
   int cl = CopyLow(_Symbol, PERIOD_CURRENT, t1, t2, ls);
   if(ch <= 0 || cl <= 0)
   {
      double fh[1], fl[1];
      if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, 1, fh) > 0) hi = fh[0];
      if(CopyLow(_Symbol, PERIOD_CURRENT, 0, 1, fl) > 0)  lo = fl[0];
      if(hi <= 0) hi = 1.0;
      if(lo <= 0 || lo >= DBL_MAX) lo = hi * 0.999;
      return;
   }
   int cnt = (int)MathMin(ch, cl);
   for(int i = 0; i < cnt; i++)
   {
      if(hs[i] > hi) hi = hs[i];
      if(ls[i] < lo) lo = ls[i];
   }
   if(hi <= 0 || lo >= DBL_MAX)
   {
      double fh2[1], fl2[1];
      if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, 1, fh2) > 0) hi = fh2[0];
      if(CopyLow(_Symbol, PERIOD_CURRENT, 0, 1, fl2) > 0)  lo = fl2[0];
      if(hi <= 0) hi = 1.0;
      if(lo <= 0 || lo >= DBL_MAX) lo = hi * 0.999;
   }
}

//+------------------------------------------------------------------+
//| Disegna un rettangolo + bordo + etichetta                        |
//+------------------------------------------------------------------+
void DrawRect(string tag, datetime t1, datetime t2,
              color fillClr, color borderClr, color lblClr, string lblText)
{
   double hi, lo;
   GetPriceRange(t1, t2, hi, lo);
   double rng = hi - lo;
   if(rng <= 0) rng = hi * 0.001;
   hi += rng * 0.02;
   lo -= rng * 0.02;

   // Rettangolo riempito (sfondo)
   string rf = PREFIX + "RF_" + tag;
   if(ObjectFind(0, rf) >= 0)
   {
      ObjectSetInteger(0, rf, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, rf, OBJPROP_PRICE, 0, hi);
      ObjectSetInteger(0, rf, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, rf, OBJPROP_PRICE, 1, lo);
   }
   else
   {
      ObjectCreate(0, rf, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
      ObjectSetInteger(0, rf, OBJPROP_COLOR, fillClr);
      ObjectSetInteger(0, rf, OBJPROP_FILL, true);
      ObjectSetInteger(0, rf, OBJPROP_BACK, true);
      ObjectSetInteger(0, rf, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, rf, OBJPROP_HIDDEN, true);
   }

   // Rettangolo bordo (davanti)
   string rb = PREFIX + "RB_" + tag;
   if(ObjectFind(0, rb) >= 0)
   {
      ObjectSetInteger(0, rb, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, rb, OBJPROP_PRICE, 0, hi);
      ObjectSetInteger(0, rb, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, rb, OBJPROP_PRICE, 1, lo);
   }
   else
   {
      ObjectCreate(0, rb, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
      ObjectSetInteger(0, rb, OBJPROP_COLOR, borderClr);
      ObjectSetInteger(0, rb, OBJPROP_FILL, false);
      ObjectSetInteger(0, rb, OBJPROP_BACK, true);
      ObjectSetInteger(0, rb, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, rb, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, rb, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, rb, OBJPROP_STYLE, STYLE_DOT);
   }

   // Etichetta
   string ln = PREFIX + "LB_" + tag;
   if(ObjectFind(0, ln) >= 0)
   {
      ObjectSetInteger(0, ln, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, ln, OBJPROP_PRICE, 0, hi);
   }
   else
   {
      ObjectCreate(0, ln, OBJ_TEXT, 0, t1, hi);
      ObjectSetString(0, ln, OBJPROP_TEXT, lblText);
      ObjectSetString(0, ln, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, ln, OBJPROP_FONTSIZE, LabelFontSize);
      ObjectSetInteger(0, ln, OBJPROP_COLOR, lblClr);
      ObjectSetInteger(0, ln, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, ln, OBJPROP_HIDDEN, true);
   }
}

//+------------------------------------------------------------------+
//| Disegna sessioni per un giorno (solo London e NY)                |
//+------------------------------------------------------------------+
void DrawDay(datetime srvMid, string sfx)
{
   datetime ldnO = ItHourToSrv(LondonOpenIT, srvMid);
   datetime ldnC = ItHourToSrv(LondonCloseIT, srvMid);
   DrawRect("LDN_" + sfx, ldnO, ldnC, ColorLondon, BorderLondon, LblColorLondon, "London");

   datetime nyO = ItHourToSrv(NewYorkOpenIT, srvMid);
   datetime nyC = ItHourToSrv(NewYorkCloseIT, srvMid);
   DrawRect("NY_" + sfx, nyO, nyC, ColorNewYork, BorderNewYork, LblColorNewYork, "New York");
}

//+------------------------------------------------------------------+
//| Linee verticali al cambio ora legale italiana                    |
//+------------------------------------------------------------------+
void DrawDSTLines()
{
   if(!ShowDSTLine || !g_diffOk) return;

   datetime gmt = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(gmt, dt);
   int yr = dt.year;

   for(int y = yr - 1; y <= yr; y++)
   {
      int ms = LastSundayOfMonth(y, 3);
      datetime gsS = StringToTime(StringFormat("%d.%02d.%02d 01:00", y, 3, ms));
      string nS = PREFIX + "DS_" + IntegerToString(y);
      if(ObjectFind(0, nS) < 0)
      {
         ObjectCreate(0, nS, OBJ_VLINE, 0, gsS + g_srvDiff, 0);
         ObjectSetInteger(0, nS, OBJPROP_COLOR, DSTLineColor);
         ObjectSetInteger(0, nS, OBJPROP_WIDTH, DSTLineWidth);
         ObjectSetInteger(0, nS, OBJPROP_STYLE, DSTLineStyle);
         ObjectSetInteger(0, nS, OBJPROP_BACK, false);
         ObjectSetInteger(0, nS, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nS, OBJPROP_HIDDEN, true);
         ObjectSetString(0, nS, OBJPROP_TOOLTIP, "Inizio CEST " + IntegerToString(y));
      }

      int os = LastSundayOfMonth(y, 10);
      datetime gsE = StringToTime(StringFormat("%d.%02d.%02d 01:00", y, 10, os));
      string nE = PREFIX + "DE_" + IntegerToString(y);
      if(ObjectFind(0, nE) < 0)
      {
         ObjectCreate(0, nE, OBJ_VLINE, 0, gsE + g_srvDiff, 0);
         ObjectSetInteger(0, nE, OBJPROP_COLOR, DSTLineColor);
         ObjectSetInteger(0, nE, OBJPROP_WIDTH, DSTLineWidth);
         ObjectSetInteger(0, nE, OBJPROP_STYLE, DSTLineStyle);
         ObjectSetInteger(0, nE, OBJPROP_BACK, false);
         ObjectSetInteger(0, nE, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nE, OBJPROP_HIDDEN, true);
         ObjectSetString(0, nE, OBJPROP_TOOLTIP, "Fine CEST " + IntegerToString(y));
      }
   }
}

//+------------------------------------------------------------------+
//| Disegna tutti i rettangoli                                       |
//+------------------------------------------------------------------+
void DrawAllRects()
{
   if(!g_diffOk) return;

   MqlDateTime ds;
   TimeToStruct(TimeCurrent(), ds);
   ds.hour = 0; ds.min = 0; ds.sec = 0;
   datetime today = StructToTime(ds);

   for(int d = -DaysToShow; d <= 0; d++)
   {
      datetime mid = today + d * 86400;
      MqlDateTime dd;
      TimeToStruct(mid, dd);
      if(dd.day_of_week == 0 || dd.day_of_week == 6) continue;
      DrawDay(mid, TimeToString(mid, TIME_DATE));
   }
   DrawDSTLines();
}

//+------------------------------------------------------------------+
//| Helper: crea pannello (OBJ_RECTANGLE_LABEL)                      |
//+------------------------------------------------------------------+
void MakePanel(string name, int x, int y, int w, int h, color bg)
{
   if(ObjectFind(0, name) >= 0)
   {
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
      ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, bg);
      return;
   }
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Helper: crea/aggiorna etichetta testo                            |
//+------------------------------------------------------------------+
void MakeLabel(string name, int x, int y, string text, color clr,
               int fsize=9, string font="Arial", ENUM_ANCHOR_POINT anch=ANCHOR_LEFT_UPPER)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, name, OBJPROP_FONT, font);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fsize);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, anch);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Crea la struttura della tabella                                  |
//+------------------------------------------------------------------+
void CreateTable()
{
   if(!ShowTable) return;

   color cTitle  = C'44,62,80';
   color cHdr    = C'52,73,94';
   color cRowE   = C'44,47,51';
   color cRowO   = C'55,58,62';
   color cTxt    = C'220,220,220';

   int y = TBL_MARGIN;

   // Titolo
   MakePanel(PREFIX+"TB", TBL_X, y, TBL_W, TBL_TITLE_H, cTitle);
   MakeLabel(PREFIX+"TT", TBL_X - TBL_W/2, y + 4, "FOREX Session", clrWhite, 11, "Arial Bold", ANCHOR_UPPER);
   y += TBL_TITLE_H;

   // Header
   MakePanel(PREFIX+"HB", TBL_X, y, TBL_W, TBL_HDR_H, cHdr);
   int hy = y + 3;
   MakeLabel(PREFIX+"H0", TBL_X - COL_S,  hy, "Session",         cTxt, 9, "Arial Bold");
   MakeLabel(PREFIX+"H1", TBL_X - COL_D,  hy, "Daylight Saving", cTxt, 9, "Arial Bold");
   MakeLabel(PREFIX+"H2", TBL_X - COL_T1, hy, "Start(UTC)",      cTxt, 9, "Arial Bold");
   MakeLabel(PREFIX+"H3", TBL_X - COL_T2, hy, "End(UTC)",        cTxt, 9, "Arial Bold");
   MakeLabel(PREFIX+"H4", TBL_X - COL_ST, hy, "Status",          cTxt, 9, "Arial Bold");
   y += TBL_HDR_H;

   // Righe dati
   for(int i = 0; i < NUM_SESS; i++)
   {
      color rBg = (i % 2 == 0) ? cRowE : cRowO;
      string si = IntegerToString(i);
      MakePanel(PREFIX+"RB_"+si, TBL_X, y, TBL_W, TBL_ROW_H, rBg);

      int ry = y + 3;
      MakeLabel(PREFIX+"RS_"+si, TBL_X - COL_S, ry, g_sName[i], clrWhite, 9);

      // Colonne dinamiche (placeholder)
      MakeLabel(PREFIX+"RD_"+si,  TBL_X - COL_D,  ry, "", cTxt, 9);
      MakeLabel(PREFIX+"RT1_"+si, TBL_X - COL_T1, ry, "", cTxt, 9);
      MakeLabel(PREFIX+"RT2_"+si, TBL_X - COL_T2, ry, "", cTxt, 9);

      // Status background + text
      int stW = TBL_W - COL_ST;
      MakePanel(PREFIX+"SB_"+si, TBL_X - COL_ST, ry - 2, stW, TBL_ROW_H - 4, C'178,34,34');
      MakeLabel(PREFIX+"SS_"+si, TBL_X - COL_ST - stW/2, ry, "Closed", clrWhite, 9, "Arial Bold", ANCHOR_UPPER);

      y += TBL_ROW_H;
   }

   g_tblOk = true;
}

//+------------------------------------------------------------------+
//| Aggiorna dati dinamici della tabella                             |
//+------------------------------------------------------------------+
void UpdateTable()
{
   if(!ShowTable || !g_tblOk) return;

   datetime gmt = TimeGMT();
   MqlDateTime dtG;
   TimeToStruct(gmt, dtG);
   int hUTC = dtG.hour;
   int dow = dtG.day_of_week;

   for(int i = 0; i < NUM_SESS; i++)
   {
      string si = IntegerToString(i);
      bool dstOn = IsDstActive(g_sDstType[i], gmt);
      int sH = dstOn ? g_sDstS[i] : g_sWinS[i];
      int eH = dstOn ? g_sDstE[i] : g_sWinE[i];

      // DST status
      string dTxt;
      color  dClr;
      if(g_sDstType[i] == 0)
      {
         dTxt = "Not Observed";
         dClr = C'128,128,128';
      }
      else if(dstOn)
      {
         dTxt = "Active";
         dClr = C'255,165,0';
      }
      else
      {
         dTxt = "Inactive";
         dClr = C'100,149,237';
      }

      // Orari
      string sStr = StringFormat("%02d:00", sH);
      string eStr = StringFormat("%02d:00", eH);

      // Open/Closed - forex reopens Sunday evening (~22:00 UTC)
      bool isOpen = false;
      if(dow >= 1 && dow <= 5)
      {
         if(sH < eH)
            isOpen = (hUTC >= sH && hUTC < eH);
         else
            isOpen = (hUTC >= sH || hUTC < eH);
      }
      else if(dow == 0 && sH >= 20)
      {
         isOpen = (hUTC >= sH);
      }
      else if(dow == 6 && sH > eH)
      {
         isOpen = (hUTC < eH);
      }

      color stBg  = isOpen ? C'46,139,87' : C'178,34,34';
      string stTx = isOpen ? "Open" : "Closed";

      MakeLabel(PREFIX+"RD_"+si,  0, 0, dTxt, dClr, 9);
      MakeLabel(PREFIX+"RT1_"+si, 0, 0, sStr, C'220,220,220', 9);
      MakeLabel(PREFIX+"RT2_"+si, 0, 0, eStr, C'220,220,220', 9);

      // Status bg
      ObjectSetInteger(0, PREFIX+"SB_"+si, OBJPROP_BGCOLOR, stBg);
      ObjectSetInteger(0, PREFIX+"SB_"+si, OBJPROP_BORDER_COLOR, stBg);
      MakeLabel(PREFIX+"SS_"+si, 0, 0, stTx, clrWhite, 9, "Arial Bold", ANCHOR_UPPER);
   }
}

//+------------------------------------------------------------------+
//| Pulizia oggetti                                                  |
//+------------------------------------------------------------------+
void Cleanup()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, PREFIX) == 0)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   InitSessData();
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Cleanup();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Timer - aggiorna tabella ogni secondo                            |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_diffOk)
   {
      datetime srv = TimeCurrent();
      datetime gmt = TimeGMT();
      if(srv > 0 && gmt > 0)
      {
         g_srvDiff = (int)(srv - gmt);
         g_diffOk = true;
      }
   }
   if(!g_diffOk) return;

   if(ShowTable)
   {
      if(!g_tblOk) CreateTable();
      UpdateTable();
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| OnCalculate - disegna rettangoli ad ogni tick / nuova barra      |
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
   g_srvDiff = (int)(TimeCurrent() - TimeGMT());
   if(!g_diffOk)
   {
      g_diffOk = true;
      if(ShowTable) { CreateTable(); UpdateTable(); }
      DrawAllRects();
      ChartRedraw(0);
      g_lastBars = rates_total;
      return(rates_total);
   }

   if(rates_total != g_lastBars)
   {
      DrawAllRects();
      ChartRedraw(0);
      g_lastBars = rates_total;
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
