//+------------------------------------------------------------------+
//|                                          SessionIndicator.mq5    |
//|   Indicatore sessioni di trading v4.0                            |
//|   Metti su UN grafico - gestisce TUTTI i grafici automaticamente |
//|   Rettangoli: London, New York                                   |
//|   Tabella FOREX Session in basso a SINISTRA                      |
//|   Linea verticale rosso fuoco al cambio ora legale italiana      |
//+------------------------------------------------------------------+
#property copyright   "SessionIndicator"
#property link        ""
#property version     "4.30"
#property indicator_chart_window
#property indicator_plots 0

//--- Rettangoli sessione (ora italiana) ---
input string   _sep1_              = "=== RETTANGOLI (ora italiana) ===";
input int      LondonOpenIT        = 10;                  // Londra apertura IT
input int      LondonCloseIT       = 18;                  // Londra chiusura IT
input int      NewYorkOpenIT       = 15;                  // New York apertura IT
input int      NewYorkCloseIT      = 23;                  // New York chiusura IT
input color    ColorLondon         = C'30,80,30';         // Riempimento Londra
input color    ColorNewYork        = C'55,30,80';         // Riempimento New York
input color    BorderLondon        = C'0,200,0';          // Bordo Londra
input color    BorderNewYork       = C'140,90,220';       // Bordo New York
input color    LblColorLondon      = clrLime;             // Etichetta Londra
input color    LblColorNewYork     = C'200,150,255';      // Etichetta New York
input int      LabelFontSize       = 9;                   // Font etichette

//--- Linea cambio ora legale ---
input string   _sep2_              = "=== LINEA ORA LEGALE ===";
input bool     ShowDSTLine         = true;                // Mostra linea DST
input color    DSTLineColor        = C'255,30,0';         // Rosso fuoco
input int      DSTLineWidth        = 2;                   // Spessore
input ENUM_LINE_STYLE DSTLineStyle = STYLE_DASH;          // Tratteggiata

//--- Tabella ---
input string   _sep3_              = "=== TABELLA SESSIONI ===";
input bool     ShowTable           = true;                // Mostra tabella

//--- Generale ---
input string   _sep4_              = "=== GENERALE ===";
input int      DaysToShow          = 365;                 // Giorni rettangoli
input bool     AutoDST             = true;                // DST automatica
input int      ManualGmtOffset     = 1;                   // Offset manuale
input string   AllowedSymbols      = "EURUSD,USDJPY,GBPJPY,GBPNZD,GBPCAD,GBPAUD,EURJPY,EURAUD,CADJPY,AUDUSD,AUDJPY";

//--- Costanti ---
#define NUM_SESS     3
#define PREFIX       "SI_"

// Layout tabella (CORNER_LEFT_UPPER, posizionata in basso via calcolo altezza chart)
#define TBL_MARGIN   8
#define TBL_W        350
#define TBL_TITLE_H  20
#define TBL_HDR_H    17
#define TBL_ROW_H    17
#define COL_SESS     6
#define COL_DST      72
#define COL_START    150
#define COL_END      218
#define COL_STATUS   278
#define COL_STATUS_W 64

//--- Variabili globali ---
int    g_srvDiff    = 0;
bool   g_diffOk     = false;

//--- Dati sessioni per tabella ---
string g_sName[NUM_SESS];
int    g_sWinS[NUM_SESS];
int    g_sWinE[NUM_SESS];
int    g_sDstS[NUM_SESS];
int    g_sDstE[NUM_SESS];
int    g_sDstType[NUM_SESS];

//+------------------------------------------------------------------+
//| Inizializza dati sessioni                                        |
//+------------------------------------------------------------------+
void InitSessData()
{
   g_sName[0]="Asia";      g_sWinS[0]=22; g_sWinE[0]=7;  g_sDstS[0]=21; g_sDstE[0]=6;  g_sDstType[0]=3;
   g_sName[1]="London";    g_sWinS[1]=8;  g_sWinE[1]=16; g_sDstS[1]=7;  g_sDstE[1]=15; g_sDstType[1]=1;
   g_sName[2]="New York";  g_sWinS[2]=13; g_sWinE[2]=21; g_sDstS[2]=12; g_sDstE[2]=20; g_sDstType[2]=2;
}

//+------------------------------------------------------------------+
//| Controlla se un simbolo e' nella lista consentita                |
//+------------------------------------------------------------------+
bool IsSymbolInList(string sym)
{
   if(AllowedSymbols == "") return true;
   string parts[];
   int n = StringSplit(AllowedSymbols, ',', parts);
   for(int i = 0; i < n; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(StringFind(sym, parts[i]) >= 0) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calcolo DST                                                      |
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

bool IsEuDST(datetime gmtTime) { return IsItalianDST(gmtTime); }

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

bool IsDstActive(int dstType, datetime gmtTime)
{
   if(dstType == 1) return IsEuDST(gmtTime);
   if(dstType == 2) return IsUsDST(gmtTime);
   if(dstType == 3) return IsAuDST(gmtTime);
   return false;
}

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
//| Trova high/low del prezzo per un simbolo/tf in un intervallo     |
//+------------------------------------------------------------------+
void GetPriceRange(string sym, ENUM_TIMEFRAMES tf,
                   datetime t1, datetime t2, double &hi, double &lo)
{
   hi = 0;
   lo = DBL_MAX;
   if(t1 > t2)
   {
      datetime tmp = t1;
      t1 = t2;
      t2 = tmp;
   }
   double hs[], ls[];
   int ch = CopyHigh(sym, tf, t1, t2, hs);
   int cl = CopyLow(sym, tf, t1, t2, ls);
   if(ch > 0 && cl > 0)
   {
      int cnt = (int)MathMin(ch, cl);
      for(int i = 0; i < cnt; i++)
      {
         if(hs[i] > hi) hi = hs[i];
         if(ls[i] < lo) lo = ls[i];
      }
   }
   if(hi <= 0 || lo >= DBL_MAX || lo <= 0)
   {
      double fb[1];
      if(CopyHigh(sym, tf, 0, 1, fb) > 0) hi = fb[0];
      else hi = 1.0;
      double fl[1];
      if(CopyLow(sym, tf, 0, 1, fl) > 0) lo = fl[0];
      else lo = hi * 0.999;
   }
}

//+------------------------------------------------------------------+
//| Disegna un rettangolo + bordo + etichetta su un grafico          |
//+------------------------------------------------------------------+
void DrawRect(long cid, string sym, ENUM_TIMEFRAMES tf,
              string tag, datetime t1, datetime t2,
              color fillClr, color borderClr, color lblClr, string lblText)
{
   if(t1 >= t2) return;
   double hi, lo;
   GetPriceRange(sym, tf, t1, t2, hi, lo);
   double rng = hi - lo;
   if(rng <= 0) rng = hi * 0.002;
   hi += rng * 0.03;
   lo -= rng * 0.03;

   string rf = PREFIX + "F_" + tag;
   if(ObjectFind(cid, rf) < 0)
   {
      ObjectCreate(cid, rf, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
      ObjectSetInteger(cid, rf, OBJPROP_COLOR, fillClr);
      ObjectSetInteger(cid, rf, OBJPROP_FILL, true);
      ObjectSetInteger(cid, rf, OBJPROP_BACK, true);
      ObjectSetInteger(cid, rf, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(cid, rf, OBJPROP_HIDDEN, true);
   }
   else
   {
      ObjectSetInteger(cid, rf, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(cid, rf, OBJPROP_PRICE, 0, hi);
      ObjectSetInteger(cid, rf, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(cid, rf, OBJPROP_PRICE, 1, lo);
   }

   string rb = PREFIX + "B_" + tag;
   if(ObjectFind(cid, rb) < 0)
   {
      ObjectCreate(cid, rb, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
      ObjectSetInteger(cid, rb, OBJPROP_COLOR, borderClr);
      ObjectSetInteger(cid, rb, OBJPROP_FILL, false);
      ObjectSetInteger(cid, rb, OBJPROP_BACK, false);
      ObjectSetInteger(cid, rb, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(cid, rb, OBJPROP_HIDDEN, true);
      ObjectSetInteger(cid, rb, OBJPROP_WIDTH, 2);
   }
   else
   {
      ObjectSetInteger(cid, rb, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(cid, rb, OBJPROP_PRICE, 0, hi);
      ObjectSetInteger(cid, rb, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(cid, rb, OBJPROP_PRICE, 1, lo);
   }

   string ln = PREFIX + "L_" + tag;
   if(ObjectFind(cid, ln) < 0)
   {
      ObjectCreate(cid, ln, OBJ_TEXT, 0, t1, hi);
      ObjectSetString(cid, ln, OBJPROP_TEXT, " " + lblText);
      ObjectSetString(cid, ln, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(cid, ln, OBJPROP_FONTSIZE, LabelFontSize);
      ObjectSetInteger(cid, ln, OBJPROP_COLOR, lblClr);
      ObjectSetInteger(cid, ln, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(cid, ln, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(cid, ln, OBJPROP_HIDDEN, true);
   }
   else
   {
      ObjectSetInteger(cid, ln, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(cid, ln, OBJPROP_PRICE, 0, hi);
   }
}

//+------------------------------------------------------------------+
//| Disegna sessioni per un giorno su un grafico                     |
//+------------------------------------------------------------------+
void DrawDay(long cid, string sym, ENUM_TIMEFRAMES tf,
             datetime srvMid, string sfx)
{
   datetime ldnO = ItHourToSrv(LondonOpenIT, srvMid);
   datetime ldnC = ItHourToSrv(LondonCloseIT, srvMid);
   if(ldnO < ldnC)
      DrawRect(cid, sym, tf, "LDN_" + sfx, ldnO, ldnC,
               ColorLondon, BorderLondon, LblColorLondon, "London");

   datetime nyO = ItHourToSrv(NewYorkOpenIT, srvMid);
   datetime nyC = ItHourToSrv(NewYorkCloseIT, srvMid);
   if(nyO < nyC)
      DrawRect(cid, sym, tf, "NY_" + sfx, nyO, nyC,
               ColorNewYork, BorderNewYork, LblColorNewYork, "New York");
}

//+------------------------------------------------------------------+
//| Linee verticali al cambio ora legale italiana su un grafico      |
//+------------------------------------------------------------------+
void DrawDSTLines(long cid)
{
   if(!ShowDSTLine || !g_diffOk) return;
   datetime gmt = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(gmt, dt);
   int yr = dt.year;

   for(int y = yr - 1; y <= yr + 1; y++)
   {
      int ms = LastSundayOfMonth(y, 3);
      datetime gsS = StringToTime(StringFormat("%d.%02d.%02d 01:00", y, 3, ms));
      string nS = PREFIX + "DS_" + IntegerToString(y);
      if(ObjectFind(cid, nS) < 0)
      {
         ObjectCreate(cid, nS, OBJ_VLINE, 0, gsS + g_srvDiff, 0);
         ObjectSetInteger(cid, nS, OBJPROP_COLOR, DSTLineColor);
         ObjectSetInteger(cid, nS, OBJPROP_WIDTH, DSTLineWidth);
         ObjectSetInteger(cid, nS, OBJPROP_STYLE, DSTLineStyle);
         ObjectSetInteger(cid, nS, OBJPROP_BACK, false);
         ObjectSetInteger(cid, nS, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(cid, nS, OBJPROP_HIDDEN, false);
         ObjectSetString(cid, nS, OBJPROP_TOOLTIP, "Inizio CEST " + IntegerToString(y));
      }

      int os = LastSundayOfMonth(y, 10);
      datetime gsE = StringToTime(StringFormat("%d.%02d.%02d 01:00", y, 10, os));
      string nE = PREFIX + "DE_" + IntegerToString(y);
      if(ObjectFind(cid, nE) < 0)
      {
         ObjectCreate(cid, nE, OBJ_VLINE, 0, gsE + g_srvDiff, 0);
         ObjectSetInteger(cid, nE, OBJPROP_COLOR, DSTLineColor);
         ObjectSetInteger(cid, nE, OBJPROP_WIDTH, DSTLineWidth);
         ObjectSetInteger(cid, nE, OBJPROP_STYLE, DSTLineStyle);
         ObjectSetInteger(cid, nE, OBJPROP_BACK, false);
         ObjectSetInteger(cid, nE, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(cid, nE, OBJPROP_HIDDEN, false);
         ObjectSetString(cid, nE, OBJPROP_TOOLTIP, "Fine CEST " + IntegerToString(y));
      }
   }
}

//+------------------------------------------------------------------+
//| Disegna tutti i rettangoli su un grafico                         |
//+------------------------------------------------------------------+
void DrawAllRects(long cid, string sym, ENUM_TIMEFRAMES tf)
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
      DrawDay(cid, sym, tf, mid, TimeToString(mid, TIME_DATE));
   }
   DrawDSTLines(cid);

   // Sentinel: segna che i rettangoli sono stati disegnati
   string sentinel = PREFIX + "DRAWN";
   if(ObjectFind(cid, sentinel) < 0)
   {
      ObjectCreate(cid, sentinel, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(cid, sentinel, OBJPROP_XDISTANCE, -100);
      ObjectSetInteger(cid, sentinel, OBJPROP_YDISTANCE, -100);
      ObjectSetInteger(cid, sentinel, OBJPROP_HIDDEN, true);
      ObjectSetInteger(cid, sentinel, OBJPROP_SELECTABLE, false);
      ObjectSetString(cid, sentinel, OBJPROP_TEXT, "");
   }
}

//+------------------------------------------------------------------+
//| Helper: crea pannello su un grafico                              |
//+------------------------------------------------------------------+
void MakePanel(long cid, string name, int x, int y, int w, int h, color bg)
{
   if(ObjectFind(cid, name) < 0)
   {
      ObjectCreate(cid, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(cid, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(cid, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(cid, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(cid, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(cid, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(cid, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(cid, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(cid, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(cid, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(cid, name, OBJPROP_BORDER_COLOR, bg);
}

//+------------------------------------------------------------------+
//| Helper: crea/aggiorna etichetta su un grafico                    |
//+------------------------------------------------------------------+
void MakeLabel(long cid, string name, int x, int y, string text, color clr,
               int fsize=8, string font="Arial", ENUM_ANCHOR_POINT anch=ANCHOR_LEFT_UPPER)
{
   if(ObjectFind(cid, name) < 0)
   {
      ObjectCreate(cid, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(cid, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(cid, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(cid, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(cid, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(cid, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(cid, name, OBJPROP_FONT, font);
   ObjectSetInteger(cid, name, OBJPROP_FONTSIZE, fsize);
   ObjectSetInteger(cid, name, OBJPROP_ANCHOR, anch);
   ObjectSetString(cid, name, OBJPROP_TEXT, text);
   ObjectSetInteger(cid, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Crea la struttura della tabella su un grafico                    |
//+------------------------------------------------------------------+
void CreateTable(long cid)
{
   if(!ShowTable) return;

   // Calcola altezza chart per posizionare tabella in basso
   int chartH = (int)ChartGetInteger(cid, CHART_HEIGHT_IN_PIXELS, 0);
   int totalH = TBL_TITLE_H + TBL_HDR_H + NUM_SESS * TBL_ROW_H;
   int startY = chartH - TBL_MARGIN - totalH;
   if(startY < TBL_MARGIN) startY = TBL_MARGIN;

   color cTitle  = C'44,62,80';
   color cHdr    = C'52,73,94';
   color cRowE   = C'44,47,51';
   color cRowO   = C'55,58,62';
   color cTxt    = C'200,200,200';

   int y = startY;

   // Titolo in alto
   MakePanel(cid, PREFIX+"TB", TBL_MARGIN, y, TBL_W, TBL_TITLE_H, cTitle);
   MakeLabel(cid, PREFIX+"TT", TBL_MARGIN + TBL_W/2, y + 3, "FOREX Session", clrWhite, 10, "Arial Bold", ANCHOR_UPPER);
   y += TBL_TITLE_H;

   // Header
   MakePanel(cid, PREFIX+"HB", TBL_MARGIN, y, TBL_W, TBL_HDR_H, cHdr);
   int hy = y + 2;
   MakeLabel(cid, PREFIX+"H0", TBL_MARGIN + COL_SESS,   hy, "Session",  cTxt, 8, "Arial Bold");
   MakeLabel(cid, PREFIX+"H1", TBL_MARGIN + COL_DST,    hy, "DST",      cTxt, 8, "Arial Bold");
   MakeLabel(cid, PREFIX+"H2", TBL_MARGIN + COL_START,  hy, "Start",    cTxt, 8, "Arial Bold");
   MakeLabel(cid, PREFIX+"H3", TBL_MARGIN + COL_END,    hy, "End",      cTxt, 8, "Arial Bold");
   MakeLabel(cid, PREFIX+"H4", TBL_MARGIN + COL_STATUS, hy, "Status",   cTxt, 8, "Arial Bold");
   y += TBL_HDR_H;

   // Righe sessioni (dall'alto in basso: Asia, London, New York)
   for(int r = 0; r < NUM_SESS; r++)
   {
      color rBg = (r % 2 == 0) ? cRowE : cRowO;
      string si = IntegerToString(r);
      MakePanel(cid, PREFIX+"RB_"+si, TBL_MARGIN, y, TBL_W, TBL_ROW_H, rBg);
      int ry = y + 2;
      MakeLabel(cid, PREFIX+"RS_"+si,  TBL_MARGIN + COL_SESS,  ry, g_sName[r], clrWhite, 8);
      MakeLabel(cid, PREFIX+"RD_"+si,  TBL_MARGIN + COL_DST,   ry, "", cTxt, 8);
      MakeLabel(cid, PREFIX+"RT1_"+si, TBL_MARGIN + COL_START, ry, "", cTxt, 8);
      MakeLabel(cid, PREFIX+"RT2_"+si, TBL_MARGIN + COL_END,   ry, "", cTxt, 8);

      MakePanel(cid, PREFIX+"SB_"+si, TBL_MARGIN + COL_STATUS, y + 2, COL_STATUS_W, TBL_ROW_H - 4, C'178,34,34');
      MakeLabel(cid, PREFIX+"SS_"+si, TBL_MARGIN + COL_STATUS + COL_STATUS_W/2, ry, "Closed", clrWhite, 8, "Arial Bold", ANCHOR_UPPER);
      y += TBL_ROW_H;
   }
}

//+------------------------------------------------------------------+
//| Aggiorna dati dinamici della tabella su un grafico               |
//+------------------------------------------------------------------+
void UpdateTable(long cid)
{
   if(!ShowTable) return;

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

      string dTxt;
      color  dClr;
      if(g_sDstType[i] == 0)
      { dTxt = "No"; dClr = C'128,128,128'; }
      else if(dstOn)
      { dTxt = "ON"; dClr = C'255,165,0'; }
      else
      { dTxt = "OFF"; dClr = C'100,149,237'; }

      string sStr = StringFormat("%02d:00", sH);
      string eStr = StringFormat("%02d:00", eH);

      // Open/Closed - forex market: Sun ~22:00 UTC -> Fri ~22:00 UTC
      bool isOpen = false;
      if(dow >= 1 && dow <= 4)
      {
         if(sH < eH)
            isOpen = (hUTC >= sH && hUTC < eH);
         else
            isOpen = (hUTC >= sH || hUTC < eH);
      }
      else if(dow == 5)
      {
         if(sH < eH)
            isOpen = (hUTC >= sH && hUTC < eH);
         else
            isOpen = (hUTC < eH);
      }
      else if(dow == 0 && sH >= 20)
         isOpen = (hUTC >= sH);

      color stBg  = isOpen ? C'46,139,87' : C'178,34,34';
      string stTx = isOpen ? "Open" : "Closed";

      ObjectSetString(cid, PREFIX+"RD_"+si,  OBJPROP_TEXT, dTxt);
      ObjectSetInteger(cid, PREFIX+"RD_"+si,  OBJPROP_COLOR, dClr);
      ObjectSetString(cid, PREFIX+"RT1_"+si, OBJPROP_TEXT, sStr);
      ObjectSetInteger(cid, PREFIX+"RT1_"+si, OBJPROP_COLOR, C'200,200,200');
      ObjectSetString(cid, PREFIX+"RT2_"+si, OBJPROP_TEXT, eStr);
      ObjectSetInteger(cid, PREFIX+"RT2_"+si, OBJPROP_COLOR, C'200,200,200');

      ObjectSetInteger(cid, PREFIX+"SB_"+si, OBJPROP_BGCOLOR, stBg);
      ObjectSetInteger(cid, PREFIX+"SB_"+si, OBJPROP_BORDER_COLOR, stBg);
      ObjectSetString(cid, PREFIX+"SS_"+si, OBJPROP_TEXT, stTx);
      ObjectSetInteger(cid, PREFIX+"SS_"+si, OBJPROP_COLOR, clrWhite);
   }
}

//+------------------------------------------------------------------+
//| Pulizia oggetti da un grafico                                    |
//+------------------------------------------------------------------+
void CleanupChart(long cid)
{
   int total = ObjectsTotal(cid);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(cid, i);
      if(StringFind(name, PREFIX) == 0)
         ObjectDelete(cid, name);
   }
}

//+------------------------------------------------------------------+
//| Pulizia solo rettangoli/DST da un grafico (lascia tabella)       |
//+------------------------------------------------------------------+
void CleanupRects(long cid)
{
   int total = ObjectsTotal(cid);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(cid, i);
      if(StringFind(name, PREFIX + "F_") == 0 ||
         StringFind(name, PREFIX + "B_") == 0 ||
         StringFind(name, PREFIX + "L_") == 0 ||
         StringFind(name, PREFIX + "DS_") == 0 ||
         StringFind(name, PREFIX + "DE_") == 0 ||
         name == PREFIX + "DRAWN")
         ObjectDelete(cid, name);
   }
}

//+------------------------------------------------------------------+
//| Processa un singolo grafico                                      |
//+------------------------------------------------------------------+
void ProcessChart(long cid, string sym, ENUM_TIMEFRAMES tf, bool forceRects)
{
   bool rectsExist = (ObjectFind(cid, PREFIX + "DRAWN") >= 0);
   bool showRects = (tf < PERIOD_H4);

   if(showRects)
   {
      if(!rectsExist || forceRects)
         DrawAllRects(cid, sym, tf);
   }
   else if(rectsExist)
   {
      CleanupRects(cid);
   }

   if(ShowTable)
   {
      CreateTable(cid);
      UpdateTable(cid);
   }

   ChartRedraw(cid);
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
//| OnDeinit - pulisci TUTTI i grafici                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   long cid = ChartFirst();
   while(cid >= 0)
   {
      CleanupChart(cid);
      ChartRedraw(cid);
      cid = ChartNext(cid);
   }
}

//+------------------------------------------------------------------+
//| Timer - gestisce tutti i grafici                                 |
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

   static int tickCount = 0;
   tickCount++;
   bool forceRects = (tickCount % 60 == 1);

   long cid = ChartFirst();
   while(cid >= 0)
   {
      string sym = ChartSymbol(cid);
      if(IsSymbolInList(sym))
         ProcessChart(cid, sym, ChartPeriod(cid), forceRects);
      cid = ChartNext(cid);
   }
}

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
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
   if(!g_diffOk)
   {
      g_srvDiff = (int)(TimeCurrent() - TimeGMT());
      g_diffOk = true;
   }
   return(rates_total);
}
//+------------------------------------------------------------------+
