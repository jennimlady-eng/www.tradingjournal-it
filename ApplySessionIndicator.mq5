//+------------------------------------------------------------------+
//|                                    ApplySessionIndicator.mq5     |
//|   Script: applica SessionIndicator su tutti i grafici aperti     |
//|   con simboli nella lista consentita.                            |
//|   Lancia questo script UNA VOLTA per applicare ovunque.          |
//+------------------------------------------------------------------+
#property copyright   "SessionIndicator"
#property link        ""
#property version     "1.00"
#property script_show_inputs

input string AllowedSymbols = "EURUSD,USDJPY,GBPJPY,GBPNZD,GBPCAD,GBPAUD,EURJPY,EURAUD,CADJPY,AUDUSD,AUDJPY";

//+------------------------------------------------------------------+
//| Controlla se un simbolo e' nella lista                           |
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
//| OnStart - eseguito una volta                                     |
//+------------------------------------------------------------------+
void OnStart()
{
   int count = 0;
   int skipped = 0;

   long cid = ChartFirst();
   while(cid >= 0)
   {
      string sym = ChartSymbol(cid);
      if(IsSymbolInList(sym))
      {
         // Controlla se l'indicatore e' gia presente
         bool found = false;
         int total = ChartIndicatorsTotal(cid, 0);
         for(int j = 0; j < total; j++)
         {
            string indName = ChartIndicatorName(cid, 0, j);
            if(StringFind(indName, "SessionIndicator") >= 0)
            { found = true; break; }
         }

         if(!found)
         {
            int h = iCustom(sym, ChartPeriod(cid), "SessionIndicator");
            if(h != INVALID_HANDLE)
            {
               if(ChartIndicatorAdd(cid, 0, h))
               {
                  count++;
                  Print("SessionIndicator aggiunto su ", sym,
                        " (", EnumToString(ChartPeriod(cid)), ")");
               }
            }
            else
            {
               Print("Errore creazione handle per ", sym, ": ", GetLastError());
            }
         }
         else
         {
            skipped++;
         }
      }
      cid = ChartNext(cid);
   }

   string msg = "SessionIndicator applicato su " + IntegerToString(count) + " grafici";
   if(skipped > 0)
      msg += " (" + IntegerToString(skipped) + " gia' presenti)";
   Print(msg);
   Alert(msg);
}
//+------------------------------------------------------------------+
