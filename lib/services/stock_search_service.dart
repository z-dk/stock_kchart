import '../models/stock_quote.dart';
import '../data_sources/data_source_factory.dart';

/// Searches A-share stocks across all registered data sources.
///
/// Each registered [DataSource] contributes its own [search] results,
/// tagged with the source's [id] via [StockSearchResult.dataSourceId].
/// Results are aggregated in registration order (Sina first, then
/// Eastmoney, etc.) so the UI can display a per-source label for the
/// user to choose from.
class StockSearchService {
  StockSearchService._();
  static final StockSearchService instance = StockSearchService._();

  static const Duration _timeout = Duration(seconds: 5);

  /// Search across all registered data sources by code, name, or pinyin.
  ///
  /// Returns an aggregated list, never throws. Each result carries a
  /// [StockSearchResult.dataSourceId] identifying its origin.
  Future<List<StockSearchResult>> search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return <StockSearchResult>[];

    final sources = DataSourceFactory.instance.allSources;

    // Query all sources in parallel; on timeout return empty for that source.
    final futures = sources.map(
      (ds) => ds.search(kw).timeout(
            _timeout,
            onTimeout: () => <StockSearchResult>[],
          ),
    );
    final results = await Future.wait(futures);

    // Flatten in registration order (Sina first, Eastmoney second, ...).
    final aggregated = <StockSearchResult>[];
    for (final list in results) {
      aggregated.addAll(list);
    }
    return aggregated;
  }
}
