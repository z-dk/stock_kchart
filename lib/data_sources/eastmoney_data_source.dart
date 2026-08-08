import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:k_chart/flutter_k_chart.dart';

import '../models/stock_quote.dart';
import 'data_source.dart';

/// Eastmoney data source — A-share China market.
///
/// Uses two public endpoints (same ones AkShare uses under the hood):
///  * Real-time quote: `http://push2.eastmoney.com/api/qt/stock/get`
///    Returns JSON with field codes (f43=price, f44=high, etc.).
///  * K-line history: `http://push2his.eastmoney.com/api/qt/stock/kline/get`
///    Returns JSON with `klines` array of comma-separated OHLCV strings.
///
/// Symbol format: `secid` = `<market>.<code>` where market is `0` (Shanghai)
/// or `1` (Shenzhen). For example `0.600519` = 贵州茅台 (SH).
class EastmoneyDataSource implements DataSource {
  EastmoneyDataSource._();
  static final EastmoneyDataSource instance = EastmoneyDataSource._();

  @override
  String get id => 'eastmoney';

  @override
  String get displayName => '东方财富 (A 股)';

  @override
  String get description => '中国 A 股实时行情与 K 线，免费无限制';

  @override
  List<String> get supportedMarkets => const <String>['CN'];

  @override
  bool get requiresApiKey => false;

  static const String _klineUrl =
      'http://push2his.eastmoney.com/api/qt/stock/kline/get';
  static const String _quoteUrl =
      'http://push2.eastmoney.com/api/qt/stock/get';
  static const String _suggestUrl =
      'https://searchapi.eastmoney.com/api/suggest/get';
  static const String _suggestToken = 'D43BF722C8E33BDC906FB84D85E326E8';

  static const Duration _timeout = Duration(seconds: 8);

  @override
  String normalizeSymbol(String input) {
    final s = input.trim().toLowerCase();

    // Already in secid format (e.g. 0.600519).
    if (RegExp(r'^[01]\.\d{6}$').hasMatch(s)) return s;

    // Already prefixed with sh/sz.
    if (s.startsWith('sh') || s.startsWith('sz')) {
      final code = s.substring(2);
      if (code.length == 6 && int.tryParse(code) != null) {
        final prefix = s.startsWith('sh') ? '0' : '1';
        return '$prefix.$code';
      }
    }

    // Strip non-digits to get the 6-digit code.
    final digits = s.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 6) {
      final first = digits[0];
      // 6/9 → Shanghai (secid prefix 0), otherwise Shenzhen (prefix 1).
      final prefix = (first == '6' || first == '9') ? '0' : '1';
      return '$prefix.$digits';
    }

    return s;
  }

  @override
  Future<StockQuote?> fetchRealtime(String symbol) async {
    final uri = Uri.parse(
      '$_quoteUrl?secid=$symbol'
      '&fields=f43,f44,f45,f46,f47,f48,f57,f58,f60,f169,f170'
      '&fltt=2',
    );
    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'eastmoney realtime HTTP ${response.statusCode} for $symbol',
        uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) return null;

    return StockQuote.fromEastmoney(symbol, data);
  }

  @override
  Future<List<KLineEntity>> fetchKline(
    String symbol, {
    required int scale,
    int datalen = 300,
  }) async {
    // Map Sina-style scale (minutes) to Eastmoney klt code.
    // 240 → 101 (daily), others pass through (5/15/30/60).
    final klt = scale >= 240 ? '101' : scale.toString();

    final uri = Uri.parse(
      '$_klineUrl?secid=$symbol&klt=$klt&fqt=1'
      '&fields1=f1,f2,f3,f4,f5,f6'
      '&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61'
      '&beg=0&end=20500101&lmt=$datalen',
    );
    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'eastmoney kline HTTP ${response.statusCode} for $symbol',
        uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return <KLineEntity>[];
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) return <KLineEntity>[];
    final klines = data['klines'];
    if (klines is! List) return <KLineEntity>[];

    final result = <KLineEntity>[];
    for (final raw in klines) {
      final line = raw.toString();
      // Format: 日期,开,收,高,低,量,额,振幅,涨跌幅,涨跌额,换手率
      final parts = line.split(',');
      if (parts.length < 7) continue;

      final open = double.tryParse(parts[1]) ?? 0;
      final close = double.tryParse(parts[2]) ?? 0;
      final high = double.tryParse(parts[3]) ?? 0;
      final low = double.tryParse(parts[4]) ?? 0;
      final volume = double.tryParse(parts[5]) ?? 0;
      if (open == 0 && close == 0) continue;

      result.add(
        KLineEntity.fromCustom(
          open: open,
          high: high,
          low: low,
          close: close,
          vol: volume,
          amount: volume,
          time: _parseTimeMs(parts[0]),
        ),
      );
    }
    return result;
  }

  @override
  Future<List<StockSearchResult>> search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return <StockSearchResult>[];

    final uri = Uri.parse(
      '$_suggestUrl?input=${Uri.encodeComponent(kw)}&type=14&token=$_suggestToken&count=15',
    );

    try {
      final response = await http.get(uri).timeout(_timeout);
      if (response.statusCode != 200) return <StockSearchResult>[];

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return <StockSearchResult>[];

      final table = decoded['QuotationCodeTable'];
      if (table is! Map<String, dynamic>) return <StockSearchResult>[];

      final data = table['Data'];
      if (data is! List) return <StockSearchResult>[];

      final results = <StockSearchResult>[];
      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        final classify = (item['Classify'] ?? '').toString();
        if (classify != 'AStock') continue;
        final result = StockSearchResult.fromEastmoney(item);
        if (result.code.isNotEmpty && result.name.isNotEmpty) {
          results.add(result);
        }
      }
      return results;
    } catch (_) {
      return <StockSearchResult>[];
    }
  }

  static int _parseTimeMs(String day) {
    if (day.isEmpty) return DateTime.now().millisecondsSinceEpoch;
    final dt = DateTime.tryParse(day) ?? DateTime.now();
    return dt.millisecondsSinceEpoch;
  }
}
