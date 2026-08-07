// Unit tests for the pure (network-free) parts of the Sina integration.

import 'package:flutter_test/flutter_test.dart';
import 'package:stock_kchart/models/stock_quote.dart';
import 'package:stock_kchart/services/sina_api_service.dart';

void main() {
  group('StockQuote.fromSina', () {
    test('parses a well-formed realtime line', () {
      // Full 33-field Sina response (name, OHLC, bid/ask, vol, amount,
      // 5-level bid×ask vol/price pairs, date, time, status).
      const line = 'var hq_str_sh600519="贵州茅台,1310.000,1306.450,1308.550,'
          '1314.400,1300.010,1308.550,1308.580,2546328,3326230801.000,'
          '7983,1308.550,7983,1308.580,7983,1308.590,7983,1308.600,7983,'
          '1308.610,7983,1308.620,7983,1308.630,7983,1308.640,7983,'
          '1308.650,7983,1308.660,2026-08-06,15:00:00,00";';
      final q = StockQuote.fromSina('sh600519', line);
      expect(q, isNotNull);
      expect(q!.name, '贵州茅台');
      expect(q.open, 1310.000);
      expect(q.prevClose, 1306.450);
      expect(q.current, 1308.550);
      expect(q.high, 1314.400);
      expect(q.low, 1300.010);
      expect(q.volume, 2546328);
      expect(q.amount, 3326230801.000);
      expect(q.date, '2026-08-06');
      expect(q.time, '15:00:00');
      expect(q.change, closeTo(2.10, 0.001));
      expect(q.isUp, isTrue);
    });

    test('returns null for an empty (suspended) response', () {
      const empty = 'var hq_str_sh000001="";';
      expect(StockQuote.fromSina('sh000001', empty), isNull);
    });
  });

  group('SinaApiService.normalizeSymbol', () {
    test('auto-prefixes Shanghai and Shenzhen codes', () {
      expect(SinaApiService.normalizeSymbol('600519'), 'sh600519');
      expect(SinaApiService.normalizeSymbol('000001'), 'sz000001');
      expect(SinaApiService.normalizeSymbol('300750'), 'sz300750');
      expect(SinaApiService.normalizeSymbol('688981'), 'sh688981');
    });

    test('preserves an explicit prefix and trims/case-folds', () {
      expect(SinaApiService.normalizeSymbol('  SH600519 '), 'sh600519');
      expect(SinaApiService.normalizeSymbol('sz000001'), 'sz000001');
    });
  });
}
