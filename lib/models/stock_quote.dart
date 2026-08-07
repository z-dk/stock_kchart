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
    this.overrideChange,
    this.overrideChangePercent,
  });

  final String symbol;
  final String name;
  final double open;
  final double prevClose;
  final double current;
  final double high;
  final double low;
  final double volume;
  final double amount;
  final String date;
  final String time;
  final double? overrideChange;
  final double? overrideChangePercent;

  double get change =>
      overrideChange ?? (current - prevClose);

  double get changePercent =>
      overrideChangePercent ??
      (prevClose == 0 ? 0 : (current - prevClose) / prevClose * 100);

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

  /// Parse a Finnhub quote response.
  ///
  /// Finnhub returns a compact JSON object:
  ///   {"c": price, "d": change, "dp": changePct,
  ///    "h": high, "l": low, "o": open, "pc": prevClose, "t": unixTs}
  ///
  /// Volume and amount are not available in the quote response → set to 0.
  /// Name/date/time are derived from the symbol and timestamp.
  static StockQuote fromFinnhub(String symbol, Map<String, dynamic> json) {
    final current = (json['c'] as num?)?.toDouble() ?? 0;
    final change = (json['d'] as num?)?.toDouble() ?? 0;
    final changePercent = (json['dp'] as num?)?.toDouble() ?? 0;
    final high = (json['h'] as num?)?.toDouble() ?? 0;
    final low = (json['l'] as num?)?.toDouble() ?? 0;
    final open = (json['o'] as num?)?.toDouble() ?? 0;
    final prevClose = (json['pc'] as num?)?.toDouble() ?? 0;
    final timestamp = (json['t'] as num?)?.toInt() ?? 0;

    final dt = timestamp > 0
        ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
        : DateTime.now();
    final date =
        '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';

    return StockQuote(
      symbol: symbol,
      name: symbol, // Finnhub does not return company name
      open: open,
      prevClose: prevClose,
      current: current,
      high: high,
      low: low,
      volume: 0, // Not available in Finnhub quote
      amount: 0,
      date: date,
      time: time,
      overrideChange: change,
      overrideChangePercent: changePercent,
    );
  }
}
