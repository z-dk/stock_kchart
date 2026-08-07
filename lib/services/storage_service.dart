import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for securely storing and retrieving data source configuration.
///
/// Sensitive values (API keys) are encrypted with [FlutterSecureStorage];
/// non-sensitive values (active data source ID) use [SharedPreferences].
class StorageService {
  StorageService._();

  static final StorageService instance = StorageService._();

  final _secure = const FlutterSecureStorage();
  final _prefKeyActiveSource = 'active_data_source';

  // ────────────────────────────── Active source ──────────────────────────

  Future<String> getActiveDataSourceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKeyActiveSource) ?? 'sina';
  }

  Future<void> setActiveDataSourceId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyActiveSource, id);
  }

  // ────────────────────────────── API keys ────────────────────────────────

  /// Retrieve the API key for [sourceId], or `null` if not set.
  Future<String?> getApiKey(String sourceId) {
    return _secure.read(key: 'api_key_$sourceId');
  }

  /// Save (or clear, if [value] is `null`) the API key for [sourceId].
  Future<void> setApiKey(String sourceId, String? value) {
    if (value == null || value.isEmpty) {
      return _secure.delete(key: 'api_key_$sourceId');
    }
    return _secure.write(key: 'api_key_$sourceId', value: value);
  }

  // ────────────────────────────── Timeout config ──────────────────────────

  Future<Duration> getPollInterval() async {
    final prefs = await SharedPreferences.getInstance();
    final secs = prefs.getInt('poll_interval_seconds') ?? 3;
    return Duration(seconds: secs);
  }

  Future<void> setPollInterval(Duration duration) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('poll_interval_seconds', duration.inSeconds);
  }
}
