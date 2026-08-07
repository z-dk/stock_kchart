import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:http/http.dart' as http;
import 'package:k_chart/flutter_k_chart.dart';

import '../data_sources/data_source.dart';
import '../models/stock_quote.dart';

/// Sina Finance data source — A-share China market only.
///
/// Uses two public endpoints:
///  * Real-time quote: `https://hq.sinajs.cn/list=<symbol>`
///    Returns GB18030-encoded text (Chinese stock names).
///    Requires `Referer: https://finance.sina.com.cn/` to avoid 403.
///  * K-line history: `https://money.finance.sina.com.cn/quotes_service/api/
///    json_v2.php/CN_MarketData.getKLineData`
///    Returns UTF-8 JSON array of OHLCV candles.
class SinaDataSource implements DataSource {
  SinaDataSource._();
  static final SinaDataSource instance = SinaDataSource._();

  @override
  String get id => 'sina';

  @override
  String get displayName => '新浪财经 (A 股)';

  @override
  String get description => '中国 A 股实时行情与 K 线，免费无限制';

  @override
  List<String> get supportedMarkets => const <String>['CN'];

  @override
  bool get requiresApiKey => false;

  static const String _hqUrl = 'https://hq.sinajs.cn/list=';
  static const String _klineUrl =
      'https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/CN_MarketData.getKLineData';

  static const String _referer = 'https://finance.sina.com.cn/';
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  static const Duration _timeout = Duration(seconds: 8);

  Map<String, String> get _headers => const <String, String>{
        'Referer': _referer,
        'User-Agent': _userAgent,
      };

  @override
  String normalizeSymbol(String input) {
    final s = input.trim().toLowerCase();

    // Already prefixed with sh/sz.
    if (s.startsWith('sh') || s.startsWith('sz')) {
      final code = s.substring(2);
      return code.length == 6 && int.tryParse(code) != null ? s : s;
    }

    // Strip anything that is not a digit.
    final digits = s.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 6) {
      final first = digits[0];
      // 6/9 → Shanghai (incl. STAR 688, B-shares 900), otherwise Shenzhen.
      if (first == '6' || first == '9') {
        return 'sh$digits';
      } else {
        return 'sz$digits';
      }
    }

    // Indices, HK, US — pass through unchanged (won't actually work on Sina).
    return s;
  }

  @override
  Future<StockQuote?> fetchRealtime(String symbol) async {
    final uri = Uri.parse('$_hqUrl$symbol');
    final response =
        await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'sina realtime HTTP ${response.statusCode} for $symbol',
        uri,
      );
    }

    final text = gbk.decode(response.bodyBytes);
    return StockQuote.fromSina(symbol, text);
  }

  @override
  Future<List<KLineEntity>> fetchKline(
    String symbol, {
    required int scale,
    int datalen = 300,
  }) async {
    final uri = Uri.parse(
      '$_klineUrl?symbol=$symbol&scale=$scale&ma=no&datalen=$datalen',
    );
    final response =
        await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'sina kline HTTP ${response.statusCode} for $symbol',
        uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return <KLineEntity>[];

    final result = <KLineEntity>[];
    for (final raw in decoded) {
      final item = raw as Map<String, dynamic>;
      final day = (item['day'] ?? '').toString();

      final open = double.tryParse('${item['open']}') ?? 0;
      final high = double.tryParse('${item['high']}') ?? 0;
      final low = double.tryParse('${item['low']}') ?? 0;
      final close = double.tryParse('${item['close']}') ?? 0;
      final volume = double.tryParse('${item['volume']}') ?? 0;
      if (open == 0 && close == 0) continue;

      result.add(
        KLineEntity.fromCustom(
          open: open,
          high: high,
          low: low,
          close: close,
          vol: volume,
          amount: volume,
          time: _parseTimeMs(day),
        ),
      );
    }
    return result;
  }

  static int _parseTimeMs(String day) {
    if (day.isEmpty) return DateTime.now().millisecondsSinceEpoch;
    final dt = DateTime.tryParse(day) ?? DateTime.now();
    return dt.millisecondsSinceEpoch;
  }
}
