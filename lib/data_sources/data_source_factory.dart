import 'data_source.dart';
import 'sina_data_source.dart';
import 'finnhub_data_source.dart';
import '../services/storage_service.dart';

/// Factory that provides the active [DataSource] based on user settings.
///
/// New providers can be registered by adding them to the [_providers] list.
class DataSourceFactory {
  DataSourceFactory._();
  static final DataSourceFactory instance = DataSourceFactory._();

  final List<DataSource> _providers = <DataSource>[
    SinaDataSource.instance,
    FinnhubDataSource.instance,
  ];

  /// Returns the list of all available data sources (for the settings UI).
  List<DataSource> get allSources => List.unmodifiable(_providers);

  /// Find a data source by [id], or return `null` if not registered.
  DataSource? findById(String id) {
    for (final ds in _providers) {
      if (ds.id == id) return ds;
    }
    return null;
  }

  /// Get the currently active data source (from persistent settings).
  /// Falls back to Sina if no setting exists.
  Future<DataSource> getActive() async {
    final storage = StorageService.instance;
    final id = await storage.getActiveDataSourceId();
    final ds = findById(id);
    return ds ?? SinaDataSource.instance;
  }

  /// Switch the active data source.
  Future<void> setActive(String id) async {
    final ds = findById(id);
    if (ds == null) {
      throw ArgumentError('Unknown data source: $id');
    }
    final storage = StorageService.instance;
    await storage.setActiveDataSourceId(id);
  }

  /// Register a new data source (for future extensibility).
  void register(DataSource source) {
    if (_providers.any((ds) => ds.id == source.id)) {
      throw StateError('Data source ${source.id} is already registered.');
    }
    _providers.add(source);
  }
}
