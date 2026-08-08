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

  /// Parse an Eastmoney real-time quote response.
  ///
  /// Eastmoney returns field-coded JSON:
  ///   f43=latest, f44=high, f45=low, f46=open, f47=volume, f48=amount,
  ///   f57=code, f58=name, f60=prevClose, f169=change, f170=changePct
  static StockQuote fromEastmoney(String symbol, Map<String, dynamic> json) {
    final current = (json['f43'] as num?)?.toDouble() ?? 0;
    final high = (json['f44'] as num?)?.toDouble() ?? 0;
    final low = (json['f45'] as num?)?.toDouble() ?? 0;
    final open = (json['f46'] as num?)?.toDouble() ?? 0;
    final volume = (json['f47'] as num?)?.toDouble() ?? 0;
    final amount = (json['f48'] as num?)?.toDouble() ?? 0;
    final name = (json['f58'] ?? '').toString();
    final prevClose = (json['f60'] as num?)?.toDouble() ?? 0;
    final change = (json['f169'] as num?)?.toDouble() ?? 0;
    final changePercent = (json['f170'] as num?)?.toDouble() ?? 0;

    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    return StockQuote(
      symbol: symbol,
      name: name,
      open: open,
      prevClose: prevClose,
      current: current,
      high: high,
      low: low,
      volume: volume,
      amount: amount,
      date: date,
      time: time,
      overrideChange: change,
      overrideChangePercent: changePercent,
    );
  }

  /// Parse a Binance 24hr ticker response.
  ///
  /// Binance returns JSON with stringified numbers:
  ///   lastPrice, priceChange, priceChangePercent, openPrice, highPrice,
  ///   lowPrice, volume (base asset), quoteVolume (USDT amount).
  static StockQuote fromBinance(String symbol, Map<String, dynamic> json) {
    final current = double.tryParse('${json['lastPrice']}') ?? 0;
    final open = double.tryParse('${json['openPrice']}') ?? 0;
    final high = double.tryParse('${json['highPrice']}') ?? 0;
    final low = double.tryParse('${json['lowPrice']}') ?? 0;
    final volume = double.tryParse('${json['volume']}') ?? 0;
    final amount = double.tryParse('${json['quoteVolume']}') ?? 0;
    final change = double.tryParse('${json['priceChange']}') ?? 0;
    final changePercent =
        double.tryParse('${json['priceChangePercent']}') ?? 0;
    // prevClose ≈ lastPrice − priceChange (Binance doesn't return it
    // directly; this matches the 24h window semantics).
    final prevClose = current - change;

    final closeTime = (json['closeTime'] as num?)?.toInt();
    final dt = closeTime != null
        ? DateTime.fromMillisecondsSinceEpoch(closeTime)
        : DateTime.now();
    final date =
        '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';

    return StockQuote(
      symbol: symbol,
      name: symbol,
      open: open,
      prevClose: prevClose,
      current: current,
      high: high,
      low: low,
      volume: volume,
      amount: amount,
      date: date,
      time: time,
      overrideChange: change,
      overrideChangePercent: changePercent,
    );
  }

  @override
  String toString() =>
      'StockQuote($symbol $name current=$current change=$change)';
}

/// A stock search suggestion returned by data source search APIs.
///
/// Each result carries the stock [code], [name], pinyin initials [pinyin],
/// the [market] tag (`sh`/`sz`/`hk`/`us`), the [dataSourceId] identifying
/// which provider returned it, and [symbol] — the loadable identifier for
/// that provider.
class StockSearchResult {
  StockSearchResult({
    required this.code,
    required this.name,
    required this.pinyin,
    required this.market,
    required this.dataSourceId,
    required this.symbol,
  });

  /// Stock code, e.g. `600519` (A-share), `00700` (HK), `AAPL` (US).
  final String code;

  /// Stock name, e.g. `贵州茅台`.
  final String name;

  /// Pinyin initials, e.g. `GZMT`.
  final String pinyin;

  /// Market tag for UI: `sh`/`sz` (A-share), `hk` (HK), `us` (US).
  final String market;

  /// Which data source returned this result (e.g. 'sina', 'eastmoney').
  final String dataSourceId;

  /// Loadable identifier for this result's data source. For Sina this is the
  /// `sh/sz`-prefixed symbol (e.g. `sh600519`); for Eastmoney it is the full
  /// `secid` from the API (e.g. `1.600519`, `116.00700`, `105.AAPL`).
  final String symbol;

  /// Parse from Eastmoney suggest API item.
  ///
  /// Uses `QuoteID` (the full secid, e.g. `1.600519`/`116.00700`/`105.AAPL`)
  /// as the loadable [symbol]. `Classify` picks the UI market tag: AStock→sh/sz
  /// (via `MktNum` 1=SH/0=SZ), HK→hk, UsStock→us.
  factory StockSearchResult.fromEastmoney(Map<String, dynamic> json,
      {String dataSourceId = 'eastmoney'}) {
    final code = (json['Code'] ?? '').toString();
    final name = (json['Name'] ?? '').toString();
    final pinyin = (json['PinYin'] ?? '').toString();
    final classify = (json['Classify'] ?? '').toString();
    final quoteId = (json['QuoteID'] ?? '').toString();

    String market;
    if (classify == 'HK') {
      market = 'hk';
    } else if (classify == 'UsStock') {
      market = 'us';
    } else {
      // AStock — MktNum: 1 → Shanghai (sh), 0 → Shenzhen (sz).
      final mktNum = (json['MktNum'] ?? '0').toString();
      market = mktNum == '1' ? 'sh' : 'sz';
    }

    return StockSearchResult(
      code: code,
      name: name,
      pinyin: pinyin,
      market: market,
      dataSourceId: dataSourceId,
      symbol: quoteId,
    );
  }

  /// Parse from a Binance exchangeInfo symbol entry.
  ///
  /// Binance has no suggest API, so search is done by locally filtering the
  /// cached exchangeInfo symbol list. [symbol] is the full trading-pair code
  /// (e.g. `BTCUSDT`), [baseAsset] is the coin code (e.g. `BTC`), [zhName] is
  /// an optional localized name (e.g. `比特币`), and [pinyin] is optional
  /// pinyin initials for Chinese-name matching.
  factory StockSearchResult.fromBinance({
    required String symbol,
    required String baseAsset,
    String zhName = '',
    String pinyin = '',
    String dataSourceId = 'binance',
  }) {
    return StockSearchResult(
      code: baseAsset,
      name: zhName.isNotEmpty ? zhName : baseAsset,
      pinyin: pinyin,
      market: 'crypto',
      dataSourceId: dataSourceId,
      symbol: symbol,
    );
  }

  /// Parse from Sina suggest API response item.
  /// Item format: `名称,类型,代码,完整代码,名称`
  /// Type 11=沪A, 12=深A.
  factory StockSearchResult.fromSina(String item,
      {String dataSourceId = 'sina'}) {
    final parts = item.split(',');
    if (parts.length < 4) {
      return StockSearchResult(
        code: '',
        name: '',
        pinyin: '',
        market: 'sh',
        dataSourceId: dataSourceId,
        symbol: '',
      );
    }
    final name = parts[0];
    final code = parts[2];
    final fullCode = parts[3]; // e.g. sh600519
    final market = fullCode.startsWith('sh') ? 'sh' : 'sz';
    return StockSearchResult(
      code: code,
      name: name,
      pinyin: '',
      market: market,
      dataSourceId: dataSourceId,
      symbol: fullCode,
    );
  }

  @override
  String toString() => 'StockSearchResult($symbol $name [$dataSourceId])';
}
