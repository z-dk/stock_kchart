import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:k_chart/flutter_k_chart.dart';

import '../models/stock_quote.dart';
import 'data_source.dart';

/// Binance data source — cryptocurrency market.
///
/// Uses Binance's public market-data endpoints (no API key required):
///  * Real-time quote: `https://data-api.binance.vision/api/v3/ticker/24hr`
///    Returns JSON with lastPrice, priceChange, priceChangePercent, etc.
///  * K-line history: `https://data-api.binance.vision/api/v3/klines`
///    Returns an array of OHLCV arrays.
///  * Exchange info: `https://data-api.binance.vision/api/v3/exchangeInfo`
///    Returns all tradeable symbols; cached locally for search filtering.
///
/// `data-api.binance.vision` is Binance's official public market-data
/// endpoint — it serves identical data to `api.binance.com` but does not
/// require an API key and is intended for public consumption.
///
/// Symbol format: the Binance trading-pair symbol (e.g. `BTCUSDT`,
/// `ETHUSDT`). Search is restricted to USDT-quoted pairs for relevance.
class BinanceDataSource implements DataSource {
  BinanceDataSource._();
  static final BinanceDataSource instance = BinanceDataSource._();

  @override
  String get id => 'binance';

  @override
  String get displayName => '币安 (加密货币)';

  @override
  String get description => '加密货币实时行情与 K 线，免费无限制';

  @override
  List<String> get supportedMarkets => const <String>['CRYPTO'];

  @override
  bool get requiresApiKey => false;

  static const String _baseUrl = 'https://data-api.binance.vision';
  static const String _klinePath = '/api/v3/klines';
  static const String _tickerPath = '/api/v3/ticker/24hr';
  static const String _exchangeInfoPath = '/api/v3/exchangeInfo';

  static const Duration _timeout = Duration(seconds: 10);

  /// Only USDT-quoted pairs are exposed via search — this covers virtually
  /// all liquid crypto markets and keeps the result list manageable.
  static const String _quoteAsset = 'USDT';

  /// In-process cache of exchangeInfo symbols, populated on first search.
  /// Each entry is `{symbol, baseAsset, quoteAsset, status}`.
  static List<Map<String, dynamic>>? _symbolCache;

  /// Common Chinese names for the most-traded base assets, used so that
  /// searching "比特币" / "以太坊" lands on the right pair. Assets not
  /// listed here fall back to their English base-asset code (e.g. `AVAX`).
  static const Map<String, String> _zhNames = <String, String>{
    'BTC': '比特币',
    'ETH': '以太坊',
    'BNB': '币安币',
    'SOL': '索拉纳',
    'XRP': '瑞波币',
    'ADA': '艾达币',
    'DOGE': '狗狗币',
    'DOT': '波卡',
    'MATIC': '马蹄币',
    'AVAX': '雪崩',
    'LINK': '链链',
    'UNI': 'UNISWAP',
    'SHIB': '柴犬币',
    'LTC': '莱特币',
    'ATOM': '宇宙',
    'TRX': '波场',
    'ETC': '以太经典',
    'XLM': '恒星币',
    'NEAR': '近协议',
    'FIL': '文件币',
    'ICP': '互联网计算机',
    'APT': '阿普托斯',
    'ARB': '仲裁',
    'OP': '优化',
    'INJ': '注射币',
    'SUI': '苏伊',
    'SEI': 'sei',
    'RUNE': 'THORChain',
    'AAVE': 'Aave',
    'MKR': 'Maker',
    'PEPE': '佩佩',
    'WIF': 'dogwifhat',
    'BONK': 'BONK',
    'FLOKI': 'FLOKI',
    'TON': 'TON',
  };

  /// Pinyin initials for the common Chinese names above, so that searching
  /// e.g. "btb" finds 比特币 (BTC). Kept in sync with [_zhNames].
  static const Map<String, String> _zhPinyin = <String, String>{
    'BTC': 'BTB',
    'ETH': 'YTF',
    'BNB': 'BAB',
    'SOL': 'SLN',
    'XRP': 'RBP',
    'ADA': 'ADB',
    'DOGE': 'GGB',
    'DOT': 'BK',
    'MATIC': 'MTB',
    'AVAX': 'XB',
    'LINK': 'LL',
    'UNI': 'UNI',
    'SHIB': 'CQB',
    'LTC': 'LTB',
    'ATOM': 'YZ',
    'TRX': 'BC',
    'ETC': 'YLJD',
    'XLM': 'HXB',
    'NEAR': 'JXY',
    'FIL': 'WJB',
    'ICP': 'HLWJSJ',
    'APT': 'APT',
    'ARB': 'ZC',
    'OP': 'YH',
    'INJ': 'ZSB',
    'SUI': 'SY',
    'RUNE': 'THOR',
    'PEPE': 'PP',
  };

  @override
  String normalizeSymbol(String input) {
    final s = input.trim().toUpperCase();
    if (s.isEmpty) return s;
    // Already a full Binance pair (e.g. BTCUSDT) — return verbatim.
    if (s.endsWith(_quoteAsset)) return s;
    // Base asset only (e.g. BTC) — append the USDT quote suffix.
    return '$s$_quoteAsset';
  }

  @override
  Future<StockQuote?> fetchRealtime(String symbol) async {
    final pair = normalizeSymbol(symbol);
    final uri = Uri.parse('$_baseUrl$_tickerPath?symbol=$pair');
    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'binance realtime HTTP ${response.statusCode} for $pair',
        uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;

    return StockQuote.fromBinance(pair, decoded);
  }

  @override
  Future<List<KLineEntity>> fetchKline(
    String symbol, {
    required int scale,
    int datalen = 300,
  }) async {
    final pair = normalizeSymbol(symbol);
    // Map the project's minute-based `scale` to Binance interval strings.
    // The app uses 5/15/30/60 intraday and 240 for daily (mirroring Sina /
    // Eastmoney conventions), so 240 → 1d here rather than 4h to keep the
    // "日K" period consistent across data sources.
    final interval = _scaleToInterval(scale);

    final uri = Uri.parse(
      '$_baseUrl$_klinePath?symbol=$pair&interval=$interval&limit=$datalen',
    );
    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'binance kline HTTP ${response.statusCode} for $pair',
        uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return <KLineEntity>[];

    final result = <KLineEntity>[];
    for (final raw in decoded) {
      if (raw is! List || raw.length < 7) continue;
      // Binance kline array layout:
      //   [0] openTime (ms), [1] open, [2] high, [3] low, [4] close,
      //   [5] volume (base asset), [6] closeTime (ms), [7] quoteVolume
      final open = double.tryParse(raw[1].toString()) ?? 0;
      final high = double.tryParse(raw[2].toString()) ?? 0;
      final low = double.tryParse(raw[3].toString()) ?? 0;
      final close = double.tryParse(raw[4].toString()) ?? 0;
      final volume = double.tryParse(raw[5].toString()) ?? 0;
      final time = (raw[0] as num).toInt();
      if (open == 0 && close == 0) continue;

      result.add(
        KLineEntity.fromCustom(
          open: open,
          high: high,
          low: low,
          close: close,
          vol: volume,
          amount: volume,
          time: time,
        ),
      );
    }
    return result;
  }

  @override
  Future<List<StockSearchResult>> search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return <StockSearchResult>[];

    try {
      final symbols = await _loadSymbols();
      if (symbols.isEmpty) return <StockSearchResult>[];

      final kwUpper = kw.toUpperCase();
      final kwLower = kw.toLowerCase();
      final results = <StockSearchResult>[];

      for (final sym in symbols) {
        final baseAsset = (sym['baseAsset'] ?? '').toString();
        final pairSymbol = (sym['symbol'] ?? '').toString();
        final zhName = _zhNames[baseAsset] ?? '';
        final pinyin = _zhPinyin[baseAsset] ?? '';

        // Match on base-asset code, full pair symbol, Chinese name, or
        // pinyin initials. e.g. "btc", "BTCUSDT", "比特币", "btb" all hit BTC.
        if (baseAsset.toUpperCase().contains(kwUpper) ||
            pairSymbol.toUpperCase().contains(kwUpper) ||
            (zhName.isNotEmpty && zhName.contains(keyword)) ||
            (pinyin.isNotEmpty && pinyin.toUpperCase().contains(kwUpper)) ||
            (zhName.isNotEmpty &&
                zhName.toLowerCase().contains(kwLower))) {
          results.add(StockSearchResult.fromBinance(
            symbol: pairSymbol,
            baseAsset: baseAsset,
            zhName: zhName,
            pinyin: pinyin,
          ));
        }
      }

      // Cap the result list to keep the dropdown snappy — Binance lists
      // hundreds of USDT pairs and a broad keyword can match many.
      if (results.length > 30) {
        results.sort((a, b) => _sortWeight(b).compareTo(_sortWeight(a)));
        return results.sublist(0, 30);
      }
      return results;
    } catch (_) {
      return <StockSearchResult>[];
    }
  }

  /// Fetch and cache the exchangeInfo symbol list (USDT pairs only).
  /// Subsequent searches reuse the cached list for the app's lifetime.
  Future<List<Map<String, dynamic>>> _loadSymbols() async {
    if (_symbolCache != null) return _symbolCache!;

    final uri = Uri.parse('$_baseUrl$_exchangeInfoPath');
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'binance exchangeInfo HTTP ${response.statusCode}',
        uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      _symbolCache = <Map<String, dynamic>>[];
      return _symbolCache!;
    }
    final symbols = decoded['symbols'];
    if (symbols is! List) {
      _symbolCache = <Map<String, dynamic>>[];
      return _symbolCache!;
    }

    final cache = <Map<String, dynamic>>[];
    for (final sym in symbols) {
      if (sym is! Map<String, dynamic>) continue;
      final status = (sym['status'] ?? '').toString();
      final quote = (sym['quoteAsset'] ?? '').toString();
      // Only TRADING-status USDT pairs are useful for search.
      if (status != 'TRADING' || quote != _quoteAsset) continue;
      cache.add(sym);
    }
    _symbolCache = cache;
    return cache;
  }

  /// Rank by base-asset "importance" so BTC/ETH/etc. float to the top
  /// when many results match a broad keyword.
  static int _sortWeight(StockSearchResult r) {
    switch (r.code) {
      case 'BTC':
        return 100;
      case 'ETH':
        return 99;
      case 'BNB':
        return 98;
      case 'SOL':
        return 97;
      case 'XRP':
        return 96;
      default:
        return 0;
    }
  }

  /// Map the project's minute-based `scale` to a Binance kline interval.
  static String _scaleToInterval(int scale) {
    switch (scale) {
      case 5:
        return '5m';
      case 15:
        return '15m';
      case 30:
        return '30m';
      case 60:
        return '1h';
      case 240: // The app's "日K" period (240 min) → daily candle on Binance.
        return '1d';
      default:
        if (scale >= 240) return '1d';
        return '5m';
    }
  }
}
