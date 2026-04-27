//+------------------------------------------------------------------+
//|                                                   ScalpPro.mq5   |
//|                        Scalping Execution Panel - Professional    |
//|                        MetaTrader 5 Expert Advisor                |
//+------------------------------------------------------------------+
#property copyright   "ScalpPro"
#property link        ""
#property version     "1.00"
#property strict
#property description "Professional scalping EA: rapid execution, auto break-even, trailing stop."
#property description "Dark minimal panel. Config-file based BE system preserved."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "--- Execution ---"
input double InpDefaultSlPips     = 60.0;       // SL (pips)
input double InpDefaultRiskEur    = 110.0;      // Risk (EUR)
input double InpLockInPips        = 0.0;        // Lock-in on BE (pips above entry)
input string InpMainSymbols       = "EURUSD,USDJPY,GBPJPY,GBPNZD,GBPCAD,GBPAUD,EURJPY,EURAUD,CADJPY,AUDUSD,AUDJPY";

input group "--- Break-Even & Trailing ---"
input int    InpBEAfterMinutes    = 5;          // Auto BE after X minutes
input double InpTrailingPips      = 10.0;       // Trailing step (pips) after BE
input string InpConfigFile        = "be_config.txt"; // Config file for manual time-based BE

input group "--- Panel ---"
input int    InpPanelX            = 20;         // Panel X offset
input int    InpPanelY            = 20;         // Panel Y offset

input group "--- Advanced ---"
input double InpMaxSpreadPips     = 999.0;      // Max spread filter (pips)
input long   InpMagicFilter       = -1;         // Magic filter (-1 = all)
input bool   InpDebugLogs         = false;      // Debug log output

//+------------------------------------------------------------------+
//| CONSTANTS & DEFINES                                               |
//+------------------------------------------------------------------+
#define PREFIX   "SP_"
#define PNL_W    400
#define ROW_H    36
#define HDR_H    32
#define MAX_ORD  50

//+------------------------------------------------------------------+
//| COLOR PALETTE - Dark Institutional Theme                          |
//+------------------------------------------------------------------+
#define CLR_BG          C'16,16,24'
#define CLR_HDR         C'10,42,78'
#define CLR_ROW_ALT     C'20,20,30'
#define CLR_FIELD_BG    C'28,28,40'
#define CLR_BORDER      C'48,48,64'
#define CLR_TEXT         C'200,200,210'
#define CLR_TEXT_DIM     C'120,120,140'
#define CLR_ACCENT       C'40,120,200'
#define CLR_BUY          C'0,150,80'
#define CLR_BUY_HOVER    C'0,180,100'
#define CLR_SELL         C'180,35,35'
#define CLR_SELL_HOVER   C'210,50,50'
#define CLR_PRESET_ON    C'30,80,150'
#define CLR_PRESET_OFF   C'38,38,52'
#define CLR_LIVE_ON      C'0,130,80'
#define CLR_LIVE_OFF     C'48,48,64'
#define CLR_LOTS         C'255,200,60'
#define CLR_BE_SECTION   C'22,22,34'

//+------------------------------------------------------------------+
//| GLOBAL STATE                                                      |
//+------------------------------------------------------------------+
CTrade g_trade;

// --- BE config file system ---
struct SBeConfig
{
   ulong  ticket;
   int    hour;
   int    minute;
   bool   applied;
   bool   stale;
   string note;
   string rawValue;
};
SBeConfig g_configs[];
int       g_configCount = 0;

// --- Trailing state per position ---
struct STrailState
{
   ulong  ticket;
   bool   beApplied;      // BE has been moved
   double highWaterMark;   // best price after BE for trailing
};
STrailState g_trails[];
int         g_trailCount = 0;

// --- Runtime BE/Trailing settings (editable from panel) ---
int    g_beAfterMinutes   = 5;
double g_trailingPips     = 10.0;

// --- Panel state ---
bool   g_priceLive        = false;
string g_lastLivePriceTxt = "";
string g_lastQuickSymbol  = "";

// --- Symbol list ---
string g_mainSymbols[];
int    g_mainSymbolsCount = 0;
int    g_mainSymbolsIdx   = 0;

// --- Preset counts (fixed: 2, 3, 5, 10) ---
int    g_presetCounts[]   = {2, 3, 5, 10};
int    g_presetCount      = 4;
int    g_selectedPreset   = 1;   // index into g_presetCounts (default=3 orders)

//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                 |
//+------------------------------------------------------------------+
double GetPipSize(const string symbol)
{
   int    d = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double p = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return (d == 3 || d == 5) ? p * 10.0 : p;
}

double GetSpreadPips(const string symbol)
{
   double pip = GetPipSize(symbol);
   if(pip <= 0.0) return 999.0;
   return (SymbolInfoDouble(symbol, SYMBOL_ASK) -
           SymbolInfoDouble(symbol, SYMBOL_BID)) / pip;
}

bool IsTimeReached(int h, int m)
{
   MqlDateTime t;
   TimeToStruct(TimeLocal(), t);
   return (t.hour > h || (t.hour == h && t.min >= m));
}

bool GetSymbolPrices(const string symbol, double &bid, double &ask)
{
   MqlTick tick;
   if(!SymbolSelect(symbol, true))
      return false;
   if(SymbolInfoTick(symbol, tick) && tick.bid > 0.0 && tick.ask > 0.0)
   {
      bid = tick.bid;
      ask = tick.ask;
      return true;
   }
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(symbol, PERIOD_CURRENT, 0, 1, rates) > 0 &&
      SymbolInfoTick(symbol, tick) &&
      tick.bid > 0.0 && tick.ask > 0.0)
   {
      bid = tick.bid;
      ask = tick.ask;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| LOT CALCULATION                                                   |
//+------------------------------------------------------------------+
double CalcLots(const string symbol, double slPips, double riskEur)
{
   if(slPips <= 0.0 || riskEur <= 0.0) return 0.0;

   double tickVal  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double pipSize  = GetPipSize(symbol);

   if(tickVal <= 0.0 || tickSize <= 0.0 || pipSize <= 0.0) return 0.0;

   double pipValPerLot = tickVal * (pipSize / tickSize);
   if(pipValPerLot <= 0.0) return 0.0;

   double lots    = riskEur / (slPips * pipValPerLot);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double lotMax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

   if(lotStep <= 0.0) lotStep = 0.01;
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lotMin, MathMin(lotMax, lots));

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| CONFIG FILE MANAGEMENT (preserved from original)                  |
//+------------------------------------------------------------------+
bool TicketExistsInConfig(ulong ticket)
{
   for(int i = 0; i < g_configCount; i++)
      if(g_configs[i].ticket == ticket) return true;
   return false;
}

bool IsTicketInFile(ulong ticket)
{
   if(!FileIsExist(InpConfigFile)) return false;
   int f = FileOpen(InpConfigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(f == INVALID_HANDLE) return false;
   bool found = false;
   while(!FileIsEnding(f))
   {
      string line = FileReadString(f);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0 || StringGetCharacter(line, 0) == '#') continue;
      int sep = StringFind(line, "=");
      if(sep <= 0) continue;
      ulong lt = (ulong)StringToInteger(StringSubstr(line, 0, sep));
      if(lt == ticket) { found = true; break; }
   }
   FileClose(f);
   return found;
}

void AppendTicketToConfig(ulong ticket, const string defaultValue)
{
   if(ticket == 0) return;
   if(TicketExistsInConfig(ticket) || IsTicketInFile(ticket))
   {
      if(InpDebugLogs)
         PrintFormat("[CFG] Ticket #%I64u already present, skip.", ticket);
      return;
   }

   bool exists = FileIsExist(InpConfigFile);
   int flags   = FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   int mode    = exists ? (FILE_READ|FILE_WRITE) : FILE_WRITE;
   int file    = FileOpen(InpConfigFile, mode|flags);

   if(file == INVALID_HANDLE)
   {
      PrintFormat("[CFG] Error opening %s (err=%d)", InpConfigFile, GetLastError());
      return;
   }

   if(exists) FileSeek(file, 0, SEEK_END);
   string line = StringFormat("%I64u=%s", ticket, defaultValue);
   if(exists) FileWriteString(file, "\r\n" + line);
   else       FileWriteString(file, line + "\r\n");
   FileClose(file);

   if(InpDebugLogs)
      PrintFormat("[CFG] Added #%I64u='%s' to %s", ticket, defaultValue, InpConfigFile);

   ArrayResize(g_configs, g_configCount + 1);
   g_configs[g_configCount].ticket   = ticket;
   g_configs[g_configCount].applied  = false;
   g_configs[g_configCount].stale    = false;
   g_configs[g_configCount].note     = "";
   g_configs[g_configCount].rawValue = defaultValue;
   g_configs[g_configCount].hour     = -1;
   g_configs[g_configCount].minute   = -1;
   g_configCount++;
}

void RemoveTicketFromConfig(ulong ticket)
{
   if(ticket == 0) return;

   int idx = -1;
   for(int i = 0; i < g_configCount; i++)
      if(g_configs[i].ticket == ticket) { idx = i; break; }
   if(idx >= 0)
   {
      for(int i = idx; i < g_configCount - 1; i++)
         g_configs[i] = g_configs[i + 1];
      g_configCount--;
      if(g_configCount >= 0) ArrayResize(g_configs, g_configCount);
   }

   if(!FileIsExist(InpConfigFile)) return;

   int rf = FileOpen(InpConfigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(rf == INVALID_HANDLE) return;

   string lines[];
   int n = 0;
   bool removed = false;
   while(!FileIsEnding(rf))
   {
      string raw = FileReadString(rf);
      string trimmed = raw;
      StringTrimLeft(trimmed);
      StringTrimRight(trimmed);
      bool skip = false;
      if(StringLen(trimmed) > 0 && StringGetCharacter(trimmed, 0) != '#')
      {
         int sep = StringFind(trimmed, "=");
         if(sep > 0)
         {
            ulong lt = (ulong)StringToInteger(StringSubstr(trimmed, 0, sep));
            if(lt == ticket) { skip = true; removed = true; }
         }
      }
      if(!skip) { ArrayResize(lines, n + 1); lines[n++] = raw; }
   }
   FileClose(rf);

   if(!removed) return;

   int wf = FileOpen(InpConfigFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(wf == INVALID_HANDLE) return;
   for(int i = 0; i < n; i++)
   {
      if(i < n - 1) FileWriteString(wf, lines[i] + "\r\n");
      else          FileWriteString(wf, lines[i]);
   }
   FileClose(wf);

   if(InpDebugLogs)
      PrintFormat("[CFG] Removed #%I64u from %s", ticket, InpConfigFile);
}

void ReconcileConfigFile()
{
   if(!FileIsExist(InpConfigFile)) return;

   ulong alive[];
   int na = 0;
   int pt = PositionsTotal();
   for(int i = 0; i < pt; i++)
   {
      ulong t = PositionGetTicket(i);
      if(t != 0) { ArrayResize(alive, na + 1); alive[na++] = t; }
   }

   int rf = FileOpen(InpConfigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(rf == INVALID_HANDLE) return;

   string lines[];
   int ln = 0;
   bool changed = false;
   while(!FileIsEnding(rf))
   {
      string raw = FileReadString(rf);
      string trimmed = raw;
      StringTrimLeft(trimmed);
      StringTrimRight(trimmed);
      bool keep = true;
      if(StringLen(trimmed) > 0 && StringGetCharacter(trimmed, 0) != '#')
      {
         int sep = StringFind(trimmed, "=");
         if(sep > 0)
         {
            ulong lt = (ulong)StringToInteger(StringSubstr(trimmed, 0, sep));
            if(lt != 0)
            {
               bool isAlive = false;
               for(int k = 0; k < na; k++)
                  if(alive[k] == lt) { isAlive = true; break; }
               if(!isAlive) { keep = false; changed = true; }
            }
         }
      }
      if(keep) { ArrayResize(lines, ln + 1); lines[ln++] = raw; }
   }
   FileClose(rf);

   if(!changed) return;

   int wf = FileOpen(InpConfigFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(wf == INVALID_HANDLE) return;
   for(int i = 0; i < ln; i++)
   {
      if(i < ln - 1) FileWriteString(wf, lines[i] + "\r\n");
      else           FileWriteString(wf, lines[i]);
   }
   FileClose(wf);

   for(int i = g_configCount - 1; i >= 0; i--)
   {
      bool isAlive = false;
      for(int k = 0; k < na; k++)
         if(alive[k] == g_configs[i].ticket) { isAlive = true; break; }
      if(!isAlive)
      {
         for(int j = i; j < g_configCount - 1; j++)
            g_configs[j] = g_configs[j + 1];
         g_configCount--;
         if(g_configCount >= 0) ArrayResize(g_configs, g_configCount);
      }
   }

   if(InpDebugLogs)
      Print("[CFG] Reconcile: removed closed tickets");
}

void LoadConfig()
{
   int file = FileOpen(InpConfigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(file == INVALID_HANDLE) return;

   for(int i = 0; i < g_configCount; i++)
      if(!g_configs[i].applied)
      {
         g_configs[i].hour   = -1;
         g_configs[i].minute = -1;
         g_configs[i].note   = "";
      }

   while(!FileIsEnding(file))
   {
      string line = FileReadString(file);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0 || StringGetCharacter(line, 0) == '#') continue;

      int sep = StringFind(line, "=");
      if(sep < 0) continue;

      ulong  ticket = (ulong)StringToInteger(StringSubstr(line, 0, sep));
      string val    = StringSubstr(line, sep + 1);
      StringTrimLeft(val);
      StringTrimRight(val);

      if(ticket == 0) continue;

      int idx = -1;
      for(int i = 0; i < g_configCount; i++)
         if(g_configs[i].ticket == ticket) { idx = i; break; }

      if(idx < 0)
      {
         ArrayResize(g_configs, g_configCount + 1);
         g_configs[g_configCount].ticket   = ticket;
         g_configs[g_configCount].applied  = false;
         g_configs[g_configCount].stale    = false;
         g_configs[g_configCount].note     = "";
         g_configs[g_configCount].rawValue = "";
         idx = g_configCount++;
      }

      string rawConfigValue = val;
      if(g_configs[idx].rawValue != "" && g_configs[idx].rawValue != rawConfigValue)
      {
         g_configs[idx].applied = false;
         g_configs[idx].stale   = false;
         if(InpDebugLogs)
            PrintFormat("[BE] #%I64u: config changed ('%s' -> '%s'), re-arm.",
                        ticket, g_configs[idx].rawValue, rawConfigValue);
      }
      g_configs[idx].rawValue = rawConfigValue;

      string note = "";
      int noteSep = StringFind(val, "|");
      if(noteSep >= 0)
      {
         note = StringSubstr(val, noteSep + 1);
         val  = StringSubstr(val, 0, noteSep);
         StringTrimLeft(note);
         StringTrimRight(note);
      }
      g_configs[idx].note = note;

      if(val == "NO" || val == "no")
      {
         g_configs[idx].hour   = -1;
         g_configs[idx].minute = -1;
         continue;
      }

      if(StringLen(val) >= 5 && StringSubstr(val, 2, 1) == ":")
      {
         int h = (int)StringToInteger(StringSubstr(val, 0, 2));
         int m = (int)StringToInteger(StringSubstr(val, 3, 2));
         if(h >= 0 && h <= 23 && m >= 0 && m <= 59 && !g_configs[idx].applied)
         {
            g_configs[idx].hour   = h;
            g_configs[idx].minute = m;
         }
      }
   }
   FileClose(file);

   if(InpDebugLogs)
      PrintFormat("[BE] Config loaded: %d tickets", g_configCount);
}

//+------------------------------------------------------------------+
//| BREAK-EVEN APPLICATION (config file based)                        |
//+------------------------------------------------------------------+
bool ApplyBreakEven(ulong ticket, const string symbol,
                    ENUM_POSITION_TYPE ptype,
                    double openP, double curSL, double curTP,
                    double bid, double ask, int digits, double pipSize,
                    int beH, int beM, const string note)
{
   double newSL = NormalizeDouble(
      ptype == POSITION_TYPE_BUY ? openP + InpLockInPips * pipSize
                                 : openP - InpLockInPips * pipSize, digits);

   if(ptype == POSITION_TYPE_BUY  && curSL >= newSL) return false;
   if(ptype == POSITION_TYPE_SELL && curSL <= newSL && curSL > 0.0) return false;

   double minDist = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                    SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(ptype == POSITION_TYPE_BUY && newSL >= bid - minDist)
   {
      if(InpDebugLogs)
         PrintFormat("[BE] #%I64u: SL rejected (stops level). bid=%.5f newSL=%.5f",
                     ticket, bid, newSL);
      return false;
   }
   if(ptype == POSITION_TYPE_SELL && newSL <= ask + minDist)
   {
      if(InpDebugLogs)
         PrintFormat("[BE] #%I64u: SL rejected (stops level). ask=%.5f newSL=%.5f",
                     ticket, ask, newSL);
      return false;
   }

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = symbol;
   req.sl       = newSL;
   req.tp       = NormalizeDouble(curTP, digits);

   bool ok = OrderSend(req, res);
   if(ok && res.retcode == TRADE_RETCODE_DONE)
      PrintFormat("[BE] #%I64u (%s): SL -> %.5f at %02d:%02d%s",
                  ticket, symbol, newSL, beH, beM,
                  StringLen(note) > 0 ? " | " + note : "");
   else
      PrintFormat("[BE] #%I64u FAILED retcode=%d", ticket, res.retcode);

   return ok && res.retcode == TRADE_RETCODE_DONE;
}

//+------------------------------------------------------------------+
//| PROCESS CONFIG-FILE BASED BREAK-EVEN                              |
//+------------------------------------------------------------------+
void ProcessConfigBreakEven()
{
   int total = PositionsTotal();
   if(total == 0) return;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;

      string sym   = PositionGetString(POSITION_SYMBOL);
      long   magic = PositionGetInteger(POSITION_MAGIC);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      if(InpMagicFilter >= 0 && magic != InpMagicFilter) continue;

      int    digits  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double pipSize = GetPipSize(sym);
      if(pipSize <= 0.0) continue;

      double bid = 0.0, ask = 0.0;
      if(!GetSymbolPrices(sym, bid, ask)) continue;
      if(((ask - bid) / pipSize) > InpMaxSpreadPips) continue;

      int cfgIdx = -1;
      for(int c = 0; c < g_configCount; c++)
         if(g_configs[c].ticket == ticket) { cfgIdx = c; break; }
      if(cfgIdx < 0) continue;
      if(g_configs[cfgIdx].applied) continue;
      if(g_configs[cfgIdx].stale) continue;
      if(g_configs[cfgIdx].hour < 0) continue;

      if(!IsTimeReached(g_configs[cfgIdx].hour, g_configs[cfgIdx].minute))
         continue;

      double targetSL = NormalizeDouble(
         ptype == POSITION_TYPE_BUY ? openP + InpLockInPips * pipSize
                                    : openP - InpLockInPips * pipSize, digits);
      bool beAlready = (ptype == POSITION_TYPE_BUY) ? (curSL >= targetSL)
                                                    : (curSL > 0.0 && curSL <= targetSL);
      if(beAlready) { g_configs[cfgIdx].applied = true; continue; }

      double profPips = (ptype == POSITION_TYPE_BUY) ? (bid - openP) / pipSize
                                                     : (openP - ask) / pipSize;
      double slDistPips = 0.0;
      if(curSL > 0.0)
         slDistPips = (ptype == POSITION_TYPE_BUY) ? (openP - curSL) / pipSize
                                                   : (curSL - openP) / pipSize;
      else
         slDistPips = InpDefaultSlPips;

      double stopsLvlPips = (SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) *
                             SymbolInfoDouble(sym, SYMBOL_POINT)) / pipSize;
      double minProfPips  = MathMax(slDistPips, stopsLvlPips + InpLockInPips + 1.0);

      if(profPips < minProfPips)
      {
         g_configs[cfgIdx].stale = true;
         PrintFormat("[BE] #%I64u at %02d:%02d: profit %.1f pips < min %.1f pips: BE skipped.",
                     ticket, g_configs[cfgIdx].hour, g_configs[cfgIdx].minute,
                     profPips, minProfPips);
         continue;
      }

      bool ok = ApplyBreakEven(ticket, sym, ptype, openP, curSL, curTP,
                               bid, ask, digits, pipSize,
                               g_configs[cfgIdx].hour, g_configs[cfgIdx].minute,
                               g_configs[cfgIdx].note);
      if(ok) g_configs[cfgIdx].applied = true;
   }
}

//+------------------------------------------------------------------+
//| AUTO BREAK-EVEN (time-based from panel setting)                   |
//+------------------------------------------------------------------+
int FindTrailIndex(ulong ticket)
{
   for(int i = 0; i < g_trailCount; i++)
      if(g_trails[i].ticket == ticket) return i;
   return -1;
}

void EnsureTrailEntry(ulong ticket)
{
   if(FindTrailIndex(ticket) >= 0) return;
   ArrayResize(g_trails, g_trailCount + 1);
   g_trails[g_trailCount].ticket        = ticket;
   g_trails[g_trailCount].beApplied     = false;
   g_trails[g_trailCount].highWaterMark = 0.0;
   g_trailCount++;
}

void CleanupTrails()
{
   for(int i = g_trailCount - 1; i >= 0; i--)
   {
      bool alive = false;
      for(int p = PositionsTotal() - 1; p >= 0; p--)
      {
         if(PositionGetTicket(p) == g_trails[i].ticket)
         { alive = true; break; }
      }
      if(!alive)
      {
         for(int j = i; j < g_trailCount - 1; j++)
            g_trails[j] = g_trails[j + 1];
         g_trailCount--;
         ArrayResize(g_trails, MathMax(0, g_trailCount));
      }
   }
}

void ProcessAutoBEAndTrailing()
{
   if(g_beAfterMinutes <= 0 && g_trailingPips <= 0.0) return;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;

      string sym   = PositionGetString(POSITION_SYMBOL);
      long   magic = PositionGetInteger(POSITION_MAGIC);
      if(InpMagicFilter >= 0 && magic != InpMagicFilter) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openP   = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL   = PositionGetDouble(POSITION_SL);
      double curTP   = PositionGetDouble(POSITION_TP);
      datetime openT = (datetime)PositionGetInteger(POSITION_TIME);

      int    digits  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double pipSize = GetPipSize(sym);
      if(pipSize <= 0.0) continue;

      double bid = 0.0, ask = 0.0;
      if(!GetSymbolPrices(sym, bid, ask)) continue;
      if(((ask - bid) / pipSize) > InpMaxSpreadPips) continue;

      EnsureTrailEntry(ticket);
      int tIdx = FindTrailIndex(ticket);
      if(tIdx < 0) continue;

      // --- When BE is disabled, allow trailing to work independently ---
      if(g_beAfterMinutes <= 0 && !g_trails[tIdx].beApplied)
      {
         g_trails[tIdx].beApplied     = true;
         g_trails[tIdx].highWaterMark = (ptype == POSITION_TYPE_BUY) ? bid : ask;
      }

      // --- Auto BE after X minutes ---
      if(g_beAfterMinutes > 0 && !g_trails[tIdx].beApplied)
      {
         int elapsed = (int)(TimeCurrent() - openT) / 60;
         if(elapsed >= g_beAfterMinutes)
         {
            double beSL = NormalizeDouble(
               ptype == POSITION_TYPE_BUY ? openP + InpLockInPips * pipSize
                                          : openP - InpLockInPips * pipSize, digits);

            bool alreadyBE = (ptype == POSITION_TYPE_BUY) ? (curSL >= beSL)
                                                          : (curSL > 0.0 && curSL <= beSL);
            if(alreadyBE)
            {
               g_trails[tIdx].beApplied = true;
               g_trails[tIdx].highWaterMark = (ptype == POSITION_TYPE_BUY) ? bid : ask;
            }
            else
            {
               double profPips = (ptype == POSITION_TYPE_BUY) ? (bid - openP) / pipSize
                                                              : (openP - ask) / pipSize;
               if(profPips > InpLockInPips + 1.0)
               {
                  double minDist = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) *
                                   SymbolInfoDouble(sym, SYMBOL_POINT);
                  bool valid = (ptype == POSITION_TYPE_BUY) ? (beSL < bid - minDist)
                                                            : (beSL > ask + minDist);
                  if(valid)
                  {
                     MqlTradeRequest req = {};
                     MqlTradeResult  res = {};
                     req.action   = TRADE_ACTION_SLTP;
                     req.position = ticket;
                     req.symbol   = sym;
                     req.sl       = beSL;
                     req.tp       = NormalizeDouble(curTP, digits);
                     bool ok = OrderSend(req, res);
                     if(ok && res.retcode == TRADE_RETCODE_DONE)
                     {
                        g_trails[tIdx].beApplied     = true;
                        g_trails[tIdx].highWaterMark = (ptype == POSITION_TYPE_BUY) ? bid : ask;
                        PrintFormat("[AUTO-BE] #%I64u (%s): SL -> %.5f after %d min",
                                    ticket, sym, beSL, elapsed);
                     }
                  }
               }
            }
         }
         continue;   // trailing only after BE
      }

      // --- Trailing Stop (only after BE applied) ---
      if(g_trailingPips > 0.0 && g_trails[tIdx].beApplied)
      {
         double curPrice = (ptype == POSITION_TYPE_BUY) ? bid : ask;
         double hwm      = g_trails[tIdx].highWaterMark;

         if(ptype == POSITION_TYPE_BUY)
         {
            if(curPrice > hwm) g_trails[tIdx].highWaterMark = curPrice;
            double trailSL = NormalizeDouble(
               g_trails[tIdx].highWaterMark - g_trailingPips * pipSize, digits);
            if(trailSL > curSL + pipSize * 0.5)
            {
               double minDist = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) *
                                SymbolInfoDouble(sym, SYMBOL_POINT);
               if(trailSL < bid - minDist)
               {
                  MqlTradeRequest req = {};
                  MqlTradeResult  res = {};
                  req.action   = TRADE_ACTION_SLTP;
                  req.position = ticket;
                  req.symbol   = sym;
                  req.sl       = trailSL;
                  req.tp       = NormalizeDouble(curTP, digits);
                  bool ok = OrderSend(req, res);
                  if(ok && res.retcode == TRADE_RETCODE_DONE)
                  {
                     if(InpDebugLogs)
                        PrintFormat("[TRAIL] #%I64u BUY: SL %.5f -> %.5f (HWM=%.5f)",
                                    ticket, curSL, trailSL, g_trails[tIdx].highWaterMark);
                  }
               }
            }
         }
         else
         {
            if(curPrice < hwm || hwm <= 0.0) g_trails[tIdx].highWaterMark = curPrice;
            double trailSL = NormalizeDouble(
               g_trails[tIdx].highWaterMark + g_trailingPips * pipSize, digits);
            if(trailSL < curSL - pipSize * 0.5 || curSL <= 0.0)
            {
               double minDist = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) *
                                SymbolInfoDouble(sym, SYMBOL_POINT);
               if(trailSL > ask + minDist)
               {
                  MqlTradeRequest req = {};
                  MqlTradeResult  res = {};
                  req.action   = TRADE_ACTION_SLTP;
                  req.position = ticket;
                  req.symbol   = sym;
                  req.sl       = trailSL;
                  req.tp       = NormalizeDouble(curTP, digits);
                  bool ok = OrderSend(req, res);
                  if(ok && res.retcode == TRADE_RETCODE_DONE)
                  {
                     if(InpDebugLogs)
                        PrintFormat("[TRAIL] #%I64u SELL: SL %.5f -> %.5f (HWM=%.5f)",
                                    ticket, curSL, trailSL, g_trails[tIdx].highWaterMark);
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ORDER EXECUTION - N market orders, same SL, no RR diff            |
//+------------------------------------------------------------------+
void OpenNOrders(const string symbol, ENUM_ORDER_TYPE otype,
                 double slPips, double totalLots, int count)
{
   if(totalLots <= 0.0) { Print("[EXEC] Invalid lot size."); return; }
   if(count <= 0) count = 1;
   if(count > MAX_ORD) count = MAX_ORD;

   double pipSize = GetPipSize(symbol);
   int    digits  = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   if(lotStep <= 0.0) lotStep = 0.01;

   double oneLot = MathFloor((totalLots / (double)count) / lotStep) * lotStep;
   oneLot = NormalizeDouble(MathMax(lotMin, oneLot), 2);

   bool isBuy = (otype == ORDER_TYPE_BUY);

   string cmt = StringFormat("SP_%dx", count);

   for(int i = 0; i < count; i++)
   {
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};

      req.action    = TRADE_ACTION_DEAL;
      req.type      = otype;
      req.symbol    = symbol;
      req.volume    = oneLot;
      req.deviation = 10;

      double entryPrice = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                : SymbolInfoDouble(symbol, SYMBOL_BID);
      req.price = entryPrice;

      double sl = 0.0;
      if(slPips > 0.0)
         sl = NormalizeDouble(isBuy ? entryPrice - slPips * pipSize
                                    : entryPrice + slPips * pipSize, digits);
      req.sl = sl;
      req.tp = 0.0;   // no TP - scalping mode, manage exits manually or via trailing

      req.magic   = (InpMagicFilter >= 0) ? InpMagicFilter : 0;
      req.comment = cmt;

      bool ok = OrderSend(req, res);
      if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
         PrintFormat("[EXEC] %d/%d: %s %s %.2f lots @ %.5f SL=%.5f OK (#%I64u)",
                     i + 1, count, symbol, isBuy ? "BUY" : "SELL",
                     oneLot, req.price, sl, res.order);
      else
         PrintFormat("[EXEC] %d/%d FAILED retcode=%d", i + 1, count, res.retcode);
   }
}

//+------------------------------------------------------------------+
//| SYMBOL LIST MANAGEMENT                                            |
//+------------------------------------------------------------------+
void ParseMainSymbols()
{
   g_mainSymbolsCount = 0;
   ArrayResize(g_mainSymbols, 0);
   string src = InpMainSymbols;
   while(StringLen(src) > 0)
   {
      int comma = StringFind(src, ",");
      string tok = (comma >= 0) ? StringSubstr(src, 0, comma) : src;
      src = (comma >= 0) ? StringSubstr(src, comma + 1) : "";
      StringTrimLeft(tok);
      StringTrimRight(tok);
      if(StringLen(tok) == 0) continue;
      ArrayResize(g_mainSymbols, g_mainSymbolsCount + 1);
      g_mainSymbols[g_mainSymbolsCount++] = tok;
   }
   g_mainSymbolsIdx = 0;
}

int FindSymbolIndex(const string sym)
{
   for(int i = 0; i < g_mainSymbolsCount; i++)
      if(g_mainSymbols[i] == sym) return i;
   return -1;
}

void ApplySymbolFromList(int idx)
{
   if(g_mainSymbolsCount <= 0) return;
   if(idx < 0) idx = g_mainSymbolsCount - 1;
   if(idx >= g_mainSymbolsCount) idx = 0;
   g_mainSymbolsIdx = idx;

   string sym = g_mainSymbols[idx];
   SymbolSelect(sym, true);

   if(ObjectFind(0, PREFIX + "sym_edit") >= 0)
      ObjectSetString(0, PREFIX + "sym_edit", OBJPROP_TEXT, sym);

   g_lastQuickSymbol = sym;
   UpdateLivePrice();
   UpdateLotsLabel();
   RefreshSymbolIndex();
   ChartRedraw(0);
}

void RefreshSymbolIndex()
{
   if(ObjectFind(0, PREFIX + "sym_idx") < 0) return;
   if(g_mainSymbolsCount <= 0)
   {
      ObjectSetString(0, PREFIX + "sym_idx", OBJPROP_TEXT, "");
      return;
   }
   ObjectSetString(0, PREFIX + "sym_idx", OBJPROP_TEXT,
                   StringFormat("%d/%d", g_mainSymbolsIdx + 1, g_mainSymbolsCount));
}

//+------------------------------------------------------------------+
//| PANEL HELPERS                                                     |
//+------------------------------------------------------------------+
int GetQuickCount()
{
   string txt = ObjGetText(PREFIX + "cnt_edit");
   int n = (int)StringToInteger(txt);
   if(n < 1) n = 1;
   if(n > MAX_ORD) n = MAX_ORD;
   return n;
}

void SetQuickCount(int n)
{
   if(n < 1) n = 1;
   if(n > MAX_ORD) n = MAX_ORD;
   if(ObjectFind(0, PREFIX + "cnt_edit") >= 0)
      ObjectSetString(0, PREFIX + "cnt_edit", OBJPROP_TEXT, IntegerToString(n));
   UpdateLotsLabel();
   HighlightActivePreset(n);
   ChartRedraw(0);
}

void HighlightActivePreset(int count)
{
   for(int i = 0; i < g_presetCount; i++)
   {
      string nm = PREFIX + "pre_" + IntegerToString(i);
      if(ObjectFind(0, nm) >= 0)
      {
         color bg = (g_presetCounts[i] == count) ? CLR_PRESET_ON : CLR_PRESET_OFF;
         ObjectSetInteger(0, nm, OBJPROP_BGCOLOR, bg);
      }
   }
}

void UpdateLivePrice()
{
   string sym = ObjGetText(PREFIX + "sym_edit");
   double bid = 0.0, ask = 0.0;
   if(!GetSymbolPrices(sym, bid, ask)) return;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string txt = DoubleToString(bid, digits);
   if(ObjectFind(0, PREFIX + "price_edit") >= 0)
   {
      ObjectSetString(0, PREFIX + "price_edit", OBJPROP_TEXT, txt);
      g_lastLivePriceTxt = txt;
   }
   g_lastQuickSymbol = sym;
}

void UpdateLotsLabel()
{
   string sym  = ObjGetText(PREFIX + "sym_edit");
   double slP  = StringToDouble(ObjGetText(PREFIX + "sl_edit"));
   double risk = StringToDouble(ObjGetText(PREFIX + "risk_edit"));
   int    n    = GetQuickCount();

   SymbolSelect(sym, true);
   double lots = CalcLots(sym, slP, risk);

   string txt;
   if(lots > 0.0)
   {
      double one = NormalizeDouble(lots / (double)n, 2);
      txt = StringFormat("%.2f (%.2f x%d)", lots, one, n);
   }
   else
      txt = "---";

   if(ObjectFind(0, PREFIX + "lots_val") >= 0)
      ObjectSetString(0, PREFIX + "lots_val", OBJPROP_TEXT, txt);

   ChartRedraw(0);
}

void RefreshLiveButton()
{
   if(ObjectFind(0, PREFIX + "btn_r") < 0) return;
   color bg    = g_priceLive ? CLR_LIVE_ON : CLR_LIVE_OFF;
   string txt  = g_priceLive ? "R" : "R";
   ObjectSetInteger(0, PREFIX + "btn_r", OBJPROP_BGCOLOR, bg);
   ObjectSetString(0, PREFIX + "btn_r", OBJPROP_TEXT, txt);
}

void SetLivePriceMode(bool on)
{
   g_priceLive = on;
   RefreshLiveButton();
   if(on) UpdateLivePrice();
   ChartRedraw(0);
   if(InpDebugLogs)
      PrintFormat("[PANEL] Live price %s", on ? "ON" : "OFF");
}

//+------------------------------------------------------------------+
//| OBJECT CREATION HELPERS                                           |
//+------------------------------------------------------------------+
string ObjGetText(const string n) { return ObjectGetString(0, n, OBJPROP_TEXT); }
void   ObjResetBtn(const string n) { ObjectSetInteger(0, n, OBJPROP_STATE, false); }

void ObjRect(const string n, int x, int y, int w, int h, color c, color borderClr = CLR_BORDER)
{
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, c);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_COLOR, borderClr);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);
}

void ObjLabel(const string n, int x, int y, const string txt,
              int fs = 10, color c = CLR_TEXT, const string font = "Segoe UI")
{
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, fs);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetString(0, n, OBJPROP_FONT, font);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);
}

void ObjEdit(const string n, int x, int y, int w, int h,
             const string txt, int fs = 11)
{
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, CLR_FIELD_BG);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, CLR_BORDER);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, fs);
   ObjectSetString(0, n, OBJPROP_FONT, "Segoe UI");
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void ObjBtn(const string n, int x, int y, int w, int h,
            const string txt, color bg, int fs = 10,
            const string font = "Segoe UI Semibold")
{
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, fs);
   ObjectSetString(0, n, OBJPROP_FONT, font);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);
}

//+------------------------------------------------------------------+
//| DRAW MAIN PANEL                                                   |
//+------------------------------------------------------------------+
void DrawPanel()
{
   int x = InpPanelX;
   int y = InpPanelY;
   int pad = 10;
   int fieldH = 28;
   int bigBtnH = 44;
   int sectionGap = 6;

   // Total panel height calculation
   int totalH = HDR_H                  // header
              + ROW_H                  // row 1: symbol + price
              + ROW_H                  // row 2: SL + risk + lots
              + ROW_H                  // row 3: order count + presets
              + bigBtnH + 12          // row 4: BUY / SELL
              + ROW_H + 4            // row 5: BE + trailing section
              + 8;                    // bottom padding

   // --- Background ---
   ObjRect(PREFIX + "bg", x, y, PNL_W, totalH, CLR_BG, CLR_BORDER);

   // --- Header ---
   ObjRect(PREFIX + "hdr", x, y, PNL_W, HDR_H, CLR_HDR, CLR_HDR);
   ObjLabel(PREFIX + "title", x + pad, y + 8, "SCALP PRO", 13, clrWhite, "Segoe UI Bold");
   ObjLabel(PREFIX + "ver", x + PNL_W - 42, y + 12, "v1.0", 9, CLR_TEXT_DIM);

   // ===================================================================
   // ROW 1: Symbol [<] [edit] [>] idx  |  Price [R]
   // ===================================================================
   int r1 = y + HDR_H + sectionGap;

   ObjBtn(PREFIX + "sym_prev", x + pad, r1 + 3, 24, fieldH, "<", CLR_ACCENT, 12);

   ObjEdit(PREFIX + "sym_edit", x + pad + 26, r1 + 3, 100, fieldH, _Symbol);

   ObjBtn(PREFIX + "sym_next", x + pad + 128, r1 + 3, 24, fieldH, ">", CLR_ACCENT, 12);

   ObjLabel(PREFIX + "sym_idx", x + pad + 156, r1 + 10, "", 9, CLR_TEXT_DIM);

   ObjLabel(PREFIX + "lbl_price", x + 200, r1 + 10, "Prezzo", 9, CLR_TEXT_DIM);
   int priceDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   ObjEdit(PREFIX + "price_edit", x + 244, r1 + 3, 110, fieldH,
           DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), priceDigits));

   ObjBtn(PREFIX + "btn_r", x + 358, r1 + 3, 30, fieldH, "R", CLR_LIVE_OFF, 11);

   // ===================================================================
   // ROW 2: SL pips | Risk EUR | Lots
   // ===================================================================
   int r2 = r1 + ROW_H + 2;

   ObjLabel(PREFIX + "lbl_sl", x + pad, r2 + 10, "SL", 9, CLR_TEXT_DIM);
   string slDef = DoubleToString(InpDefaultSlPips,
                  (InpDefaultSlPips == MathFloor(InpDefaultSlPips)) ? 0 : 1);
   ObjEdit(PREFIX + "sl_edit", x + pad + 22, r2 + 3, 68, fieldH, slDef);
   ObjLabel(PREFIX + "lbl_sl2", x + pad + 93, r2 + 10, "pip", 9, CLR_TEXT_DIM);

   ObjLabel(PREFIX + "lbl_risk", x + 130, r2 + 10, "Risk", 9, CLR_TEXT_DIM);
   string riskDef = DoubleToString(InpDefaultRiskEur,
                    (InpDefaultRiskEur == MathFloor(InpDefaultRiskEur)) ? 0 : 1);
   ObjEdit(PREFIX + "risk_edit", x + 162, r2 + 3, 68, fieldH, riskDef);
   ObjLabel(PREFIX + "lbl_eur", x + 233, r2 + 10, "EUR", 9, CLR_TEXT_DIM);   // changed to EUR label

   ObjLabel(PREFIX + "lbl_lots", x + 272, r2 + 10, "Lotti", 9, CLR_TEXT_DIM);
   ObjLabel(PREFIX + "lots_val", x + 308, r2 + 10, "---", 11, CLR_LOTS, "Segoe UI Semibold");

   // ===================================================================
   // ROW 3: Order count + presets (2, 3, 5, 10)
   // ===================================================================
   int r3 = r2 + ROW_H + 2;

   ObjLabel(PREFIX + "lbl_cnt", x + pad, r3 + 10, "Ordini", 9, CLR_TEXT_DIM);

   int cntDefault = 3;
   ObjEdit(PREFIX + "cnt_edit", x + pad + 48, r3 + 3, 46, fieldH,
           IntegerToString(cntDefault), 11);

   int px = x + pad + 104;
   int pw = 40;
   int pgap = 4;
   for(int i = 0; i < g_presetCount; i++)
   {
      string nm  = PREFIX + "pre_" + IntegerToString(i);
      string lbl = IntegerToString(g_presetCounts[i]);
      color  bg  = (g_presetCounts[i] == cntDefault) ? CLR_PRESET_ON : CLR_PRESET_OFF;
      ObjBtn(nm, px, r3 + 3, pw, fieldH, lbl, bg, 10);
      px += pw + pgap;
   }

   // ===================================================================
   // ROW 4: BUY / SELL big buttons
   // ===================================================================
   int r4 = r3 + ROW_H + 4;
   int btnW = (PNL_W - 2 * pad - 8) / 2;

   ObjBtn(PREFIX + "btn_buy", x + pad, r4, btnW, bigBtnH,
          "BUY", CLR_BUY, 16, "Segoe UI Bold");

   ObjBtn(PREFIX + "btn_sell", x + pad + btnW + 8, r4, btnW, bigBtnH,
          "SELL", CLR_SELL, 16, "Segoe UI Bold");

   // ===================================================================
   // ROW 5: BE + Trailing section (separated visually)
   // ===================================================================
   int r5 = r4 + bigBtnH + 8;
   int sectionH = ROW_H + 4;

   ObjRect(PREFIX + "be_bg", x + 2, r5, PNL_W - 4, sectionH, CLR_BE_SECTION, CLR_BORDER);

   ObjLabel(PREFIX + "lbl_be", x + pad, r5 + 10, "BE dopo", 9, CLR_TEXT_DIM);
   ObjEdit(PREFIX + "be_min_edit", x + pad + 52, r5 + 5, 40, fieldH - 4,
           IntegerToString(InpBEAfterMinutes), 10);
   ObjLabel(PREFIX + "lbl_bemin", x + pad + 96, r5 + 10, "min", 9, CLR_TEXT_DIM);

   ObjLabel(PREFIX + "lbl_trail", x + 200, r5 + 10, "Trail", 9, CLR_TEXT_DIM);
   ObjEdit(PREFIX + "trail_edit", x + 238, r5 + 5, 48, fieldH - 4,
           DoubleToString(InpTrailingPips, 1), 10);
   ObjLabel(PREFIX + "lbl_trpip", x + 290, r5 + 10, "pips", 9, CLR_TEXT_DIM);

   // --- Final refresh ---
   RefreshSymbolIndex();
   RefreshLiveButton();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| PANEL EVENT HANDLER                                               |
//+------------------------------------------------------------------+
void HandlePanelClick(const string obj)
{
   ObjResetBtn(obj);

   // --- Symbol navigation ---
   if(obj == PREFIX + "sym_prev") { ApplySymbolFromList(g_mainSymbolsIdx - 1); return; }
   if(obj == PREFIX + "sym_next") { ApplySymbolFromList(g_mainSymbolsIdx + 1); return; }

   // --- Live price toggle ---
   if(obj == PREFIX + "btn_r") { SetLivePriceMode(!g_priceLive); return; }

   // --- Preset click ---
   for(int i = 0; i < g_presetCount; i++)
   {
      if(obj == PREFIX + "pre_" + IntegerToString(i))
      {
         SetQuickCount(g_presetCounts[i]);
         return;
      }
   }

   // --- BUY / SELL ---
   if(obj == PREFIX + "btn_buy" || obj == PREFIX + "btn_sell")
   {
      string sym  = ObjGetText(PREFIX + "sym_edit");
      double slP  = StringToDouble(ObjGetText(PREFIX + "sl_edit"));
      double risk = StringToDouble(ObjGetText(PREFIX + "risk_edit"));
      int    n    = GetQuickCount();

      SymbolSelect(sym, true);
      double lots = CalcLots(sym, slP, risk);

      if(lots <= 0.0)
      {
         Print("[EXEC] Invalid lot calculation. Check SL and Risk.");
         UpdateLotsLabel();
         return;
      }

      ENUM_ORDER_TYPE otype = (obj == PREFIX + "btn_buy") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      OpenNOrders(sym, otype, slP, lots, n);

      Sleep(300);
      UpdateLotsLabel();
      return;
   }
}

//+------------------------------------------------------------------+
//| INIT                                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetAsyncMode(false);

   g_configCount  = 0;
   ArrayResize(g_configs, 0);
   g_trailCount   = 0;
   ArrayResize(g_trails, 0);
   g_priceLive    = false;
   g_lastLivePriceTxt = "";
   g_lastQuickSymbol  = "";

   g_beAfterMinutes = InpBEAfterMinutes;
   g_trailingPips   = InpTrailingPips;

   ParseMainSymbols();
   int sidx = FindSymbolIndex(_Symbol);
   g_mainSymbolsIdx = (sidx >= 0) ? sidx : 0;

   // Pre-select symbols in Market Watch
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      SymbolSelect(PositionGetString(POSITION_SYMBOL), true);
   }

   LoadConfig();
   ReconcileConfigFile();
   DrawPanel();
   UpdateLivePrice();
   UpdateLotsLabel();

   EventSetTimer(1);
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);

   PrintFormat("ScalpPro v1.00 | Config: %s | SL=%.0f pips | Risk=%.0f EUR",
               InpConfigFile, InpDefaultSlPips, InpDefaultRiskEur);
   PrintFormat("Auto BE after %d min | Trailing %.1f pips | Lock-in %.1f pips",
               InpBEAfterMinutes, InpTrailingPips, InpLockInPips);
   PrintFormat("Symbols (%d): %s", g_mainSymbolsCount, InpMainSymbols);
   Print("Config format: ticket=HH:MM | ticket=NO | ticket=HH:MM|note");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINIT                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
}

//+------------------------------------------------------------------+
//| TIMER                                                             |
//+------------------------------------------------------------------+
void OnTimer()
{
   ReconcileConfigFile();
   LoadConfig();

   if(g_priceLive)
      UpdateLivePrice();

   ProcessConfigBreakEven();
   ProcessAutoBEAndTrailing();
   CleanupTrails();
}

//+------------------------------------------------------------------+
//| TICK                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(g_priceLive)
      UpdateLivePrice();

   ProcessConfigBreakEven();
   ProcessAutoBEAndTrailing();
}

//+------------------------------------------------------------------+
//| TRADE TRANSACTION - auto-add new positions to config              |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.deal != 0)
   {
      if(HistoryDealSelect(trans.deal))
      {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN)
         {
            ulong pos = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
            if(pos != 0)
               AppendTicketToConfig(pos, "NO");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CHART EVENT                                                       |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(StringFind(sparam, PREFIX) >= 0)
         HandlePanelClick(sparam);
      return;
   }

   if(id == CHARTEVENT_OBJECT_ENDEDIT)
   {
      if(sparam == PREFIX + "sym_edit")
      {
         string newSym = ObjGetText(PREFIX + "sym_edit");
         if(newSym != g_lastQuickSymbol)
         {
            UpdateLivePrice();
            g_lastQuickSymbol = newSym;
         }
         UpdateLotsLabel();
      }
      else if(sparam == PREFIX + "price_edit")
      {
         string cur = ObjGetText(PREFIX + "price_edit");
         if(cur != g_lastLivePriceTxt && g_priceLive)
         {
            SetLivePriceMode(false);
            if(InpDebugLogs)
               Print("[PANEL] Price edited manually -> live OFF.");
         }
      }
      else if(sparam == PREFIX + "cnt_edit")
      {
         int n = GetQuickCount();
         SetQuickCount(n);
      }
      else if(sparam == PREFIX + "sl_edit" || sparam == PREFIX + "risk_edit")
      {
         UpdateLotsLabel();
      }
      else if(sparam == PREFIX + "be_min_edit")
      {
         int val = (int)StringToInteger(ObjGetText(PREFIX + "be_min_edit"));
         if(val < 0) val = 0;
         g_beAfterMinutes = val;
         if(InpDebugLogs)
            PrintFormat("[PANEL] BE minutes changed to %d", g_beAfterMinutes);
      }
      else if(sparam == PREFIX + "trail_edit")
      {
         double val = StringToDouble(ObjGetText(PREFIX + "trail_edit"));
         if(val < 0.0) val = 0.0;
         g_trailingPips = val;
         if(InpDebugLogs)
            PrintFormat("[PANEL] Trailing pips changed to %.1f", g_trailingPips);
      }
   }

   if(id == CHARTEVENT_KEYDOWN)
   {
      if(lparam == 82) // R key
         SetLivePriceMode(!g_priceLive);
   }
}
//+------------------------------------------------------------------+
