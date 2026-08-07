import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:http/http.dart' as http;
import 'package:k_chart/flutter_k_chart.dart';

import '../models/stock_quote.dart';

/// Sina Finance market-data client.
///
/// Two endpoints are used:
///  * Real-time quote: `https://hq.sinajs.cn/list=<symbol>`
///    Returns GB18030-encoded text (`var hq_str_<symbol>="...";`).
///    NOTE: requires a `Referer: https://finance.sina.com.cn/` header, otherwise
///    Sina answers 403.
///  * K-line history: `https://money.finance.sina.com.cn/quotes_service/api/
///    json_v2.php/CN_MarketData.getKLineData`
///    Returns UTF-8/ASCII JSON: `[{"day","open","high","low","close","volume"}]`.
class SinaApiService {
  SinaApiService();

  static const String _hqUrl = 'https://hq.sinajs.cn/list=';
  static const String _klineUrl =
      'https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/CN_MarketData.getKLineData';

  static const String _referer = 'https://finance.sina.com.cn/';
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  /// Timeout for network requests. Real-time polling must stay snappy.
  static const Duration _timeout = Duration(seconds: 8);

  Map<String, String> get _headers => const <String, String>{
        'Referer': _referer,
        'User-Agent': _userAgent,
      };

  /// Normalize arbitrary user input into a Sina symbol with an exchange prefix.
  ///
  /// Accepted inputs: `sh600519`, `sz000001`, `600519`, `000001`, `sh000001`
  /// (index), etc. Pure 6-digit codes are auto-prefixed by A-share rules:
  /// 6xx/9xx/68x → Shanghai (`sh`); 0xx/3xx/2xx → Shenzhen (`sz`).
  static String normalizeSymbol(String input) {
    final s = input.trim().toLowerCase();

    // Already prefixed.
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

    // Indices, HK, US — pass through unchanged.
    return s;
  }

  /// Fetch the latest real-time quote for [symbol] (e.g. `sh600519`).
  ///
  /// Returns `null` when the symbol is suspended or the response is empty.
  Future<StockQuote?> fetchRealtime(String symbol) async {
    final uri = Uri.parse('$_hqUrl$symbol');
    final response = await http
        .get(uri, headers: _headers)
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'realtime HTTP ${response.statusCode} for $symbol',
        uri,
      );
    }

    // Body is GB18030 — decode bytes with the GBK codec (GBK is a subset of
    // GB18030 and covers all stock names in practice).
    final text = gbk.decode(response.bodyBytes);
    return StockQuote.fromSina(symbol, text);
  }

  /// Fetch historical K-line candles for [symbol].
  ///
  /// [scale] is the candle period in minutes: 5, 15, 30, 60 (intraday) or
  /// 240 (daily). [datalen] is how many candles to return (max ~1023).
  Future<List<KLineEntity>> fetchKline(
    String symbol, {
    required int scale,
    int datalen = 300,
  }) async {
    final uri = Uri.parse(
      '$_klineUrl?symbol=$symbol&scale=$scale&ma=no&datalen=$datalen',
    );
    final response = await http
        .get(uri, headers: _headers)
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'kline HTTP ${response.statusCode} for $symbol',
        uri,
      );
    }

    // K-line payload is pure ASCII JSON; body (UTF-8) decodes fine.
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return <KLineEntity>[];

    final result = <KLineEntity>[];
    for (final raw in decoded) {
      final item = raw as Map<String, dynamic>;
      final day = (item['day'] ?? '').toString();

      // Sina returns OHLC/volume as numeric strings like "1310.000".
      final open = double.tryParse('${item['open']}') ?? 0;
      final high = double.tryParse('${item['high']}') ?? 0;
      final low = double.tryParse('${item['low']}') ?? 0;
      final close = double.tryParse('${item['close']}') ?? 0;
      final volume = double.tryParse('${item['volume']}') ?? 0;
      if (open == 0 && close == 0) continue; // skip invalid candle

      result.add(
        KLineEntity.fromCustom(
          open: open,
          high: high,
          low: low,
          close: close,
          vol: volume,
          amount: volume, // Sina gives no amount, reuse volume for the tooltip.
          time: _parseTimeMs(day),
        ),
      );
    }
    // Sina returns oldest → newest already; keep as-is (k_chart expects this).
    return result;
  }

  /// Parse Sina's `day` field to epoch milliseconds (k_chart time unit).
  ///
  /// Daily candles: `"2026-08-06"`. Intraday candles: `"2026-08-06 14:30:00"`.
  /// Both are local time, which round-trips correctly through k_chart's
  /// `DateTime.fromMillisecondsSinceEpoch` (local) rendering.
  static int _parseTimeMs(String day) {
    if (day.isEmpty) return DateTime.now().millisecondsSinceEpoch;
    final dt = DateTime.tryParse(day) ?? DateTime.now();
    return dt.millisecondsSinceEpoch;
  }
}
