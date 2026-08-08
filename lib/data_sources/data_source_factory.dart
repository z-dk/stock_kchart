import 'data_source.dart';
import 'sina_data_source.dart';
import 'eastmoney_data_source.dart';
import 'binance_data_source.dart';

/// Factory that provides access to all registered [DataSource]s.
///
/// New providers can be registered by adding them to the [_providers] list.
/// Unlike the previous single-active-source model, the UI now selects a
/// data source per-stock via the search dropdown, so this factory only
/// exposes the list and lookup — no global "active" state.
class DataSourceFactory {
  DataSourceFactory._();
  static final DataSourceFactory instance = DataSourceFactory._();

  final List<DataSource> _providers = <DataSource>[
    SinaDataSource.instance,
    EastmoneyDataSource.instance,
    BinanceDataSource.instance,
  ];

  /// Returns the list of all available data sources.
  List<DataSource> get allSources => List.unmodifiable(_providers);

  /// Find a data source by [id], or return `null` if not registered.
  DataSource? findById(String id) {
    for (final ds in _providers) {
      if (ds.id == id) return ds;
    }
    return null;
  }

  /// Register a new data source (for future extensibility).
  void register(DataSource source) {
    if (_providers.any((ds) => ds.id == source.id)) {
      throw StateError('Data source ${source.id} is already registered.');
    }
    _providers.add(source);
  }
}
