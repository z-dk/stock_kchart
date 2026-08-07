import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:k_chart/flutter_k_chart.dart';

import 'data_source.dart';
import '../models/stock_quote.dart';
import '../services/storage_service.dart';

/// Finnhub data source — global equities, ADRs, Hong Kong, Chinese ADRs.
///
/// Uses the free tier (60 calls/min, delayed data):
///  * Realtime quote:    GET /quote?symbol=AAPL&token=xxx
///  * Historical candles: GET /stock/candle?symbol=AAPL&resolution=D&from=...&to=...&token=xxx
///
/// A Finnhub API key is required. Sign up at https://finnhub.io/register
/// (free tier, 60 calls/min).
///
/// Supported symbol formats:
///  * US stocks: 'AAPL', 'TSLA', 'MSFT'
///  * ADRs:      '600519.SS' (Shanghai), '000001.SZ' (Shenzhen)
///  * HK stocks: '00700.HK'
class FinnhubDataSource implements DataSource {
  FinnhubDataSource._();
  static final FinnhubDataSource instance = FinnhubDataSource._();

  @override
  String get id => 'finnhub';

  @override
  String get displayName => 'Finnhub (全球)';

  @override
  String get description => '全球股票行情，需 API Key（免费 60 次/分）';

  @override
  List<String> get supportedMarkets =>
      const <String>['US', 'CN', 'HK', 'IN', 'EU'];

  @override
  bool get requiresApiKey => true;

  static const String _quoteUrl = 'https://finnhub.io/api/v1/quote';
  static const String _candleUrl = 'https://finnhub.io/api/v1/stock/candle';
  static const Duration _timeout = Duration(seconds: 10);

  final _storage = StorageService.instance;

  /// Default keys loaded from `assets/config/default_keys.json`.
  /// This file is listed in .gitignore so it never enters version control.
  /// The .example file (default_keys.json.example) is committed as a template.
  String? _defaultKey;
  bool _keysLoaded = false;

  Future<void> _loadDefaultKeys() async {
    if (_keysLoaded) return;
    try {
      final raw = await rootBundle
          .loadString('assets/config/default_keys.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final k = json['finnhub'] as String?;
      if (k != null && k.isNotEmpty && !k.startsWith('YOUR_')) {
        _defaultKey = k;
      }
    } catch (_) {
      // File not found or invalid — silently leave _defaultKey as null.
    }
    _keysLoaded = true;
  }

  /// Returns the user-configured API key, the shipped default key from
  /// assets, or `null` if neither is available.
  Future<String?> _getApiKey() async {
    final userKey = await _storage.getApiKey('finnhub');
    if (userKey != null && userKey.isNotEmpty) return userKey;
    await _loadDefaultKeys();
    return _defaultKey;
  }

  void _requireApiKey(String symbol) {
    throw StateError(
      'Finnhub API key not configured. Please add one in Settings. '
      'Symbol: $symbol',
    );
  }

  @override
  String normalizeSymbol(String input) {
    final s = input.trim().toUpperCase();

    // If already in Finnhub format (contains .SS, .SZ, .HK, or is a ticker)
    if (s.contains('.') || RegExp(r'^[A-Z]{1,6}$').hasMatch(s)) {
      return s;
    }

    // If a 6-digit code, convert to A-share ADR format
    final digits = s.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 6) {
      final first = digits[0];
      if (first == '6' || first == '9') {
        return '$digits.SS';
      } else {
        return '$digits.SZ';
      }
    }

    return s;
  }

  @override
  Future<StockQuote?> fetchRealtime(String symbol) async {
    final normalizedSymbol = normalizeSymbol(symbol);
    final apiKey = await _getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      _requireApiKey(normalizedSymbol);
    }

    final uri = Uri.parse('$_quoteUrl?symbol=$normalizedSymbol&token=$apiKey');
    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode == 429) {
      throw Exception('Finnhub rate limit exceeded (60 calls/min).');
    }
    if (response.statusCode == 403) {
      throw Exception(
        'Finnhub 访问被拒绝 (HTTP 403)。可能原因：\n'
        '1. API Key 无效或已过期\n'
        '2. 免费套餐不支持此功能\n'
        '请检查 API Key 或升级套餐。',
      );
    }
    if (response.statusCode != 200) {
      throw http.ClientException(
        'finnhub quote HTTP ${response.statusCode} for $normalizedSymbol',
        uri,
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;

    // Finnhub returns empty object {} for unknown symbols → not an error.
    if (decoded.isEmpty || decoded['c'] == null) return null;

    return StockQuote.fromFinnhub(normalizedSymbol, decoded);
  }

  @override
  Future<List<KLineEntity>> fetchKline(
    String symbol, {
    required int scale,
    int datalen = 300,
  }) async {
    final normalizedSymbol = normalizeSymbol(symbol);
    final apiKey = await _getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      _requireApiKey(normalizedSymbol);
    }

    // Map minutes → Finnhub resolution string.
    final resolution = _mapResolution(scale);
    if (resolution == null) {
      throw ArgumentError(
        'Unsupported scale $scale for Finnhub. '
        'Supported: 1, 5, 15, 30, 60 (intraday), 240 (daily).',
      );
    }

    // Fetch from `datalen` candles back to now.
    final now = DateTime.now();
    final from = _calcFromTime(now, scale, datalen);
    final to = now.millisecondsSinceEpoch ~/ 1000;

    final uri = Uri.parse(
      '$_candleUrl?symbol=$normalizedSymbol&resolution=$resolution&from=$from&to=$to&token=$apiKey',
    );

    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode == 429) {
      throw Exception('Finnhub rate limit exceeded (60 calls/min).');
    }
    if (response.statusCode == 403) {
      throw Exception(
        'Finnhub K 线数据访问被拒绝 (HTTP 403)。\n\n'
        '原因：Finnhub 免费套餐不支持 /stock/candle 接口。\n\n'
        '解决方案：\n'
        '1. 升级 Finnhub 付费套餐以获取 K 线数据\n'
        '2. 或切换到"新浪"数据源（支持 A 股 K 线）',
      );
    }
    if (response.statusCode != 200) {
      throw http.ClientException(
        'finnhub candle HTTP ${response.statusCode} for $normalizedSymbol',
        uri,
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final status = decoded['s'] as String?;

    if (status == 'no_data' || status == null) return <KLineEntity>[];

    final times = decoded['t'] as List<dynamic>? ?? const <dynamic>[];
    final opens = decoded['o'] as List<dynamic>? ?? const <dynamic>[];
    final highs = decoded['h'] as List<dynamic>? ?? const <dynamic>[];
    final lows = decoded['l'] as List<dynamic>? ?? const <dynamic>[];
    final closes = decoded['c'] as List<dynamic>? ?? const <dynamic>[];
    final volumes = decoded['v'] as List<dynamic>? ?? const <dynamic>[];

    final int count = times.length;
    final result = <KLineEntity>[];
    for (int i = 0; i < count; i++) {
      final open = (opens[i] as num?)?.toDouble() ?? 0;
      final high = (highs[i] as num?)?.toDouble() ?? 0;
      final low = (lows[i] as num?)?.toDouble() ?? 0;
      final close = (closes[i] as num?)?.toDouble() ?? 0;
      final volume = (volumes[i] as num?)?.toDouble() ?? 0;
      if (open == 0 && close == 0) continue;

      result.add(
        KLineEntity.fromCustom(
          open: open,
          high: high,
          low: low,
          close: close,
          vol: volume,
          amount: volume,
          time: (times[i] as int) * 1000, // Finnhub returns seconds → ms
        ),
      );
    }
    return result;
  }

  /// Map minute-based scale → Finnhub resolution string.
  static String? _mapResolution(int scale) {
    switch (scale) {
      case 1:
        return '1';
      case 5:
        return '5';
      case 15:
        return '15';
      case 30:
        return '30';
      case 60:
      case 240:
        return '60';
      default:
        return null;
    }
  }

  /// Calculate the UNIX timestamp (seconds) for `datalen` candles back.
  static int _calcFromTime(DateTime now, int scale, int datalen) {
    final minutes = scale * datalen;
    final from = now.subtract(Duration(minutes: minutes));
    return from.millisecondsSinceEpoch ~/ 1000;
  }
}
