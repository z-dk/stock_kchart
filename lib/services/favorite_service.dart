import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_item.dart';

/// Persistent favorites store backed by SharedPreferences.
///
/// Favorites are stored as a single JSON-encoded list under the
/// `favorites` key. The whole list is rewritten on each mutation — the
/// collection is small (tens of items) so this is cheap and keeps the
/// implementation simple.
class FavoriteService {
  FavoriteService._();
  static final FavoriteService instance = FavoriteService._();

  static const String _prefsKey = 'favorites';

  List<FavoriteItem>? _cache;

  /// Load all favorites, most-recently-added first.
  Future<List<FavoriteItem>> getAll() async {
    if (_cache != null) {
      return List<FavoriteItem>.from(_cache!)
        ..sort((FavoriteItem a, FavoriteItem b) => b.addedAt.compareTo(a.addedAt));
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey) ?? '';
    final items = decodeFavorites(raw);
    _cache = items;
    return List<FavoriteItem>.from(items)
      ..sort((FavoriteItem a, FavoriteItem b) => b.addedAt.compareTo(a.addedAt));
  }

  /// Group favorites by market tag for drawer display.
  /// Returns an ordered map: market → items, with a stable market order
  /// (sh, sz, hk, us, crypto) regardless of insertion order.
  Future<Map<String, List<FavoriteItem>>> groupedByMarket() async {
    final items = await getAll();
    final order = const <String>['sh', 'sz', 'hk', 'us', 'crypto'];
    final groups = <String, List<FavoriteItem>>{};
    for (final f in items) {
      groups.putIfAbsent(f.market, () => <FavoriteItem>[]).add(f);
    }
    // Sort each group: name first, then symbol.
    for (final list in groups.values) {
      list.sort((FavoriteItem a, FavoriteItem b) {
        final cmp = a.name.compareTo(b.name);
        if (cmp != 0) return cmp;
        return a.symbol.compareTo(b.symbol);
      });
    }
    // Build an ordered map following `order`, then any stray markets.
    final ordered = <String, List<FavoriteItem>>{};
    for (final m in order) {
      final g = groups.remove(m);
      if (g != null && g.isNotEmpty) ordered[m] = g;
    }
    // Any leftover markets (e.g. unknown tags) appended in alphabetical order.
    final leftover = groups.keys.toList()..sort();
    for (final m in leftover) {
      ordered[m] = groups[m]!;
    }
    return ordered;
  }

  /// True if the given symbol/source pair is already favorited.
  Future<bool> isFavorite(String symbol, String dataSourceId) async {
    final items = await getAll();
    return items.any((FavoriteItem f) =>
        f.symbol == symbol && f.dataSourceId == dataSourceId);
  }

  /// Add a favorite. No-op (returns false) if it already exists.
  Future<bool> add(FavoriteItem item) async {
    final items = await getAll();
    if (items.any((FavoriteItem f) => f.key == item.key)) return false;
    items.insert(0, item);
    await _persist(items);
    return true;
  }

  /// Remove a favorite by symbol + source. Returns true if removed.
  Future<bool> remove(String symbol, String dataSourceId) async {
    final items = await getAll();
    final before = items.length;
    items.removeWhere((FavoriteItem f) =>
        f.symbol == symbol && f.dataSourceId == dataSourceId);
    if (items.length == before) return false;
    await _persist(items);
    return true;
  }

  /// Toggle a favorite on/off. Returns the new state (true = now favorited).
  Future<bool> toggle(FavoriteItem item) async {
    final exists = await isFavorite(item.symbol, item.dataSourceId);
    if (exists) {
      await remove(item.symbol, item.dataSourceId);
      return false;
    }
    await add(item);
    return true;
  }

  Future<void> _persist(List<FavoriteItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    // Store in added-order (most recent first) — getAll already sorts, but
    // persist the raw list so re-sorts on load remain stable.
    await prefs.setString(_prefsKey, encodeFavorites(items));
    _cache = items;
  }
}
