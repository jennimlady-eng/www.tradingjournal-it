//+------------------------------------------------------------------+
//|                                           BreakEvenManager.mq5  |
//|   Break Even + Ordini Pendenti + Apertura Rapida N Posizioni    |
//|                        Compatible with MetaTrader 5             |
//+------------------------------------------------------------------+
#property copyright   "BreakEvenManager"
#property link        ""
#property version     "9.00"
#property strict
#property description "BE da file + apertura rapida N posizioni + tab Mercato + selettore simboli + prezzo live."
#include <Trade\Trade.mqh>
string ConfigFile              = "be_config.txt";
input double LockInPips              = 0.0;
long   MagicFilter             = -1;
bool   AllowBuyPositions       = true;
bool   AllowSellPositions      = true;
double MaxSpreadPips           = 999.0;
bool   TestAllowBEWithoutProfit= false;
input bool   DebugBELogs             = true;
bool   AutoAddTicketsToConfig  = true;
bool   AutoRemoveCanceledTickets = true;
string DefaultBEValue          = "NO";
int    DefaultQuickCount       = 3;
string QuickCountPresets       = "1,2,3,5,10";
input double DefaultSlPips            = 60.0;       // SL pips di default nel pannello
input double DefaultRiskEur           = 110.0;      // Rischio EUR di default nel pannello
input string MainSymbols              = "EURUSD,USDJPY,GBPJPY,GBPNZD,GBPCAD,GBPAUD,EURJPY,EURAUD,CADJPY,AUDUSD,AUDJPY";
input double RR_Position1             = 2.0;        // RR per la 1a posizione (1:2)
input double RR_Position2             = 3.0;        // RR per la 2a posizione (1:3)
input double RR_Position3             = 4.0;        // RR per la 3a posizione (1:4)
input int    PanelX                  = 20;
input int    PanelY                  = 20;
CTrade g_trade;
struct SBeConfig
{
   ulong  ticket;
   int    hour;
   int    minute;
   bool   applied;   // BE gia' applicato o SL gia' al livello BE
   bool   stale;     // Orario passato con posizione in SL -> "dimenticato" finche' non arriva una nuova data
   string note;
   string rawValue;
};
SBeConfig g_configs[];
int       g_configCount = 0;
string g_pendingSignature = "";
string g_lastQuickSymbol  = "";
int    g_quickPanelH      = 0;
// --- Stato "prezzo live" del pannello rapido ---
bool   g_priceLive        = false;   // se true, il campo "Prezzo" segue il Bid in tempo reale
string g_lastLivePriceTxt = "";      // ultimo testo scritto automaticamente (per distinguere edit utente)
// --- Preset count ---
int    g_presetCounts[];
int    g_presetCount = 0;
// --- Tab attivo del pannello di apertura rapida ---
// 0 = PENDENTI (BUY/SELL LMT + STOP), 1 = MERCATO (BUY/SELL MKT grandi)
int    g_activeTab = 0;
// --- Lista simboli principali (freccette < >) ---
string g_mainSymbols[];
int    g_mainSymbolsCount = 0;
int    g_mainSymbolsIdx   = 0;
#define PREFIX  "BEM_"
#define PNL_W   720
#define ROW_H   34
#define MAX_QUICK_COUNT 50
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
   MqlDateTime t; TimeToStruct(TimeLocal(), t);
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
bool TicketExistsInConfig(ulong ticket)
{
   for(int i=0;i<g_configCount;i++)
      if(g_configs[i].ticket==ticket) return true;
   return false;
}
bool IsTicketInFile(ulong ticket)
{
   if(!FileIsExist(ConfigFile)) return false;
   int f = FileOpen(ConfigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(f==INVALID_HANDLE) return false;
   bool found=false;
   while(!FileIsEnding(f))
   {
      string line=FileReadString(f);
      StringTrimLeft(line); StringTrimRight(line);
      if(StringLen(line)==0 || StringGetCharacter(line,0)=='#') continue;
      int sep=StringFind(line,"=");
      if(sep<=0) continue;
      ulong lt=(ulong)StringToInteger(StringSubstr(line,0,sep));
      if(lt==ticket){ found=true; break; }
   }
   FileClose(f);
   return found;
}
void AppendTicketToConfig(ulong ticket, const string defaultValue)
{
   if(ticket==0) return;
   if(!AutoAddTicketsToConfig) return;
   if(TicketExistsInConfig(ticket) || IsTicketInFile(ticket))
   {
      if(DebugBELogs)
         PrintFormat("[CFG] Ticket #%I64u gia' presente, skip append.",ticket);
      return;
   }
   bool exists = FileIsExist(ConfigFile);
   int flags = FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   int mode  = exists ? (FILE_READ|FILE_WRITE) : FILE_WRITE;
   int file  = FileOpen(ConfigFile, mode|flags);
   if(file==INVALID_HANDLE)
   {
      PrintFormat("[CFG] Errore apertura %s per append (err=%d)",ConfigFile,GetLastError());
      return;
   }
   if(exists) FileSeek(file,0,SEEK_END);
   string line = StringFormat("%I64u=%s",ticket,defaultValue);
   if(exists) FileWriteString(file,"\r\n"+line);
   else       FileWriteString(file,line+"\r\n");
   FileClose(file);
   PrintFormat("[CFG] Aggiunto ticket #%I64u='%s' in %s",ticket,defaultValue,ConfigFile);
   ArrayResize(g_configs,g_configCount+1);
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
   if(ticket==0) return;
   int idx=-1;
   for(int i=0;i<g_configCount;i++)
      if(g_configs[i].ticket==ticket){idx=i;break;}
   if(idx>=0)
   {
      for(int i=idx;i<g_configCount-1;i++) g_configs[i]=g_configs[i+1];
      g_configCount--;
      if(g_configCount>=0) ArrayResize(g_configs,g_configCount);
   }
   if(!FileIsExist(ConfigFile)) return;
   int rf = FileOpen(ConfigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(rf==INVALID_HANDLE) return;
   string lines[]; int n=0; bool removed=false;
   while(!FileIsEnding(rf))
   {
      string raw=FileReadString(rf);
      string trimmed=raw;
      StringTrimLeft(trimmed); StringTrimRight(trimmed);
      bool skip=false;
      if(StringLen(trimmed)>0 && StringGetCharacter(trimmed,0)!='#')
      {
         int sep=StringFind(trimmed,"=");
         if(sep>0)
         {
            ulong lt=(ulong)StringToInteger(StringSubstr(trimmed,0,sep));
            if(lt==ticket){skip=true;removed=true;}
         }
      }
      if(!skip){ ArrayResize(lines,n+1); lines[n++]=raw; }
   }
   FileClose(rf);
   if(!removed) return;
   int wf = FileOpen(ConfigFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(wf==INVALID_HANDLE) return;
   for(int i=0;i<n;i++)
   {
      if(i<n-1) FileWriteString(wf,lines[i]+"\r\n");
      else      FileWriteString(wf,lines[i]);
   }
   FileClose(wf);
   PrintFormat("[CFG] Rimosso ticket #%I64u da %s",ticket,ConfigFile);
}
void ReconcileConfigFile()
{
   if(!FileIsExist(ConfigFile)) return;
   ulong alive[]; int na=0;
   int ot = OrdersTotal();
   for(int i=0;i<ot;i++)
   {
      ulong t=OrderGetTicket(i);
      if(t!=0){ ArrayResize(alive,na+1); alive[na++]=t; }
   }
   int pt = PositionsTotal();
   for(int i=0;i<pt;i++)
   {
      ulong t=PositionGetTicket(i);
      if(t!=0){ ArrayResize(alive,na+1); alive[na++]=t; }
   }
   int rf = FileOpen(ConfigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(rf==INVALID_HANDLE) return;
   string lines[]; int ln=0; bool changed=false;
   while(!FileIsEnding(rf))
   {
      string raw = FileReadString(rf);
      string trimmed = raw;
      StringTrimLeft(trimmed); StringTrimRight(trimmed);
      bool keep = true;
      if(StringLen(trimmed)>0 && StringGetCharacter(trimmed,0)!='#')
      {
         int sep = StringFind(trimmed,"=");
         if(sep>0)
         {
            ulong lt = (ulong)StringToInteger(StringSubstr(trimmed,0,sep));
            if(lt!=0)
            {
               bool isAlive=false;
               for(int k=0;k<na;k++) if(alive[k]==lt){isAlive=true;break;}
               if(!isAlive){ keep=false; changed=true; }
            }
         }
      }
      if(keep){ ArrayResize(lines,ln+1); lines[ln++]=raw; }
   }
   FileClose(rf);
   if(!changed) return;
   int wf = FileOpen(ConfigFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(wf==INVALID_HANDLE) return;
   for(int i=0;i<ln;i++)
   {
      if(i<ln-1) FileWriteString(wf,lines[i]+"\r\n");
      else       FileWriteString(wf,lines[i]);
   }
   FileClose(wf);
   for(int i=g_configCount-1;i>=0;i--)
   {
      bool isAlive=false;
      for(int k=0;k<na;k++) if(alive[k]==g_configs[i].ticket){isAlive=true;break;}
      if(!isAlive)
      {
         for(int j=i;j<g_configCount-1;j++) g_configs[j]=g_configs[j+1];
         g_configCount--;
         if(g_configCount>=0) ArrayResize(g_configs,g_configCount);
      }
   }
   if(DebugBELogs) Print("[CFG] Reconcile: rimosse righe di ticket non piu' attivi");
}
//+------------------------------------------------------------------+
//| Apertura di N ordini (mercato o pendenti) ripartendo i lotti     |
//+------------------------------------------------------------------+
double GetPositionRR(int posIndex)
{
   switch(posIndex)
   {
      case 0:  return RR_Position1;
      case 1:  return RR_Position2;
      case 2:  return RR_Position3;
      default: return RR_Position1;
   }
}
void OpenNOrders(const string symbol, ENUM_ORDER_TYPE otype,
                 double price, double slPips, double totalLots, int count)
{
   if(totalLots <= 0.0) { Print("[OPEN] Lotti non validi."); return; }
   if(count <= 0) count = 1;
   if(count > MAX_QUICK_COUNT) count = MAX_QUICK_COUNT;
   double pipSize  = GetPipSize(symbol);
   int    digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double lotStep  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double lotMin   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   if(lotStep <= 0.0) lotStep = 0.01;
   double oneLot = MathFloor((totalLots / (double)count) / lotStep) * lotStep;
   oneLot = NormalizeDouble(MathMax(lotMin, oneLot), 2);
   bool isBuy = (otype == ORDER_TYPE_BUY ||
                 otype == ORDER_TYPE_BUY_LIMIT ||
                 otype == ORDER_TYPE_BUY_STOP);
   double sl = 0.0;
   if(slPips > 0.0)
      sl = NormalizeDouble(isBuy ? price - slPips * pipSize
                                 : price + slPips * pipSize, digits);
   string cmt = StringFormat("BEM_%dx", count);
   for(int i = 0; i < count; i++)
   {
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      double entryPrice = price;
      if(otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_SELL)
      {
         req.action    = TRADE_ACTION_DEAL;
         req.type      = otype;
         entryPrice    = (otype == ORDER_TYPE_BUY)
                         ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(symbol, SYMBOL_BID);
         req.price     = entryPrice;
         req.deviation = 10;
      }
      else
      {
         req.action    = TRADE_ACTION_PENDING;
         req.type      = otype;
         entryPrice    = NormalizeDouble(price, digits);
         req.price     = entryPrice;
         req.type_time = ORDER_TIME_GTC;
      }
      double tp = 0.0;
      double rr = GetPositionRR(i);
      if(slPips > 0.0 && rr > 0.0)
      {
         double tpPips = slPips * rr;
         tp = NormalizeDouble(isBuy ? entryPrice + tpPips * pipSize
                                    : entryPrice - tpPips * pipSize, digits);
      }
      req.symbol  = symbol;
      req.volume  = oneLot;
      req.sl      = sl;
      req.tp      = tp;
      req.magic   = (MagicFilter >= 0) ? MagicFilter : 0;
      req.comment = cmt;
      bool ok = OrderSend(req, res);
      if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
         PrintFormat("[OPEN] %d/%d: %s %s %.2f lotti @ %.5f SL=%.5f TP=%.5f (RR=1:%.0f) OK (ticket=%I64u)",
                     i+1, count, symbol, EnumToString(otype), oneLot, req.price, sl, tp, rr, res.order);
      else
         PrintFormat("[OPEN] %d/%d FALLITO retcode=%d", i+1, count, res.retcode);
   }
}
void LoadConfig()
{
   int file = FileOpen(ConfigFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(file == INVALID_HANDLE)
   {
      if(DebugBELogs)
         PrintFormat("[BE] Config non trovato: %s | path: %s\\MQL5\\Files\\",
                     ConfigFile, TerminalInfoString(TERMINAL_DATA_PATH));
      return;
   }
   for(int i = 0; i < g_configCount; i++)
      if(!g_configs[i].applied) { g_configs[i].hour=-1; g_configs[i].minute=-1; g_configs[i].note=""; }
   while(!FileIsEnding(file))
   {
      string line = FileReadString(file);
      StringTrimLeft(line); StringTrimRight(line);
      if(StringLen(line)==0 || StringGetCharacter(line,0)=='#') continue;
      int sep = StringFind(line,"=");
      if(sep < 0) continue;
      ulong  ticket = (ulong)StringToInteger(StringSubstr(line,0,sep));
      string val    = StringSubstr(line,sep+1);
      StringTrimLeft(val); StringTrimRight(val);
      if(ticket == 0) continue;
      int idx = -1;
      for(int i=0;i<g_configCount;i++)
         if(g_configs[i].ticket==ticket){idx=i;break;}
      if(idx < 0)
      {
         ArrayResize(g_configs, g_configCount+1);
         g_configs[g_configCount].ticket=ticket;
         g_configs[g_configCount].applied=false;
         g_configs[g_configCount].stale=false;
         g_configs[g_configCount].note="";
         g_configs[g_configCount].rawValue="";
         idx=g_configCount++;
      }
      string rawConfigValue = val;
      if(g_configs[idx].rawValue != "" && g_configs[idx].rawValue != rawConfigValue)
      {
         // Nuova configurazione per lo stesso ticket -> riarma tutto
         g_configs[idx].applied = false;
         g_configs[idx].stale   = false;
         if(DebugBELogs)
            PrintFormat("[BE] #%I64u: nuovo valore config ('%s' -> '%s'), riarmo BE.",
                        ticket, g_configs[idx].rawValue, rawConfigValue);
      }
      g_configs[idx].rawValue = rawConfigValue;
      string note = "";
      int noteSep = StringFind(val,"|");
      if(noteSep >= 0)
      {
         note = StringSubstr(val,noteSep+1);
         val  = StringSubstr(val,0,noteSep);
         StringTrimLeft(note); StringTrimRight(note);
      }
      g_configs[idx].note = note;
      if(val=="NO"||val=="no"){ g_configs[idx].hour=-1; g_configs[idx].minute=-1; continue; }
      if(StringLen(val)>=5 && StringSubstr(val,2,1)==":")
      {
         int h=(int)StringToInteger(StringSubstr(val,0,2));
         int m=(int)StringToInteger(StringSubstr(val,3,2));
         if(h>=0&&h<=23&&m>=0&&m<=59&&!g_configs[idx].applied)
            { g_configs[idx].hour=h; g_configs[idx].minute=m; }
      }
   }
   FileClose(file);
   if(DebugBELogs)
      PrintFormat("[BE] Config caricato: %d ticket", g_configCount);
}
bool ApplyBreakEven(ulong ticket, const string symbol,
                    ENUM_POSITION_TYPE ptype,
                    double openP, double curSL, double curTP,
                    double bid, double ask, int digits, double pipSize,
                    int beH, int beM, const string note)
{
   double newSL = NormalizeDouble(
      ptype==POSITION_TYPE_BUY ? openP+LockInPips*pipSize
                               : openP-LockInPips*pipSize, digits);
   if(ptype==POSITION_TYPE_BUY  && curSL>=newSL) return false;
   if(ptype==POSITION_TYPE_SELL && curSL<=newSL && curSL>0.0) return false;
   double minDist = SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL)*
                    SymbolInfoDouble(symbol,SYMBOL_POINT);
   if(ptype==POSITION_TYPE_BUY  && newSL>=bid-minDist)
   {
      PrintFormat("[BE] #%I64u: SL rifiutato stop level. stops_level=%d pts, minDist=%.5f, bid=%.5f, newSL=%.5f, diff=%.5f",
                  ticket,(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL),
                  minDist,bid,newSL,bid-newSL);
      return false;
   }
   if(ptype==POSITION_TYPE_SELL && newSL<=ask+minDist)
   {
      PrintFormat("[BE] #%I64u: SL rifiutato stop level. stops_level=%d pts, minDist=%.5f, ask=%.5f, newSL=%.5f, diff=%.5f",
                  ticket,(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL),
                  minDist,ask,newSL,newSL-ask);
      return false;
   }
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_SLTP; req.position=ticket; req.symbol=symbol;
   req.sl=newSL; req.tp=NormalizeDouble(curTP,digits);
   bool ok = OrderSend(req,res);
   if(ok && res.retcode==TRADE_RETCODE_DONE)
      PrintFormat("[BE] #%I64u (%s): SL->%.5f alle %02d:%02d%s",
                  ticket,symbol,newSL,beH,beM,
                  StringLen(note)>0?" | "+note:"");
   else
      PrintFormat("[BE] #%I64u FALLITO retcode=%d",ticket,res.retcode);
   return ok && res.retcode==TRADE_RETCODE_DONE;
}
void ProcessBreakEvenAllSymbols()
{
   int total=PositionsTotal();
   if(total==0)return;
   for(int i=total-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0||!PositionSelectByTicket(ticket))continue;
      string sym  =PositionGetString(POSITION_SYMBOL);
      long   magic=PositionGetInteger(POSITION_MAGIC);
      ENUM_POSITION_TYPE ptype=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openP=PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL=PositionGetDouble(POSITION_SL);
      double curTP=PositionGetDouble(POSITION_TP);
      if(MagicFilter>=0&&magic!=MagicFilter)continue;
      if(ptype==POSITION_TYPE_BUY  &&!AllowBuyPositions) continue;
      if(ptype==POSITION_TYPE_SELL &&!AllowSellPositions)continue;
      double point=SymbolInfoDouble(sym,SYMBOL_POINT);
      int    digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      if(point<=0.0||digits<=0)continue;
      double bid=0.0, ask=0.0;
      if(!GetSymbolPrices(sym,bid,ask))continue;
      double pipSize=GetPipSize(sym);
      if(pipSize<=0.0)continue;
      if(((ask-bid)/pipSize)>MaxSpreadPips)continue;
      int cfgIdx=-1;
      for(int c=0;c<g_configCount;c++)
         if(g_configs[c].ticket==ticket){cfgIdx=c;break;}
      if(cfgIdx<0)continue;
      if(g_configs[cfgIdx].applied)continue;
      if(g_configs[cfgIdx].stale)
      {
         // Ignorato finche' non arriva una nuova data nel config
         continue;
      }
      if(g_configs[cfgIdx].hour<0)continue;
      if(!IsTimeReached(g_configs[cfgIdx].hour,g_configs[cfgIdx].minute))
      {
         if(DebugBELogs)
         {
            MqlDateTime nowLocal; TimeToStruct(TimeLocal(), nowLocal);
            PrintFormat("[BE] #%I64u attendo %02d:%02d, ora locale %02d:%02d",
                        ticket,g_configs[cfgIdx].hour,g_configs[cfgIdx].minute,
                        nowLocal.hour,nowLocal.min);
         }
         continue;
      }
      double targetSL=NormalizeDouble(
         ptype==POSITION_TYPE_BUY?openP+LockInPips*pipSize
                                 :openP-LockInPips*pipSize,digits);
      bool beApplied=(ptype==POSITION_TYPE_BUY)?(curSL>=targetSL):(curSL>0.0&&curSL<=targetSL);
      if(beApplied){g_configs[cfgIdx].applied=true;continue;}
      double profPips=(ptype==POSITION_TYPE_BUY)?(bid-openP)/pipSize:(openP-ask)/pipSize;
      // --- Nuova regola: orario passato + posizione in perdita => "dimentica" il BE
      if(profPips < 0.0 && !TestAllowBEWithoutProfit)
      {
         g_configs[cfgIdx].stale = true;
         PrintFormat("[BE] #%I64u orario %02d:%02d passato con posizione in SL (%.1f pips): BE DIMENTICATO. Scrivere una NUOVA ora nel config per riarmare.",
                     ticket, g_configs[cfgIdx].hour, g_configs[cfgIdx].minute, profPips);
         continue;
      }
      double stopsLevelPips = (SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL)*
                               SymbolInfoDouble(sym,SYMBOL_POINT)) / pipSize;
      double minProfitPips  = MathMax(2.0, stopsLevelPips + LockInPips + 1.0);
      if(!TestAllowBEWithoutProfit && profPips<=minProfitPips)
      {
         if(DebugBELogs)
            PrintFormat("[BE] #%I64u non abbastanza in profitto (%.1f pips, serve >%.1f, stops_level=%.1f pips), attendo.",
                        ticket,profPips,minProfitPips,stopsLevelPips);
         continue;
      }
      bool ok=ApplyBreakEven(ticket,sym,ptype,openP,curSL,curTP,bid,ask,digits,pipSize,
                             g_configs[cfgIdx].hour,g_configs[cfgIdx].minute,g_configs[cfgIdx].note);
      if(ok)g_configs[cfgIdx].applied=true;
   }
}
void ObjRect(const string n,int x,int y,int w,int h,color c)
{
   if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,c);ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clrDimGray);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);
}
void ObjLabel(const string n,int x,int y,const string txt,int fs=10,color c=clrWhite)
{
   if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetString(0,n,OBJPROP_FONT,"Arial");ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_BACK,false);
}
void ObjEdit(const string n,int x,int y,int w,int h,const string txt,int fs=11)
{
   if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'35,35,48');ObjectSetInteger(0,n,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,clrDimGray);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,n,OBJPROP_FONT,"Arial");ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
}
void ObjBtn(const string n,int x,int y,int w,int h,const string txt,color bg,int fs=10)
{
   if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,n,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);ObjectSetString(0,n,OBJPROP_FONT,"Arial Bold");
   ObjectSetString(0,n,OBJPROP_TEXT,txt);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);
}
string ObjGetText(const string n){return ObjectGetString(0,n,OBJPROP_TEXT);}
void ObjResetBtn(const string n){ObjectSetInteger(0,n,OBJPROP_STATE,false);}
//+------------------------------------------------------------------+
//| Preset della quantita' di ordini                                 |
//+------------------------------------------------------------------+
void ParseMainSymbols()
{
   g_mainSymbolsCount = 0;
   ArrayResize(g_mainSymbols, 0);
   string src = MainSymbols;
   while(StringLen(src) > 0)
   {
      int comma = StringFind(src, ",");
      string tok = (comma >= 0) ? StringSubstr(src, 0, comma) : src;
      src = (comma >= 0) ? StringSubstr(src, comma+1) : "";
      StringTrimLeft(tok); StringTrimRight(tok);
      if(StringLen(tok) == 0) continue;
      ArrayResize(g_mainSymbols, g_mainSymbolsCount+1);
      g_mainSymbols[g_mainSymbolsCount++] = tok;
   }
   g_mainSymbolsIdx = 0;
}
int FindSymbolIndex(const string sym)
{
   for(int i=0;i<g_mainSymbolsCount;i++)
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
   if(ObjectFind(0,PREFIX+"qk_sym")>=0)
      ObjectSetString(0,PREFIX+"qk_sym",OBJPROP_TEXT,sym);
   g_lastQuickSymbol = sym;
   UpdateQuickPrice();
   UpdateLotsLabel();
   RefreshSymbolLabel();
   ChartRedraw(0);
}
void RefreshSymbolLabel()
{
   if(ObjectFind(0,PREFIX+"qk_sym_pos")<0) return;
   if(g_mainSymbolsCount <= 0)
   {
      ObjectSetString(0,PREFIX+"qk_sym_pos",OBJPROP_TEXT,"");
      return;
   }
   string txt = StringFormat("%d/%d", g_mainSymbolsIdx+1, g_mainSymbolsCount);
   ObjectSetString(0,PREFIX+"qk_sym_pos",OBJPROP_TEXT,txt);
}
void ParsePresetCounts()
{
   g_presetCount = 0;
   ArrayResize(g_presetCounts, 0);
   string src = QuickCountPresets;
   while(StringLen(src) > 0)
   {
      int comma = StringFind(src, ",");
      string tok = (comma >= 0) ? StringSubstr(src, 0, comma) : src;
      src = (comma >= 0) ? StringSubstr(src, comma+1) : "";
      StringTrimLeft(tok); StringTrimRight(tok);
      if(StringLen(tok) == 0) continue;
      int v = (int)StringToInteger(tok);
      if(v < 1) v = 1;
      if(v > MAX_QUICK_COUNT) v = MAX_QUICK_COUNT;
      ArrayResize(g_presetCounts, g_presetCount+1);
      g_presetCounts[g_presetCount++] = v;
   }
   if(g_presetCount == 0)
   {
      int fallback[] = {1,2,3,5,10};
      g_presetCount = ArraySize(fallback);
      ArrayResize(g_presetCounts, g_presetCount);
      for(int i=0;i<g_presetCount;i++) g_presetCounts[i] = fallback[i];
   }
}
int GetQuickCount()
{
   string txt = ObjGetText(PREFIX+"qk_cnt");
   int n = (int)StringToInteger(txt);
   if(n < 1) n = 1;
   if(n > MAX_QUICK_COUNT) n = MAX_QUICK_COUNT;
   return n;
}
void SetQuickCount(int n)
{
   if(n < 1) n = 1;
   if(n > MAX_QUICK_COUNT) n = MAX_QUICK_COUNT;
   if(ObjectFind(0,PREFIX+"qk_cnt")>=0)
      ObjectSetString(0,PREFIX+"qk_cnt",OBJPROP_TEXT,IntegerToString(n));
   RefreshQuickTitle();
   UpdateLotsLabel();
   ChartRedraw(0);
}
void RefreshQuickTitle()
{
   int n = GetQuickCount();
   string modo = (g_activeTab==1) ? "MERCATO" : "PENDENTI";
   string title = StringFormat("Apertura Rapida [%s] - %d Posizioni (1/%d lotti)  [R = prezzo live]",
                               modo, n, n);
   if(ObjectFind(0,PREFIX+"qk_title")>=0)
      ObjectSetString(0,PREFIX+"qk_title",OBJPROP_TEXT,title);
}
void RefreshTabButtons()
{
   color onCol  = C'20,100,170';
   color offCol = C'45,45,60';
   if(ObjectFind(0,PREFIX+"qk_tab_p")>=0)
      ObjectSetInteger(0,PREFIX+"qk_tab_p",OBJPROP_BGCOLOR,
                       g_activeTab==0 ? onCol : offCol);
   if(ObjectFind(0,PREFIX+"qk_tab_m")>=0)
      ObjectSetInteger(0,PREFIX+"qk_tab_m",OBJPROP_BGCOLOR,
                       g_activeTab==1 ? onCol : offCol);
}
void DrawActionButtons(int y, int x, int rowH)
{
   // Rimuovi eventuali vecchi bottoni di azione
   string names[] = {"qk_calc","qk_bl","qk_sl2","qk_bs","qk_ss","qk_bm","qk_sm"};
   for(int i=0;i<ArraySize(names);i++)
   {
      string nm = PREFIX+names[i];
      if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm);
   }
   ObjBtn(PREFIX+"qk_calc", x+12, y+4, 96, rowH-10, "CALCOLA", C'60,60,70', 10);
   if(g_activeTab == 0)
   {
      // Tab PENDENTI
      ObjBtn(PREFIX+"qk_bl",  x+114, y+4, 140, rowH-10, "BUY LIMIT",  C'0,110,60',  10);
      ObjBtn(PREFIX+"qk_sl2", x+258, y+4, 140, rowH-10, "SELL LIMIT", C'160,30,30', 10);
      ObjBtn(PREFIX+"qk_bs",  x+402, y+4, 140, rowH-10, "BUY STOP",   C'0,140,80',  10);
      ObjBtn(PREFIX+"qk_ss",  x+546, y+4, 140, rowH-10, "SELL STOP",  C'190,40,40', 10);
   }
   else
   {
      // Tab MERCATO (bottoni grandi)
      ObjBtn(PREFIX+"qk_bm", x+114, y+4, 286, rowH-10, "BUY MARKET",  C'0,180,110', 12);
      ObjBtn(PREFIX+"qk_sm", x+406, y+4, 286, rowH-10, "SELL MARKET", C'220,50,50', 12);
   }
}
void SetActiveTab(int t)
{
   if(t < 0) t = 0;
   if(t > 1) t = 1;
   if(g_activeTab == t) return;
   g_activeTab = t;
   int rowH = 40;
   // Ricava la Y della riga azioni salvata in memoria: ricalcolala come in DrawQuickPanel
   int x  = PanelX, y = PanelY, hdrH=36, tabH=28, presetRowH=30;
   int r4 = y + hdrH + tabH + rowH*3 + presetRowH + 10;
   DrawActionButtons(r4, x, rowH);
   RefreshTabButtons();
   RefreshQuickTitle();
   RefreshLiveControlsVisibility();
   // Sul tab MERCATO il prezzo e' sempre live (non posso comunque scegliere il prezzo)
   if(t == 1) UpdateQuickPrice();
   ChartRedraw(0);
   if(DebugBELogs)
      PrintFormat("[QK] Tab attivo: %s", t==1 ? "MERCATO" : "PENDENTI");
}
void RefreshLiveButton()
{
   if(ObjectFind(0,PREFIX+"qk_rp")<0) return;
   color bg = g_priceLive ? C'0,130,80' : C'60,60,70';
   string txt = g_priceLive ? "R*" : "R";
   ObjectSetInteger(0,PREFIX+"qk_rp",OBJPROP_BGCOLOR,bg);
   ObjectSetString (0,PREFIX+"qk_rp",OBJPROP_TEXT,txt);
}
// Mostra il tasto R (e la label) solo sul tab PENDENTI.
// Sul tab MERCATO il prezzo e' sempre live, quindi R non serve e lo rimuovo.
void RefreshLiveControlsVisibility()
{
   if(g_activeTab == 1)
   {
      // Mercato: elimina R e la label hint se presenti
      if(ObjectFind(0,PREFIX+"qk_rp")>=0)      ObjectDelete(0,PREFIX+"qk_rp");
      if(ObjectFind(0,PREFIX+"qk_rp_hint")>=0) ObjectDelete(0,PREFIX+"qk_rp_hint");
      // Forza live spento logicamente (non serve su mercato, il prezzo si aggiorna sempre)
      g_priceLive = false;
      g_lastLivePriceTxt = "";
   }
   else
   {
      int x=PanelX, y=PanelY, hdrH=36, tabH=28, rowH=40;
      int r1 = y + hdrH + tabH + 6;
      if(ObjectFind(0,PREFIX+"qk_rp")<0)
         ObjBtn(PREFIX+"qk_rp", x+456, r1+4, 32, rowH-10, "R", C'60,60,70', 11);
      if(ObjectFind(0,PREFIX+"qk_rp_hint")<0)
         ObjLabel(PREFIX+"qk_rp_hint", x+494, r1+12, "click = live", 9, clrDarkGray);
      RefreshLiveButton();
   }
}
void SetLivePriceMode(bool on)
{
   g_priceLive = on;
   RefreshLiveButton();
   if(on) UpdateQuickPrice();
   ChartRedraw(0);
   if(DebugBELogs)
      PrintFormat("[QK] Prezzo live %s", on ? "ATTIVO" : "spento");
}
void UpdateQuickPrice()
{
   string sym = ObjGetText(PREFIX+"qk_sym");
   double bid = 0.0, ask = 0.0;
   if(!GetSymbolPrices(sym,bid,ask)) return;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string txt = DoubleToString(bid,digits);
   if(ObjectFind(0,PREFIX+"qk_price")>=0)
   {
      ObjectSetString(0,PREFIX+"qk_price",OBJPROP_TEXT,txt);
      g_lastLivePriceTxt = txt;
   }
   g_lastQuickSymbol = sym;
}
void DrawQuickPanel()
{
   int x=PanelX,y=PanelY,hdrH=36,tabH=28,rowH=40,presetRowH=30;
   int h = hdrH + tabH + rowH*3 + presetRowH + 18;
   g_quickPanelH = h;
   ObjRect(PREFIX+"qk_bg",  x,y,PNL_W,h,C'20,20,32');
   ObjRect(PREFIX+"qk_hdr", x,y,PNL_W,hdrH,C'10,60,120');
   ObjLabel(PREFIX+"qk_title",x+12,y+10,"Apertura Rapida",12,clrWhite);
   // --- Riga TAB: PENDENTI / MERCATO ---
   int ty = y + hdrH;
   ObjRect(PREFIX+"qk_tabs_bg", x, ty, PNL_W, tabH, C'16,16,26');
   int tabW = 160;
   ObjBtn(PREFIX+"qk_tab_p", x+8,       ty+3, tabW, tabH-6, "PENDENTI",
          g_activeTab==0 ? C'20,100,170' : C'45,45,60', 11);
   ObjBtn(PREFIX+"qk_tab_m", x+8+tabW+6,ty+3, tabW, tabH-6, "MERCATO",
          g_activeTab==1 ? C'20,100,170' : C'45,45,60', 11);
   ObjLabel(PREFIX+"qk_tab_hint", x+8+tabW*2+24, ty+7,
            "Clicca per passare da pending a mercato (apertura istantanea)",
            9, clrDarkGray);
   int r1=y+hdrH+tabH+6;
   ObjLabel(PREFIX+"qk_lsym",  x+12, r1+12,"Simbolo",  10,clrSilver);
   // Selettore simbolo: [<] [EDIT] [>] [pos]
   ObjBtn  (PREFIX+"qk_sym_prev", x+72,  r1+4, 24, rowH-10, "<", C'45,70,120', 12);
   ObjEdit (PREFIX+"qk_sym",      x+98,  r1+4, 110, rowH-10, _Symbol);
   ObjBtn  (PREFIX+"qk_sym_next", x+210, r1+4, 24, rowH-10, ">", C'45,70,120', 12);
   ObjLabel(PREFIX+"qk_sym_pos",  x+236, r1+12, "", 9, clrDarkGray);
   ObjLabel(PREFIX+"qk_lprice",x+270,r1+12,"Prezzo",   10,clrSilver);
   int priceDigits = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   ObjEdit (PREFIX+"qk_price", x+320,r1+4,130,rowH-10,
            DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_BID), priceDigits));
   ObjBtn  (PREFIX+"qk_rp",    x+456,r1+4,32,rowH-10,"R",C'60,60,70',11);
   ObjLabel(PREFIX+"qk_rp_hint",x+494,r1+12,"click = live",9,clrDarkGray);
   int r2=r1+rowH+4;
   string slDefault   = DoubleToString(DefaultSlPips, (DefaultSlPips == MathFloor(DefaultSlPips)) ? 0 : 1);
   string riskDefault = DoubleToString(DefaultRiskEur, (DefaultRiskEur == MathFloor(DefaultRiskEur)) ? 0 : 1);
   ObjLabel(PREFIX+"qk_lsl",  x+12, r2+12,"SL pips",     10,clrSilver);
   ObjEdit (PREFIX+"qk_sl",   x+82, r2+4,110,rowH-10, slDefault);
   ObjLabel(PREFIX+"qk_lrisk",x+205,r2+12,"Rischio EUR", 10,clrSilver);
   ObjEdit (PREFIX+"qk_risk", x+300,r2+4,110,rowH-10, riskDefault);
   ObjLabel(PREFIX+"qk_llots",x+425,r2+12,"Lotti tot:",  10,clrSilver);
   ObjLabel(PREFIX+"qk_lots", x+510,r2+12,"---",         12,clrYellow);
   // --- Riga N. Ordini + preset ---
   int r3=r2+rowH+4;
   ObjLabel(PREFIX+"qk_lcnt", x+12, r3+8,"N. Ordini",    10,clrSilver);
   int cntDefault = (DefaultQuickCount>0 && DefaultQuickCount<=MAX_QUICK_COUNT) ? DefaultQuickCount : 3;
   ObjEdit (PREFIX+"qk_cnt",  x+82, r3+2,60, presetRowH-4, IntegerToString(cntDefault), 11);
   // Pulisci eventuali vecchi bottoni preset
   for(int i=0;i<MAX_QUICK_COUNT;i++)
   {
      string nm = PREFIX+"qk_pre_"+IntegerToString(i);
      if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm);
   }
   int px = x + 160;
   int pw = 44;
   int pgap = 6;
   for(int i=0;i<g_presetCount;i++)
   {
      string nm = PREFIX+"qk_pre_"+IntegerToString(i);
      string lbl = IntegerToString(g_presetCounts[i]);
      ObjBtn(nm, px, r3+2, pw, presetRowH-4, lbl, C'45,70,120', 10);
      px += pw + pgap;
   }
   ObjLabel(PREFIX+"qk_cnt_hint", px+8, r3+8,"preset: modifica N o clicca", 9, clrDarkGray);
   int r4=r3+presetRowH+6;
   DrawActionButtons(r4, x, rowH);
   RefreshQuickTitle();
   RefreshLiveButton();
   RefreshTabButtons();
   RefreshSymbolLabel();
   RefreshLiveControlsVisibility();
   ChartRedraw(0);
}
void UpdateLotsLabel()
{
   string sym  = ObjGetText(PREFIX+"qk_sym");
   double slP  = StringToDouble(ObjGetText(PREFIX+"qk_sl"));
   double risk = StringToDouble(ObjGetText(PREFIX+"qk_risk"));
   int    n    = GetQuickCount();
   SymbolSelect(sym,true);
   double lots = CalcLots(sym,slP,risk);
   string txt;
   if(lots > 0.0)
   {
      double one = NormalizeDouble(lots/(double)n, 2);
      txt = StringFormat("%.2f (%.2f x%d)", lots, one, n);
   }
   else txt = "Errore simbolo";
   if(ObjectFind(0,PREFIX+"qk_lots")>=0)
      ObjectSetString(0,PREFIX+"qk_lots",OBJPROP_TEXT,txt);
   ChartRedraw(0);
}
string ComputePendingSignature()
{
   string s = "";
   int total = OrdersTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0||!OrderSelect(ticket))continue;
      s += StringFormat("%I64u|%d|%.5f|%.2f|%.5f|%.5f;",
                        ticket,
                        (int)OrderGetInteger(ORDER_TYPE),
                        OrderGetDouble(ORDER_PRICE_OPEN),
                        OrderGetDouble(ORDER_VOLUME_CURRENT),
                        OrderGetDouble(ORDER_SL),
                        OrderGetDouble(ORDER_TP));
   }
   return s;
}
void DrawPendingPanel()
{
   ObjectsDeleteAll(0,PREFIX+"pnd_");
   int total=OrdersTotal();
   int hdrH=34,panelH=hdrH+MathMax(total,1)*ROW_H+12;
   int py=PanelY+g_quickPanelH+10;
   ObjRect(PREFIX+"pnd_bg", PanelX,py,PNL_W,panelH,C'20,20,32');
   ObjRect(PREFIX+"pnd_hdr",PanelX,py,PNL_W,hdrH,C'10,50,100');
   ObjLabel(PREFIX+"pnd_title",PanelX+12,py+10,"Ordini Pendenti",12,clrWhite);
   if(total==0)
   {
      ObjLabel(PREFIX+"pnd_empty",PanelX+12,py+hdrH+10,"Nessun ordine pendente.",10,clrGray);
      g_pendingSignature = ComputePendingSignature();
      int qkY0 = PanelY + 36 + 28 + 40*3 + 30 + 10;
      DrawActionButtons(qkY0, PanelX, 40);
      ChartRedraw(0);return;
   }
   int hy=py+hdrH+4;
   ObjLabel(PREFIX+"pnd_h1",PanelX+12, hy,"Ticket", 10,clrSilver);
   ObjLabel(PREFIX+"pnd_h2",PanelX+120,hy,"Simbolo",10,clrSilver);
   ObjLabel(PREFIX+"pnd_h3",PanelX+230,hy,"Tipo",   10,clrSilver);
   ObjLabel(PREFIX+"pnd_h4",PanelX+340,hy,"Prezzo", 10,clrSilver);
   ObjLabel(PREFIX+"pnd_h5",PanelX+480,hy,"Lotti",  10,clrSilver);
   ObjLabel(PREFIX+"pnd_h6",PanelX+585,hy,"Azioni", 10,clrSilver);
   for(int i=0;i<total;i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0||!OrderSelect(ticket))continue;
      string sym=OrderGetString(ORDER_SYMBOL);
      ENUM_ORDER_TYPE ot=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double price=OrderGetDouble(ORDER_PRICE_OPEN);
      double lots=OrderGetDouble(ORDER_VOLUME_CURRENT);
      int digs=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      string tstr=(ot==ORDER_TYPE_BUY_LIMIT) ?"Buy Limit":
                  (ot==ORDER_TYPE_SELL_LIMIT)?"Sell Limit":
                  (ot==ORDER_TYPE_BUY_STOP)  ?"Buy Stop":
                  (ot==ORDER_TYPE_SELL_STOP) ?"Sell Stop":"?";
      color tclr=(ot==ORDER_TYPE_BUY_LIMIT||ot==ORDER_TYPE_BUY_STOP)?clrLimeGreen:clrTomato;
      int ry=py+hdrH+ROW_H*(i+1);
      string tkstr = IntegerToString((long)ticket);
      ObjRect(PREFIX+"pnd_row_"+tkstr,PanelX,ry,PNL_W,ROW_H-2,
              i%2==0?C'28,28,40':C'22,22,34');
      ObjLabel(PREFIX+"pnd_tk_"+tkstr,PanelX+12, ry+8,tkstr,10,clrWhite);
      ObjLabel(PREFIX+"pnd_sy_"+tkstr,PanelX+120,ry+8,sym,10,clrWhite);
      ObjLabel(PREFIX+"pnd_tp_"+tkstr,PanelX+230,ry+8,tstr,10,tclr);
      ObjEdit (PREFIX+"pnd_ep_"+tkstr,PanelX+330,ry+3,130,ROW_H-8,DoubleToString(price,digs));
      ObjEdit (PREFIX+"pnd_el_"+tkstr,PanelX+470,ry+3,90, ROW_H-8,DoubleToString(lots,2));
      ObjBtn  (PREFIX+"pnd_mod_"+tkstr,PanelX+570,ry+3,54,ROW_H-8,"MOD",C'30,100,180',10);
      ObjBtn  (PREFIX+"pnd_del_"+tkstr,PanelX+630,ry+3,54,ROW_H-8,"DEL",C'160,30,30',10);
   }
   g_pendingSignature = ComputePendingSignature();
   // Ri-disegno i bottoni del tab attivo per assicurarmi che restino in primo piano
   // (ObjectsDeleteAll del pannello pending crea nuovi oggetti che altrimenti
   //  possono sovrapporsi ai tasti BUY/SELL MARKET).
   int qkY = PanelY + 36 + 28 + 40*3 + 30 + 10; // hdrH + tabH + 3*rowH + presetRowH + 10
   DrawActionButtons(qkY, PanelX, 40);
   ChartRedraw(0);
}
void HandleQuickPanel(const string obj)
{
   ObjResetBtn(obj);
   // --- Tab click ---
   if(obj==PREFIX+"qk_tab_p"){ SetActiveTab(0); return; }
   if(obj==PREFIX+"qk_tab_m"){ SetActiveTab(1); return; }
   // --- Selettore simbolo < > ---
   if(obj==PREFIX+"qk_sym_prev"){ ApplySymbolFromList(g_mainSymbolsIdx - 1); return; }
   if(obj==PREFIX+"qk_sym_next"){ ApplySymbolFromList(g_mainSymbolsIdx + 1); return; }
   // --- Preset click: imposta N e ricalcola ---
   string presetPrefix = PREFIX+"qk_pre_";
   if(StringFind(obj,presetPrefix)==0)
   {
      int idx = (int)StringToInteger(StringSubstr(obj,StringLen(presetPrefix)));
      if(idx>=0 && idx<g_presetCount)
         SetQuickCount(g_presetCounts[idx]);
      return;
   }
   if(obj==PREFIX+"qk_calc"){UpdateLotsLabel();return;}
   if(obj==PREFIX+"qk_rp")
   {
      // Toggle modalita' prezzo live
      SetLivePriceMode(!g_priceLive);
      return;
   }
   string sym  = ObjGetText(PREFIX+"qk_sym");
   double price= StringToDouble(ObjGetText(PREFIX+"qk_price"));
   double slP  = StringToDouble(ObjGetText(PREFIX+"qk_sl"));
   double risk = StringToDouble(ObjGetText(PREFIX+"qk_risk"));
   int    n    = GetQuickCount();
   SymbolSelect(sym,true);
   double lots = CalcLots(sym,slP,risk);
   if(lots<=0.0)
   {
      // Auto-calcolo: se i parametri sono validi, calcoliamo al volo
      Print("[OPEN] Lotti non validi. Verifica SL pips e Rischio EUR.");
      UpdateLotsLabel();
      return;
   }
   ENUM_ORDER_TYPE otype;
   if     (obj==PREFIX+"qk_bl")  otype=ORDER_TYPE_BUY_LIMIT;
   else if(obj==PREFIX+"qk_sl2") otype=ORDER_TYPE_SELL_LIMIT;
   else if(obj==PREFIX+"qk_bs")  otype=ORDER_TYPE_BUY_STOP;
   else if(obj==PREFIX+"qk_ss")  otype=ORDER_TYPE_SELL_STOP;
   else if(obj==PREFIX+"qk_bm")  otype=ORDER_TYPE_BUY;
   else if(obj==PREFIX+"qk_sm")  otype=ORDER_TYPE_SELL;
   else return;
   OpenNOrders(sym,otype,price,slP,lots,n);
   Sleep(300);
   DrawPendingPanel();
   UpdateLotsLabel();
}
void HandlePendingModify(const string obj)
{
   ObjResetBtn(obj);
   string p = PREFIX+"pnd_mod_";
   ulong ticket=(ulong)StringToInteger(StringSubstr(obj,StringLen(p)));
   if(ticket==0||!OrderSelect(ticket))
   {
      PrintFormat("[PND] MOD: ticket %I64u non trovato",ticket);
      return;
   }
   string sym    = OrderGetString(ORDER_SYMBOL);
   ENUM_ORDER_TYPE ot=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   double curPrice=OrderGetDouble(ORDER_PRICE_OPEN);
   double curVol = OrderGetDouble(ORDER_VOLUME_CURRENT);
   double curSL  = OrderGetDouble(ORDER_SL);
   double curTP  = OrderGetDouble(ORDER_TP);
   long   magic  = OrderGetInteger(ORDER_MAGIC);
   string comment= OrderGetString(ORDER_COMMENT);
   int digs=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   string tkstr = IntegerToString((long)ticket);
   string epText = ObjGetText(PREFIX+"pnd_ep_"+tkstr);
   string elText = ObjGetText(PREFIX+"pnd_el_"+tkstr);
   double newP = StringToDouble(epText);
   double newL = StringToDouble(elText);
   PrintFormat("[PND] MOD #%I64u: prezzo='%s'->%.5f (era %.5f), lotti='%s'->%.2f (era %.2f)",
               ticket, epText, newP, curPrice, elText, newL, curVol);
   if(newP<=0.0||newL<=0.0){Print("[PND] Valori non validi, annullo.");return;}
   double lotStep=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   if(lotStep<=0.0) lotStep=0.01;
   newL = NormalizeDouble(MathRound(newL/lotStep)*lotStep,2);
   newP = NormalizeDouble(newP,digs);
   double point = SymbolInfoDouble(sym,SYMBOL_POINT);
   bool priceChanged = MathAbs(newP - curPrice) > point/2.0;
   bool volChanged   = MathAbs(newL - curVol)  > lotStep/2.0;
   if(!priceChanged && !volChanged)
   {
      PrintFormat("[PND] #%I64u nessun cambio rilevato.",ticket);
      return;
   }
   if(!volChanged)
   {
      MqlTradeRequest req={}; MqlTradeResult res={};
      req.action    = TRADE_ACTION_MODIFY;
      req.order     = ticket;
      req.price     = newP;
      req.sl        = NormalizeDouble(curSL,digs);
      req.tp        = NormalizeDouble(curTP,digs);
      req.type_time = ORDER_TIME_GTC;
      bool ok=OrderSend(req,res);
      if(ok && res.retcode==TRADE_RETCODE_DONE)
         PrintFormat("[PND] #%I64u prezzo %.5f -> %.5f OK",ticket,curPrice,newP);
      else
      {
         PrintFormat("[PND] #%I64u MOD prezzo FALLITO retcode=%d comment='%s'",
                     ticket,res.retcode,res.comment);
         return;
      }
   }
   else
   {
      MqlTradeRequest dreq={}; MqlTradeResult dres={};
      dreq.action = TRADE_ACTION_REMOVE;
      dreq.order  = ticket;
      bool dok = OrderSend(dreq,dres);
      if(!dok || dres.retcode!=TRADE_RETCODE_DONE)
      {
         PrintFormat("[PND] #%I64u DELETE FALLITO retcode=%d comment='%s'",
                     ticket,dres.retcode,dres.comment);
         return;
      }
      RemoveTicketFromConfig(ticket);
      MqlTradeRequest req={}; MqlTradeResult res={};
      req.action    = TRADE_ACTION_PENDING;
      req.symbol    = sym;
      req.type      = ot;
      req.price     = newP;
      req.volume    = newL;
      req.sl        = NormalizeDouble(curSL,digs);
      req.tp        = NormalizeDouble(curTP,digs);
      req.type_time = ORDER_TIME_GTC;
      req.magic     = magic;
      req.comment   = comment;
      bool ok=OrderSend(req,res);
      if(ok && (res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_PLACED))
         PrintFormat("[PND] #%I64u ricreato come #%I64u lotti %.2f->%.2f prezzo %.5f->%.5f",
                     ticket,res.order,curVol,newL,curPrice,newP);
      else
      {
         PrintFormat("[PND] ricreazione FALLITA retcode=%d comment='%s'",res.retcode,res.comment);
         return;
      }
   }
   Sleep(200);
   ReconcileConfigFile();
   DrawPendingPanel();
}
void HandlePendingDelete(const string obj)
{
   ObjResetBtn(obj);
   string p = PREFIX+"pnd_del_";
   ulong ticket=(ulong)StringToInteger(StringSubstr(obj,StringLen(p)));
   if(ticket==0||!OrderSelect(ticket))return;
   if(g_trade.OrderDelete(ticket))
      RemoveTicketFromConfig(ticket);
   Sleep(200);
   ReconcileConfigFile();
   DrawPendingPanel();
}
int OnInit()
{
   g_trade.SetAsyncMode(false);
   g_configCount=0; ArrayResize(g_configs,0);
   g_pendingSignature="";
   g_lastQuickSymbol="";
   g_priceLive=false;
   g_lastLivePriceTxt="";
   g_activeTab=0;
   ParsePresetCounts();
   ParseMainSymbols();
   // Imposta indice iniziale del selettore simbolo sul simbolo corrente del chart, se presente in lista
   int sidx = FindSymbolIndex(_Symbol);
   g_mainSymbolsIdx = (sidx >= 0) ? sidx : 0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong t=PositionGetTicket(i);
      if(t==0||!PositionSelectByTicket(t))continue;
      SymbolSelect(PositionGetString(POSITION_SYMBOL),true);
   }
   LoadConfig();
   ReconcileConfigFile();
   DrawQuickPanel();
   UpdateQuickPrice();
   UpdateLotsLabel();
   DrawPendingPanel();
   EventSetTimer(1);
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   PrintFormat("BreakEvenManager v9.00 avviato. Config: %s | Ordini default: %d | SL=%.0f pips | Rischio=%.0f EUR",
               ConfigFile, DefaultQuickCount, DefaultSlPips, DefaultRiskEur);
   PrintFormat("TP automatico per posizione: 1a=1:%.0f, 2a=1:%.0f, 3a=1:%.0f",
               RR_Position1, RR_Position2, RR_Position3);
   Print("Formato BE: 123456=17:30  oppure  123456=NO  oppure  123456=17:30|nota");
   Print("Tasto R nel pannello = prezzo live ON/OFF (sul tab MERCATO sempre attivo).");
   Print("Tab PENDENTI / MERCATO nel pannello per cambiare modalita' di apertura rapida.");
   PrintFormat("Selettore simboli ( < > ) con %d mercati: %s", g_mainSymbolsCount, MainSymbols);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0,PREFIX);
}
void OnTimer()
{
   ReconcileConfigFile();
   LoadConfig();
   string sig = ComputePendingSignature();
   if(sig != g_pendingSignature)
      DrawPendingPanel();
   // Sul tab MERCATO il prezzo e' sempre live; sul tab PENDENTI solo se R e' attivo
   if(g_activeTab == 1 || g_priceLive)
      UpdateQuickPrice();
   ProcessBreakEvenAllSymbols();
}
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(AutoAddTicketsToConfig)
   {
      if(trans.type==TRADE_TRANSACTION_ORDER_ADD && trans.order!=0)
      {
         if(OrderSelect(trans.order))
         {
            ENUM_ORDER_TYPE ot=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            if(ot==ORDER_TYPE_BUY_LIMIT||ot==ORDER_TYPE_SELL_LIMIT||
               ot==ORDER_TYPE_BUY_STOP ||ot==ORDER_TYPE_SELL_STOP)
            {
               AppendTicketToConfig(trans.order, DefaultBEValue);
               DrawPendingPanel();
            }
         }
      }
      if(trans.type==TRADE_TRANSACTION_DEAL_ADD && trans.deal!=0)
      {
         if(HistoryDealSelect(trans.deal))
         {
            ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
            if(entry==DEAL_ENTRY_IN)
            {
               ulong pos=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
               if(pos!=0) AppendTicketToConfig(pos, DefaultBEValue);
            }
         }
      }
   }
   if(AutoRemoveCanceledTickets &&
      trans.type==TRADE_TRANSACTION_HISTORY_ADD && trans.order!=0)
   {
      if(HistoryOrderSelect(trans.order))
      {
         ENUM_ORDER_STATE st=(ENUM_ORDER_STATE)HistoryOrderGetInteger(trans.order,ORDER_STATE);
         if(st==ORDER_STATE_CANCELED || st==ORDER_STATE_REJECTED || st==ORDER_STATE_EXPIRED)
            RemoveTicketFromConfig(trans.order);
      }
   }
}
void OnChartEvent(const int id,const long &lparam,
                  const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_CLICK)
   {
      if(StringFind(sparam,PREFIX+"pnd_mod_")>=0)      HandlePendingModify(sparam);
      else if(StringFind(sparam,PREFIX+"pnd_del_")>=0) HandlePendingDelete(sparam);
      else if(StringFind(sparam,PREFIX+"qk_")>=0)      HandleQuickPanel(sparam);
      return;
   }
   if(id==CHARTEVENT_OBJECT_ENDEDIT)
   {
      if(sparam==PREFIX+"qk_sym")
      {
         string newSym = ObjGetText(PREFIX+"qk_sym");
         if(newSym != g_lastQuickSymbol)
         {
            UpdateQuickPrice();
            g_lastQuickSymbol = newSym;
         }
         UpdateLotsLabel();
      }
      else if(sparam==PREFIX+"qk_price")
      {
         // L'utente ha modificato il prezzo manualmente -> disattivo live mode
         string cur = ObjGetText(PREFIX+"qk_price");
         if(cur != g_lastLivePriceTxt && g_priceLive)
         {
            SetLivePriceMode(false);
            if(DebugBELogs)
               Print("[QK] Prezzo modificato manualmente -> live OFF.");
         }
      }
      else if(sparam==PREFIX+"qk_cnt")
      {
         int n = GetQuickCount();
         SetQuickCount(n);
      }
      else if(sparam==PREFIX+"qk_sl"||sparam==PREFIX+"qk_risk")
         UpdateLotsLabel();
   }
   if(id==CHARTEVENT_KEYDOWN)
   {
      // Scorciatoia da tastiera: R attiva/disattiva prezzo live
      if(lparam==82 /*R*/)
         SetLivePriceMode(!g_priceLive);
   }
}
void OnTick()
{
   if(g_activeTab == 1 || g_priceLive) UpdateQuickPrice();
   ProcessBreakEvenAllSymbols();
}
//+------------------------------------------------------------------+