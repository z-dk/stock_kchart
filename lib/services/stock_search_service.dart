import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/stock_quote.dart';

/// Searches A-share stocks via Eastmoney's public suggest API.
///
/// Endpoint: `https://searchapi.eastmoney.com/api/suggest/get`
/// Returns JSON with Code/Name/PinYin/MktNum for matching stocks.
/// Users can search by 6-digit code, Chinese name, or pinyin initials.
///
/// Only A-share stocks (`Classify == "AStock"`) are returned; indices, funds,
/// bonds, etc. are filtered out so results always load correctly in the chart.
class StockSearchService {
  StockSearchService._();
  static final StockSearchService instance = StockSearchService._();

  static const String _url =
      'https://searchapi.eastmoney.com/api/suggest/get';
  static const String _token = 'D43BF722C8E33BDC906FB84D85E326E8';
  static const Duration _timeout = Duration(seconds: 5);

  /// Search A-share stocks by code, name, or pinyin.
  ///
  /// Returns an empty list on error, timeout, or no matches — never throws,
  /// so the caller can safely use the result to populate a dropdown.
  Future<List<StockSearchResult>> search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return <StockSearchResult>[];

    final uri = Uri.parse(
      '$_url?input=${Uri.encodeComponent(kw)}&type=14&token=$_token&count=15',
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
        // Only A-shares; skip indices, funds, bonds, etc.
        final classify = (item['Classify'] ?? '').toString();
        if (classify != 'AStock') continue;
        final result = StockSearchResult.fromEastmoney(item);
        if (result.code.isNotEmpty && result.name.isNotEmpty) {
          results.add(result);
        }
      }
      return results;
    } catch (_) {
      // Network error, parse error, or timeout — return empty gracefully.
      return <StockSearchResult>[];
    }
  }
}
