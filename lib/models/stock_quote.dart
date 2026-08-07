/// Real-time quote for a single A-share symbol, parsed from Sina Finance's
/// `hq.sinajs.cn` text response.
///
/// Sina returns a line like:
///   var hq_str_sh600519="贵州茅台,1310.000,1306.450,1308.550,1314.400,
///   1300.010,1308.550,1308.580,2546328,3326230801.000,7983,1308.550,
///   ...(5档买卖)...,2026-08-06,15:00:00,00";
///
/// The fields (comma separated, 0-indexed):
///   0  name          1  todayOpen      2  prevClose       3  current
///   4  high          5  low            6  bidPrice        7  askPrice
///   8  volume(shares) 9 amount(yuan)   10..29 买一..买五(量,价)
///   30 date          31 time          32 status
class StockQuote {
  StockQuote({
    required this.symbol,
    required this.name,
    required this.open,
    required this.prevClose,
    required this.current,
    required this.high,
    required this.low,
    required this.volume,
    required this.amount,
    required this.date,
    required this.time,
  });

  /// Sina symbol with exchange prefix, e.g. `sh600519`, `sz000001`.
  final String symbol;

  /// Stock name (Chinese, already decoded from GB18030).
  final String name;

  final double open;
  final double prevClose;
  final double current;
  final double high;
  final double low;

  /// Number of traded shares.
  final double volume;

  /// Traded value in yuan.
  final double amount;

  /// Quote date, e.g. `2026-08-06`.
  final String date;

  /// Quote time, e.g. `15:00:00`.
  final String time;

  /// Price change vs previous close.
  double get change => current - prevClose;

  /// Price change percentage vs previous close.
  double get changePercent =>
      prevClose == 0 ? 0 : (current - prevClose) / prevClose * 100;

  bool get isUp => current >= prevClose;

  /// Parse a single `var hq_str_<symbol>="...";` line.
  /// Returns `null` if the line is empty or malformed (e.g. suspended symbol).
  static StockQuote? fromSina(String symbol, String text) {
    final eq = text.indexOf('=');
    if (eq < 0) return null;

    var payload = text.substring(eq + 1).trim();
    if (payload.startsWith('"')) payload = payload.substring(1);
    if (payload.endsWith('";')) {
      payload = payload.substring(0, payload.length - 2);
    } else if (payload.endsWith('"')) {
      payload = payload.substring(0, payload.length - 1);
    }
    payload = payload.trim();
    if (payload.isEmpty) return null;

    final parts = payload.split(',');
    if (parts.length < 32) return null;

    double num(int i) => double.tryParse(parts[i].trim()) ?? 0;

    return StockQuote(
      symbol: symbol,
      name: parts[0].trim(),
      open: num(1),
      prevClose: num(2),
      current: num(3),
      high: num(4),
      low: num(5),
      volume: num(8),
      amount: num(9),
      date: parts[30].trim(),
      time: parts[31].trim(),
    );
  }

  @override
  String toString() =>
      'StockQuote($symbol $name current=$current change=$change)';
}
