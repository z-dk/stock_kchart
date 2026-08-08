// Unit tests for the pure (network-free) parts of the Eastmoney integration.

import 'package:flutter_test/flutter_test.dart';
import 'package:stock_kchart/data_sources/eastmoney_data_source.dart';
import 'package:stock_kchart/models/stock_quote.dart';

void main() {
  group('StockQuote.fromEastmoney', () {
    test('parses a well-formed realtime quote response', () {
      // Mirrors the Eastmoney push2 stock/get JSON (field codes).
      const json = <String, dynamic>{
        'f43': 1308.55, // latest
        'f44': 1314.40, // high
        'f45': 1300.01, // low
        'f46': 1310.00, // open
        'f47': 2546328, // volume
        'f48': 3326230801.0, // amount
        'f57': '600519',
        'f58': '贵州茅台',
        'f60': 1306.45, // prevClose
        'f169': 2.10, // change
        'f170': 0.16, // changePct
      };
      final q = StockQuote.fromEastmoney('1.600519', json);
      expect(q, isNotNull);
      expect(q.name, '贵州茅台');
      expect(q.current, 1308.55);
      expect(q.open, 1310.00);
      expect(q.high, 1314.40);
      expect(q.low, 1300.01);
      expect(q.prevClose, 1306.45);
      expect(q.volume, 2546328);
      expect(q.amount, 3326230801.0);
      expect(q.change, 2.10);
      expect(q.changePercent, 0.16);
      expect(q.isUp, isTrue);
    });

    test('handles missing fields gracefully (all zeros)', () {
      final q = StockQuote.fromEastmoney('1.600519', <String, dynamic>{});
      expect(q.current, 0);
      expect(q.name, '');
    });
  });

  group('EastmoneyDataSource.normalizeSymbol', () {
    final ds = EastmoneyDataSource.instance;

    test('auto-prefixes Shanghai and Shenzhen codes', () {
      expect(ds.normalizeSymbol('600519'), '1.600519'); // SH
      expect(ds.normalizeSymbol('000001'), '0.000001'); // SZ
      expect(ds.normalizeSymbol('300750'), '0.300750'); // SZ ChiNext
      expect(ds.normalizeSymbol('688981'), '1.688981'); // SH STAR
    });

    test('passes through an explicit secid verbatim (case-sensitive)', () {
      expect(ds.normalizeSymbol('1.600519'), '1.600519');
      expect(ds.normalizeSymbol('116.00700'), '116.00700');
      expect(ds.normalizeSymbol('105.AAPL'), '105.AAPL'); // US case preserved
    });

    test('converts sh/sz-prefixed symbols to secid', () {
      expect(ds.normalizeSymbol('sh600519'), '1.600519');
      expect(ds.normalizeSymbol('SZ000001'), '0.000001');
    });
  });
}
