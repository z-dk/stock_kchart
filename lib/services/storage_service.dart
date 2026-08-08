import 'package:shared_preferences/shared_preferences.dart';

/// Service for storing non-sensitive app preferences.
///
/// All data sources are now key-free, so only lightweight SharedPreferences
/// remain for settings like poll interval.
class StorageService {
  StorageService._();

  static final StorageService instance = StorageService._();

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
