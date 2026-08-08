import 'dart:convert';

/// A user-favorited trading instrument.
///
/// Favorites are persisted locally (SharedPreferences) and grouped by
/// [market] in the drawer UI. The [symbol] + [dataSourceId] pair uniquely
/// identifies a favorite — the same stock returned by two sources counts as
/// two entries, matching the search-result model.
class FavoriteItem {
  const FavoriteItem({
    required this.symbol,
    required this.name,
    required this.code,
    required this.market,
    required this.dataSourceId,
    required this.addedAt,
  });

  /// Loadable identifier for the owning data source (e.g. `1.600519`,
  /// `BTCUSDT`, `116.00700`).
  final String symbol;

  /// Display name (e.g. `贵州茅台`, `比特币`, `Apple Inc`).
  final String name;

  /// Display code (e.g. `600519`, `BTC`, `AAPL`).
  final String code;

  /// Market tag: `sh`/`sz`/`hk`/`us`/`crypto`.
  final String market;

  /// Owning data source id (`eastmoney`/`binance`).
  final String dataSourceId;

  /// When the user added this favorite (epoch milliseconds).
  final int addedAt;

  /// Stable key used to dedupe / toggle favorites.
  String get key => '$dataSourceId|$symbol';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'symbol': symbol,
        'name': name,
        'code': code,
        'market': market,
        'dataSourceId': dataSourceId,
        'addedAt': addedAt,
      };

  factory FavoriteItem.fromJson(Map<String, dynamic> json) {
    return FavoriteItem(
      symbol: (json['symbol'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      code: (json['code'] ?? '').toString(),
      market: (json['market'] ?? '').toString(),
      dataSourceId: (json['dataSourceId'] ?? '').toString(),
      addedAt: (json['addedAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Build from a search result plus the resolved display fields. The search
  /// result already carries symbol/name/code/market/dataSourceId.
  factory FavoriteItem.fromSearchResult({
    required String symbol,
    required String name,
    required String code,
    required String market,
    required String dataSourceId,
  }) {
    return FavoriteItem(
      symbol: symbol,
      name: name,
      code: code,
      market: market,
      dataSourceId: dataSourceId,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  String toString() => 'FavoriteItem($symbol $name [$market/$dataSourceId])';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FavoriteItem && other.key == key);

  @override
  int get hashCode => key.hashCode;
}

/// Encode/decode a list of favorites as a JSON string for SharedPreferences.
String encodeFavorites(List<FavoriteItem> items) {
  final list = items.map((FavoriteItem f) => f.toJson()).toList();
  return jsonEncode(list);
}

List<FavoriteItem> decodeFavorites(String raw) {
  if (raw.isEmpty) return <FavoriteItem>[];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return <FavoriteItem>[];
  return decoded
      .whereType<Map<String, dynamic>>()
      .map(FavoriteItem.fromJson)
      .toList();
}
