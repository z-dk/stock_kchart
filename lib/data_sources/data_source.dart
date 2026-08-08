import 'package:k_chart/flutter_k_chart.dart';

import '../models/stock_quote.dart';

/// Abstract data source interface for market data providers.
///
/// Each provider (Eastmoney, Binance, etc.) implements this interface so the
/// UI layer can be provider-agnostic. Adding a new provider only requires
/// implementing this class and registering it in [DataSourceFactory].
abstract class DataSource {
  /// Unique identifier for the data source (e.g. 'eastmoney', 'binance').
  String get id;

  /// Human-readable display name shown in search results.
  String get displayName;

  /// Short description of the data source (market coverage, pricing).
  String get description;

  /// Supported market codes: ['CN', 'US', 'HK', 'CRYPTO', etc.]
  List<String> get supportedMarkets;

  /// Whether this data source requires an API key.
  bool get requiresApiKey;

  /// Validate an arbitrary user input and return the provider's native
  /// symbol format. Examples:
  ///   Eastmoney: 'sh600519', '600519' → '1.600519' (secid)
  ///   Binance:   'btc' → 'BTCUSDT'
  String normalizeSymbol(String input);

  /// Fetch the latest real-time quote for [symbol].
  /// Returns `null` when the instrument is suspended or not found.
  Future<StockQuote?> fetchRealtime(String symbol);

  /// Fetch historical K-line candles for [symbol].
  ///
  /// [scale] is the candle period in minutes:
  ///   5, 15, 30, 60 (intraday) or 240 (daily).
  ///
  /// [datalen] is how many candles to return (typically ≤ 1023).
  Future<List<KLineEntity>> fetchKline(
    String symbol, {
    required int scale,
    int datalen = 300,
  });

  /// Search for stocks matching [keyword] (code, name, or pinyin).
  /// Results are tagged with this source's [id] via
  /// [StockSearchResult.dataSourceId].
  Future<List<StockSearchResult>> search(String keyword);
}
