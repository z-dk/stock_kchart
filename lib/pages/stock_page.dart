import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:k_chart/chart_translations.dart';
import 'package:k_chart/flutter_k_chart.dart';

import '../data_sources/data_source.dart';
import '../data_sources/data_source_factory.dart';
import '../data_sources/eastmoney_data_source.dart';
import '../models/favorite_item.dart';
import '../models/stock_quote.dart';
import '../services/favorite_service.dart';
import '../services/stock_search_service.dart';

/// A selectable K-line period. [scale] is the candle length in minutes:
/// 5/15/30/60 intraday, 240 daily. Each data source maps this to its own
/// interval code (Eastmoney klt, Binance interval string).
class _Period {
  const _Period(this.label, this.scale);
  final String label;
  final int scale;
}

const List<_Period> _periods = <_Period>[
  _Period('5分', 5),
  _Period('15分', 15),
  _Period('30分', 30),
  _Period('60分', 60),
  _Period('日K', 240),
];

/// Refresh interval for real-time quotes.
const Duration _refreshInterval = Duration(seconds: 3);

class StockPage extends StatefulWidget {
  const StockPage({super.key, this.initialSymbol = 'sh600519'});

  final String initialSymbol;

  @override
  State<StockPage> createState() => _StockPageState();
}

class _StockPageState extends State<StockPage> {
  final _factory = DataSourceFactory.instance;
  DataSource? _dataSource;
  final TextEditingController _symbolController = TextEditingController();

  late String _symbol = widget.initialSymbol;

  /// Currently selected K-line period (minutes).
  int _scale = 240;

  List<KLineEntity> _klineData = <KLineEntity>[];
  StockQuote? _quote;

  bool _loading = false;
  String? _error;
  DateTime? _lastUpdate;

  // Chart state.
  final ChartStyle _chartStyle = ChartStyle();
  final ChartColors _chartColors = ChartColors();
  MainState _mainState = MainState.MA;
  SecondaryState _secondaryState = SecondaryState.MACD;
  bool _volHidden = false;
  bool _isLine = false;

  // Two-candle comparison mode. Toggled on from the indicator bar; while on,
  // single-finger long-pressing a candle marks it — first press marks the
  // start, second press marks the end and reveals the price change between
  // them. Unlike the old two-finger scheme this works at any zoom/pan level
  // (k_chart reports the selected index via onCandleLongPress) and never
  // resets the chart.
  bool _compareMode = false;
  int? _selIndex1;
  int? _selIndex2;
  int _chartResetKey = 0;

  static const Duration _zoomHintDuration = Duration(seconds: 7);

  /// True when the chart is displayed in landscape orientation (chart fills the
  /// screen, app bar / quote header / drawer are hidden for immersion).
  bool _isLandscape = false;

  /// True while the floating zoom/pan hint bar is visible over the chart.
  /// Shown once after the first chart load, then auto-dismisses after 7s.
  bool _showZoomHint = true;
  Timer? _zoomHintTimer;

  Timer? _timer;

  /// Whether the currently-loaded symbol is in the user's favorites.
  /// Refreshed whenever the symbol or data source changes.
  bool _isFavorite = false;

  /// Cached favorites grouped by market, shown in the drawer. Reloaded each
  /// time the drawer is opened so it reflects the latest additions.
  Map<String, List<FavoriteItem>> _favoriteGroups = <String, List<FavoriteItem>>{};
  bool _favoritesLoading = false;

  @override
  void initState() {
    super.initState();
    // Guard against a leftover landscape lock from a previous session — e.g.
    // the app was force-killed (or reinstalled) while in landscape, so dispose
    // never ran and setPreferredOrientations still pins landscape. Always
    // restore portrait on startup so the app never boots into landscape.
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _symbolController.text = _symbol;
    _initDataSource();
  }

  @override
  void dispose() {
    // Always restore portrait orientation and the system top/bottom UI when
    // the user leaves this page, otherwise the whole app stays locked in
    // landscape after viewing a chart.
    if (_isLandscape) _restorePortraitOrientation();
    _timer?.cancel();
    _zoomHintTimer?.cancel();
    _symbolController.dispose();
    super.dispose();
  }

  /// Toggle between portrait (default) and landscape chart view.
  ///
  /// Landscape locks both left and right orientations so the user can flip the
  /// phone while keeping the chart horizontal; portrait also allows upside
  /// down on tablets but for phones we only allow normal up-right.
  Future<void> _toggleLandscape() async {
    final bool going = !_isLandscape;
    if (going) {
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      // Landscape mode hides the Android system status bar and nav bar so the
      // chart gains a few dozen extra pixels on each side.
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
      );
    } else {
      _restorePortraitOrientation();
    }
    if (mounted) {
      setState(() {
        _isLandscape = going;
      });
    }
  }

  Future<void> _restorePortraitOrientation() async {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    // Re-show the normal system chrome (status bar + nav bar).
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
  }

  Future<void> _initDataSource() async {
    if (mounted) {
      setState(() {
        _dataSource = EastmoneyDataSource.instance;
      });
      _loadAll();
    }
  }

  /// Load K-line history + the first quote, then (re)start the 3s poller.
  Future<void> _loadAll() async {
    if (_dataSource == null) return;
    _timer?.cancel();

    final normalized = _dataSource!.normalizeSymbol(_symbol);
    if (normalized != _symbol) {
      _symbol = normalized;
      _symbolController.text = normalized;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait<dynamic>([
        _dataSource!.fetchKline(_symbol, scale: _scale, datalen: 300),
        _dataSource!.fetchRealtime(_symbol),
      ]);

      final kline = results[0] as List<KLineEntity>;
      final quote = results[1] as StockQuote?;

      if (kline.isNotEmpty) {
        _applyRealtimeToLast(kline, quote);
        DataUtil.calculate(kline);
      }

      if (mounted) {
        setState(() {
          _klineData = kline;
          _quote = quote;
          _loading = false;
          _lastUpdate = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }

    _startPolling();
    // Once the first chart load completes, surface a brief hint telling the
    // user that gestures (pinch-zoom, pan, long-press select) are available.
    _scheduleZoomHintDismissal();
    // Reflect the favorite state for the newly-loaded symbol.
    _refreshFavoriteStatus();
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) => _refreshQuote());
  }

  /// Start (or restart) the timer that fades the zoom hint bar off after
  /// [_zoomHintDuration] seconds. Safe to call repeatedly.
  void _scheduleZoomHintDismissal() {
    _zoomHintTimer?.cancel();
    if (!_showZoomHint) return;
    _zoomHintTimer = Timer(_zoomHintDuration, () {
      if (mounted) setState(() => _showZoomHint = false);
    });
  }

  /// Poll the real-time quote every 3 seconds and live-update the chart's
  /// last candle so the K-line reflects the latest tick.
  Future<void> _refreshQuote() async {
    if (_dataSource == null) return;
    try {
      final quote = await _dataSource!.fetchRealtime(_symbol);
      if (quote == null) return;

      if (_klineData.isNotEmpty) {
        _applyRealtimeToLast(_klineData, quote);
        // Recompute indicators so MA/MACD/… follow the moving last close.
        DataUtil.calculate(_klineData);
      }

      if (mounted) {
        setState(() {
          _quote = quote;
          _lastUpdate = DateTime.now();
        });
      }
    } catch (_) {
      // Transient polling errors are swallowed; the next tick retries.
    }
  }

  /// Merge a fresh quote into the most recent candle: close = last price, and
  /// extend high/low so the live price is always within the candle range.
  void _applyRealtimeToLast(List<KLineEntity> data, StockQuote? quote) {
    if (quote == null || data.isEmpty) return;
    final last = data.last;
    last.close = quote.current;
    if (quote.current > last.high) last.high = quote.current;
    if (quote.current < last.low) last.low = quote.current;
    if (quote.volume > 0) last.vol = quote.volume;
    last.amount = quote.amount;
    last.change = quote.current - quote.prevClose;
    last.ratio = quote.prevClose == 0
        ? 0
        : (quote.current - quote.prevClose) / quote.prevClose * 100;
  }

  void _changePeriod(int scale) {
    if (scale == _scale) return;
    _scale = scale;
    _loadAll();
  }

  void _changeSymbol() {
    if (_dataSource == null) return;
    final normalized = _dataSource!.normalizeSymbol(_symbolController.text);
    if (normalized.isEmpty || normalized == _symbol) return;
    _symbolController.text = normalized;
    _symbol = normalized;
    FocusScope.of(context).unfocus();
    _loadAll();
  }

  /// Switch to a symbol chosen from the search dropdown.
  ///
  /// Unlike [_changeSymbol], the [symbol] comes straight from a search result
  /// and [ds] is the data source that returned it. The symbol is normalized
  /// to the provider's native format before loading. This is the key path
  /// that avoids loading failures caused by invalid user input — the chart
  /// only loads a verified symbol from a verified source.
  void _changeSymbolTo(String symbol, DataSource ds) {
    if (symbol.isEmpty || symbol == _symbol) return;
    _symbolController.text = symbol;
    _symbol = symbol;
    _dataSource = ds;
    FocusScope.of(context).unfocus();
    _loadAll();
  }

  /// Look up whether the currently-loaded symbol is favorited and update
  /// [_isFavorite] so the star button reflects the current state.
  Future<void> _refreshFavoriteStatus() async {
    final ds = _dataSource;
    if (ds == null || _symbol.isEmpty) {
      if (mounted) setState(() => _isFavorite = false);
      return;
    }
    final fav = await FavoriteService.instance.isFavorite(_symbol, ds.id);
    if (mounted) setState(() => _isFavorite = fav);
  }

  /// Toggle the current symbol in/out of favorites. The display name comes
  /// from the loaded quote when available (so e.g. 比特币 is stored rather
  /// than BTCUSDT); otherwise the symbol itself is used.
  Future<void> _toggleFavorite() async {
    final ds = _dataSource;
    if (ds == null || _symbol.isEmpty) return;
    final quote = _quote;
    final item = FavoriteItem.fromSearchResult(
      symbol: _symbol,
      name: quote?.name.isNotEmpty == true ? quote!.name : _symbol,
      code: _displayCode,
      market: _currentMarket,
      dataSourceId: ds.id,
    );
    final nowFav = await FavoriteService.instance.toggle(item);
    if (mounted) {
      setState(() => _isFavorite = nowFav);
      // Refresh the drawer's cached groups so the change is visible next open.
      await _loadFavorites();
    }
  }

  /// Derive a UI market tag from the active data source / symbol. Eastmoney
  /// encodes the market in the secid prefix (1=sh, 0=sz, 116=hk, 105=us);
  /// Binance is always crypto.
  String get _currentMarket {
    final ds = _dataSource;
    if (ds == null) return 'sh';
    if (ds.id == 'binance') return 'crypto';
    // Eastmoney secid: `<market>.<code>`
    final parts = _symbol.split('.');
    if (parts.length == 2) {
      switch (parts[0]) {
        case '1':
          return 'sh';
        case '0':
          return 'sz';
        case '116':
          return 'hk';
        case '105':
          return 'us';
      }
    }
    return 'sh';
  }

  /// Short code for the favorite list (e.g. `600519`, `BTC`, `AAPL`).
  String get _displayCode {
    final ds = _dataSource;
    if (ds == null) return _symbol;
    if (ds.id == 'binance') {
      // BTCUSDT → BTC (strip the USDT suffix).
      final s = _symbol.toUpperCase();
      return s.endsWith('USDT') ? s.substring(0, s.length - 4) : s;
    }
    // Eastmoney secid `<market>.<code>` → `<code>`.
    final parts = _symbol.split('.');
    return parts.length == 2 ? parts[1] : _symbol;
  }

  /// Load favorites grouped by market for drawer display.
  Future<void> _loadFavorites() async {
    if (mounted) setState(() => _favoritesLoading = true);
    try {
      final groups = await FavoriteService.instance.groupedByMarket();
      if (mounted) {
        setState(() {
          _favoriteGroups = groups;
          _favoritesLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _favoritesLoading = false);
    }
  }

  bool get _isIntraday => _scale < 240;

  @override
  Widget build(BuildContext context) {
    final Widget title = Text(_quote != null
        ? '${_quote!.name}  ${_symbol.toUpperCase()}'
        : _symbol.toUpperCase());
    final Widget chartStack = Column(
      children: <Widget>[
        if (!_isLandscape) _buildQuoteHeader(),
        _buildPeriodBar(),
        _buildIndicatorBar(),
        Expanded(child: _buildChart()),
        // Portrait shows the detailed comparison bar at the bottom. In
        // landscape the comparison result is rendered as a floating card
        // inside the chart (see _buildChart) to avoid squeezing chart height.
        if (!_isLandscape && _selIndex1 != null && _selIndex2 != null)
          _buildSelectionBar(),
      ],
    );

    if (_isLandscape) {
      // Landscape: immersive full-screen chart with a thin top bar.
      // No drawer, no quote header, no selection bar — maximum chart area.
      return Scaffold(
        backgroundColor: const Color(0xFF18191D),
        resizeToAvoidBottomInset: false,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: AppBar(
            toolbarHeight: 36,
            backgroundColor: const Color(0xFF18191D),
            foregroundColor: Colors.white,
            automaticallyImplyLeading: false,
            elevation: 0,
            titleSpacing: 8,
            title: DefaultTextStyle(
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  overflow: TextOverflow.ellipsis),
              child: title,
            ),
            actions: <Widget>[
              IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.search, size: 20),
                tooltip: '切换股票',
                onPressed: _showSymbolDialog,
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: '刷新',
                onPressed: _loading ? null : _loadAll,
              ),
            ],
          ),
        ),
        body: chartStack,
      );
    }

    // Portrait: the standard full layout with drawer, quote header etc.
    return Scaffold(
      backgroundColor: const Color(0xFF18191D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF18191D),
        foregroundColor: Colors.white,
        leading: Builder(
          builder: (BuildContext ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: title,
        actions: <Widget>[
          IconButton(
            icon: Icon(_isFavorite ? Icons.star : Icons.star_border),
            tooltip: _isFavorite ? '取消收藏' : '收藏',
            color: _isFavorite ? const Color(0xFFF0B90B) : null,
            onPressed: _toggleFavorite,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '切换股票',
            onPressed: _showSymbolDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loading ? null : _loadAll,
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: chartStack,
    );
  }

  // ─────────────────────────── Quote header ──────────────────────────────

  Widget _buildQuoteHeader() {
    final quote = _quote;
    final upColor = const Color(0xFF4DAA90);
    final dnColor = const Color(0xFFC15466);
    final priceColor = quote == null ? Colors.white : (quote.isUp ? upColor : dnColor);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                quote == null ? '--' : quote.current.toStringAsFixed(2),
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: priceColor,
                ),
              ),
              const SizedBox(width: 12),
              if (quote != null) ...<Widget>[
                Text(
                  '${quote.change >= 0 ? '+' : ''}${quote.change.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 16, color: priceColor),
                ),
                const SizedBox(width: 8),
                Text(
                  '${quote.changePercent >= 0 ? '+' : ''}${quote.changePercent.toStringAsFixed(2)}%',
                  style: TextStyle(fontSize: 16, color: priceColor),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (quote != null)
            _buildStatsGrid(quote, upColor, dnColor)
          else if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '加载失败：$_error',
                style: const TextStyle(color: Color(0xFFC15466), fontSize: 12),
              ),
            ),
          if (_lastUpdate != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF4DAA90),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '实时刷新中 · 最后更新 ${_fmtClock(_lastUpdate!)}',
                    style: const TextStyle(color: Color(0xFF60738E), fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatsGrid(StockQuote q, Color up, Color dn) {
    final cellColor = q.isUp ? up : dn;
    Widget stat(String label, String value) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label,
              style: const TextStyle(color: Color(0xFF60738E), fontSize: 11)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(color: cellColor, fontSize: 13)),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        stat('开盘', q.open.toStringAsFixed(2)),
        stat('最高', q.high.toStringAsFixed(2)),
        stat('最低', q.low.toStringAsFixed(2)),
        stat('昨收', q.prevClose.toStringAsFixed(2)),
        stat('成交量', _fmtVolume(q.volume)),
        stat('成交额', _fmtAmount(q.amount)),
      ],
    );
  }

  // ─────────────────────────── Period bar ────────────────────────────────

  Widget _buildPeriodBar() {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _periods.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final p = _periods[index];
          final selected = p.scale == _scale;
          return ChoiceChip(
            label: Text(p.label),
            selected: selected,
            selectedColor: const Color(0xFF4C86CD),
            labelStyle: TextStyle(
              color: selected ? Colors.white : const Color(0xFF60738E),
              fontSize: 13,
            ),
            backgroundColor: const Color(0xFF23262D),
            onSelected: _loading ? null : (_) => _changePeriod(p.scale),
          );
        },
      ),
    );
  }

  // ─────────────────────────── Indicator bar ─────────────────────────────

  Widget _buildIndicatorBar() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: <Widget>[
          _chip('分时', _isLine, () => setState(() => _isLine = true)),
          _chip('K线', !_isLine, () => setState(() => _isLine = false)),
          _divider(),
          _chip('MA', _mainState == MainState.MA,
              () => setState(() => _mainState = MainState.MA)),
          _chip('BOLL', _mainState == MainState.BOLL,
              () => setState(() => _mainState = MainState.BOLL)),
          _chip('主图无', _mainState == MainState.NONE,
              () => setState(() => _mainState = MainState.NONE)),
          _divider(),
          _chip('MACD', _secondaryState == SecondaryState.MACD,
              () => setState(() => _secondaryState = SecondaryState.MACD)),
          _chip('KDJ', _secondaryState == SecondaryState.KDJ,
              () => setState(() => _secondaryState = SecondaryState.KDJ)),
          _chip('RSI', _secondaryState == SecondaryState.RSI,
              () => setState(() => _secondaryState = SecondaryState.RSI)),
          _chip('副图无', _secondaryState == SecondaryState.NONE,
              () => setState(() => _secondaryState = SecondaryState.NONE)),
          _divider(),
          _chip(_volHidden ? '显示量' : '隐藏量', false,
              () => setState(() => _volHidden = !_volHidden)),
          _divider(),
          _chip('缩放复位', false, () {
            // Bump _chartResetKey to rebuild KChartWidget, which resets its
            // internal mScaleX/mScrollX to 1.0/0.0.
            setState(() => _chartResetKey++);
          }),
          _divider(),
          _chip('对比', _compareMode, _toggleCompareMode),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF4C86CD) : const Color(0xFF23262D),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xFF9AA5B1),
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider() {
    return const Padding(
      padding: EdgeInsets.only(right: 6, left: 2),
      child: VerticalDivider(
        width: 1,
        color: Color(0xFF2C3038),
        indent: 8,
        endIndent: 8,
      ),
    );
  }

  // ─────────────────────────── Chart ─────────────────────────────────────

  Widget _buildChart() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Stack(
          children: <Widget>[
            KeyedSubtree(
              key: ValueKey<int>(_chartResetKey),
              child: KChartWidget(
                _klineData,
                _chartStyle,
                _chartColors,
                isTrendLine: false,
                isLine: _isLine,
                mainState: _mainState,
                secondaryState: _secondaryState,
                volHidden: _volHidden,
                fixedLength: 2,
                maDayList: const <int>[5, 10, 20],
                timeFormat: _isIntraday
                    ? TimeFormat.YEAR_MONTH_DAY_WITH_HOUR
                    : TimeFormat.YEAR_MONTH_DAY,
                translations: kChartTranslations,
                showNowPrice: true,
                hideGrid: false,
                isOnDrag: (bool drag) {
                  // Pause polling while the user drags to keep interaction smooth.
                  if (drag) {
                    _timer?.cancel();
                  } else {
                    _startPolling();
                  }
                },
                // k_chart reports the candle under the long-press at the
                // current zoom/pan level. In compare mode this marks candles
                // (1st press = start, 2nd = end); out of compare mode we just
                // ignore it so the normal crosshair info dialog still shows.
                onCandleLongPress: _onCandleLongPress,
              ),
            ),
            if (_loading && _klineData.isEmpty)
              const Center(child: CircularProgressIndicator()),
            if (_klineData.isEmpty && !_loading)
              const Center(
                child: Text(
                  '暂无K线数据',
                  style: TextStyle(color: Color(0xFF60738E)),
                ),
              ),
            // Compare-mode banner: tells the user long-press will mark a candle,
            // and which mark (start/end) is next.
            if (_compareMode && !_loading && _klineData.isNotEmpty)
              Positioned(
                top: 8,
                left: 12,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2229).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: const Color(0xFF4C86CD), width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.compare_arrows,
                            size: 14, color: Color(0xFF4C86CD)),
                        const SizedBox(width: 6),
                        Text(
                          _selIndex1 == null
                              ? '对比模式：长按选起点'
                              : '长按选终点',
                          style: const TextStyle(
                              color: Color(0xFFD7DCE3), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Floating gesture hint: teaches users about pinch-zoom,
            // horizontal pan, and long-press selection. Dismissed after 7s
            // or when tapped.
            if (_showZoomHint && !_compareMode &&
                !_loading &&
                _klineData.isNotEmpty)
              Positioned(
                top: 8,
                left: 12,
                right: 12,
                child: IgnorePointer(
                  ignoring: false,
                  child: GestureDetector(
                    onTap: () => setState(() => _showZoomHint = false),
                    child: AnimatedOpacity(
                      opacity: _showZoomHint ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F2229).withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: const Color(0xFF2C3038), width: 0.5),
                        ),
                        child: const Row(
                          children: <Widget>[
                            Icon(Icons.pinch,
                                size: 14, color: Color(0xFF4C86CD)),
                            SizedBox(width: 6),
                            Text(
                              '双指缩放 · 左右拖动平移 · 开「对比」长按选K线',
                              style: TextStyle(
                                  color: Color(0xFFD7DCE3), fontSize: 11),
                            ),
                            Spacer(),
                            Icon(Icons.close,
                                size: 14, color: Color(0xFF60738E)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // Landscape toggle: a small floating button anchored to the
            // bottom-right of the chart, available in both orientations so the
            // user can always enter/exit landscape without hunting in the app
            // bar (which is hidden in landscape).
            Positioned(
              bottom: 12,
              right: 12,
              child: FloatingActionButton.small(
                heroTag: const ValueKey<String>('landscapeToggle'),
                backgroundColor: const Color(0xFF1F2229),
                foregroundColor: Colors.white,
                elevation: 2,
                onPressed: _toggleLandscape,
                tooltip: _isLandscape ? '退出横屏' : '横屏查看',
                child: Icon(
                  _isLandscape
                      ? Icons.crop_portrait
                      : Icons.crop_landscape_outlined,
                  size: 20,
                ),
              ),
            ),
            // Landscape-only: show the two-candle comparison result as a
            // compact floating card (bottom-left) instead of the bottom bar
            // that portrait uses, so chart height isn't squeezed.
            if (_isLandscape &&
                _selIndex1 != null &&
                _selIndex2 != null &&
                _klineData.isNotEmpty)
              Positioned(
                bottom: 12,
                left: 12,
                child: _buildLandscapeSelectionCard(),
              ),
          ],
        );
      },
    );
  }

  // ─────────────────────── Two-candle compare mode ────────────────────────

  /// Toggle compare mode. Entering clears any previous marks; leaving also
  /// clears so the chart returns to a clean state.
  void _toggleCompareMode() {
    setState(() {
      _compareMode = !_compareMode;
      _selIndex1 = null;
      _selIndex2 = null;
    });
  }

  /// Called by k_chart on long-press start/move/end. In compare mode:
  ///  * isStart=true (a new press begins): assign the next empty slot — start
  ///    first, then end — or, if both are already set, begin a new selection
  ///    (start = this press, end cleared).
  ///  * isStart=false (the same press is being dragged): fine-tune only the
  ///    most-recently marked candle so dragging adjusts the position instead
  ///    of clearing it. This is the fix for "selecting the end candle wipes
  ///    the start" — the reset path above only runs on a fresh press, never
  ///    on a move.
  ///  * index < 0 (long-press end): ignored so marks persist for reading.
  void _onCandleLongPress(int index, double x, KLineEntity? entity, bool isStart) {
    if (!_compareMode) return;
    if (index < 0 || entity == null) return; // ignore end-of-press signal
    setState(() {
      if (isStart) {
        // A new long-press: commit to the next slot, or reset if full.
        if (_selIndex1 == null) {
          _selIndex1 = index;
        } else if (_selIndex2 == null) {
          _selIndex2 = index;
        } else {
          _selIndex1 = index;
          _selIndex2 = null;
        }
      } else {
        // Same press dragging: nudge the most-recent mark only.
        if (_selIndex2 != null) {
          _selIndex2 = index;
        } else if (_selIndex1 != null) {
          _selIndex1 = index;
        }
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selIndex1 = null;
      _selIndex2 = null;
    });
  }

  Widget _buildSelectionBar() {
    final int? i1 = _selIndex1;
    final int? i2 = _selIndex2;
    final int n = _klineData.length;
    if (i1 == null || i2 == null || i1 >= n || i2 >= n) {
      return const SizedBox.shrink();
    }

    // Order: start = older candle (smaller index), end = newer (larger index),
    // so the change reads as newer vs older.
    final int startIdx = i1 < i2 ? i1 : i2;
    final int endIdx = i1 < i2 ? i2 : i1;
    final KLineEntity a = _klineData[startIdx];
    final KLineEntity b = _klineData[endIdx];
    final double change = b.close - a.close;
    final double pct = a.close == 0 ? 0.0 : change / a.close * 100;
    final bool up = change >= 0;
    final Color color = up ? const Color(0xFF4DAA90) : const Color(0xFFC15466);

    Widget candleBlock(String tag, KLineEntity e) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$tag  ${_fmtDate(e.time)}',
            style: const TextStyle(color: Color(0xFF9AA5B1), fontSize: 11),
          ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: <Widget>[
              _kv('开', e.open.toStringAsFixed(2)),
              _kv('高', e.high.toStringAsFixed(2)),
              _kv('低', e.low.toStringAsFixed(2)),
              _kv('收', e.close.toStringAsFixed(2)),
            ],
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      color: const Color(0xFF1F2229),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    candleBlock('起', a),
                    const SizedBox(height: 6),
                    candleBlock('终', b),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16, color: Color(0xFF60738E)),
                onPressed: _clearSelection,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                tooltip: '清除选择',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '涨跌幅：${up ? '+' : ''}${change.toStringAsFixed(2)}  '
            '(${pct.toStringAsFixed(2)}%)',
            style: TextStyle(
                color: color, fontSize: 14, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  /// Landscape-only compact comparison card, floating at the chart's
  /// bottom-left. Shows the two selected candles' dates + the net change,
  /// plus a close button. Mirrors [_buildSelectionBar]'s math but in a tight
  /// horizontal layout so it overlays the chart without eating height.
  Widget _buildLandscapeSelectionCard() {
    final int? i1 = _selIndex1;
    final int? i2 = _selIndex2;
    final int n = _klineData.length;
    if (i1 == null || i2 == null || i1 >= n || i2 >= n) {
      return const SizedBox.shrink();
    }
    final int startIdx = i1 < i2 ? i1 : i2;
    final int endIdx = i1 < i2 ? i2 : i1;
    final KLineEntity a = _klineData[startIdx];
    final KLineEntity b = _klineData[endIdx];
    final double change = b.close - a.close;
    final double pct = a.close == 0 ? 0.0 : change / a.close * 100;
    final bool up = change >= 0;
    final Color color = up ? const Color(0xFF4DAA90) : const Color(0xFFC15466);

    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1F2229).withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF2C3038), width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _compactCandle('起', a),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.arrow_forward,
                      size: 14, color: Color(0xFF60738E)),
                ),
                _compactCandle('终', b),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 14, color: Color(0xFF60738E)),
                  onPressed: _clearSelection,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                  tooltip: '清除选择',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '涨跌幅：${up ? '+' : ''}${change.toStringAsFixed(2)}  '
              '(${pct.toStringAsFixed(2)}%)',
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  /// One compact candle cell used by [_buildLandscapeSelectionCard].
  Widget _compactCandle(String tag, KLineEntity e) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('$tag ${_fmtDate(e.time)}',
            style: const TextStyle(color: Color(0xFF9AA5B1), fontSize: 10)),
        const SizedBox(height: 1),
        Text('收 ${e.close.toStringAsFixed(2)}',
            style: const TextStyle(color: Color(0xFFD7DCE3), fontSize: 10)),
      ],
    );
  }

  Widget _kv(String k, String v) {
    return RichText(
      text: TextSpan(
        children: <TextSpan>[
          TextSpan(
              text: '$k ',
              style: const TextStyle(color: Color(0xFF60738E), fontSize: 11)),
          TextSpan(
              text: v,
              style: const TextStyle(color: Color(0xFFD7DCE3), fontSize: 11)),
        ],
      ),
    );
  }

  String _fmtDate(int? time) {
    if (time == null) return '--';
    final DateTime dt = DateTime.fromMillisecondsSinceEpoch(time);
    String two(int n) => n.toString().padLeft(2, '0');
    if (_isIntraday) {
      return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
          '${two(dt.hour)}:${two(dt.minute)}';
    }
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }

  // ─────────────────────────── Drawer ────────────────────────────────────

  Widget _buildDrawer() {
    // Lazily load favorites the first time the drawer is built so the list
    // reflects the latest state without forcing a load on every build.
    if (_favoriteGroups.isEmpty && !_favoritesLoading) {
      _loadFavorites();
    }
    return Drawer(
      backgroundColor: const Color(0xFF1A1D25),
      child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          DrawerHeader(
            decoration: const BoxDecoration(color: Color(0xFF1F2229)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                const CircleAvatar(
                  radius: 28,
                  backgroundColor: Color(0xFF4DAA90),
                  child: Icon(Icons.show_chart, color: Colors.white, size: 28),
                ),
                const SizedBox(height: 12),
                const Text(
                  '涨了吗',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                    '多数据源行情看盘',
                    style: TextStyle(color: Color(0xFF60738E), fontSize: 12),
                  ),
              ],
            ),
          ),
          _buildFavoritesSection(),
          const Divider(color: Color(0xFF2A2D34), height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline, color: Color(0xFF9AA5B1)),
            title: const Text('关于', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              _showAbout();
            },
          ),
        ],
      ),
    );
  }

  /// The favorites section in the drawer: a header row plus the grouped list.
  Widget _buildFavoritesSection() {
    final groups = _favoriteGroups;
    final total = groups.values.fold<int>(0, (int s, List<FavoriteItem> l) => s + l.length);

    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      collapsedIconColor: const Color(0xFF9AA5B1),
      iconColor: const Color(0xFF9AA5B1),
      title: Row(
        children: <Widget>[
          const Icon(Icons.star_rounded, color: Color(0xFFF0B90B), size: 20),
          const SizedBox(width: 12),
          const Text('我的收藏', style: TextStyle(color: Colors.white, fontSize: 15)),
          const SizedBox(width: 8),
          if (total > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFF0B90B).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$total',
                style: const TextStyle(color: Color(0xFFF0B90B), fontSize: 11),
              ),
            ),
        ],
      ),
      children: <Widget>[
        if (_favoritesLoading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF4C86CD)),
            ),
          )
        else if (total == 0)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Text(
              '还没有收藏。\n点击右上角星标收藏当前品种。',
              style: TextStyle(color: Color(0xFF60738E), fontSize: 12, height: 1.5),
            ),
          )
        else
          for (final entry in groups.entries)
            _buildMarketGroup(entry.key, entry.value),
      ],
    );
  }

  /// A single market group inside the favorites section.
  Widget _buildMarketGroup(String market, List<FavoriteItem> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
          child: Text(
            _marketLabel(market),
            style: const TextStyle(color: Color(0xFF60738E), fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        for (final item in items) _buildFavoriteTile(item),
        const SizedBox(height: 4),
      ],
    );
  }

  /// A single favorite row: tap to load, long-press to remove.
  Widget _buildFavoriteTile(FavoriteItem item) {
    final isActive =
        _dataSource?.id == item.dataSourceId && _symbol == item.symbol;
    return InkWell(
      onTap: () {
        final ds = _factory.findById(item.dataSourceId);
        if (ds == null) return;
        Navigator.pop(context); // close drawer
        _changeSymbolTo(item.symbol, ds);
      },
      onLongPress: () => _confirmRemoveFavorite(item),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: isActive ? const Color(0xFF4C86CD).withValues(alpha: 0.12) : null,
        child: Row(
          children: <Widget>[
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: _sourceBadgeColor(item.dataSourceId),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.name,
                      style: TextStyle(
                          color: isActive ? const Color(0xFF4C86CD) : Colors.white,
                          fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(item.code.toUpperCase(),
                      style: const TextStyle(color: Color(0xFF60738E), fontSize: 11)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _sourceBadgeColor(item.dataSourceId).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _sourceBadgeLabel(item.dataSourceId),
                style: TextStyle(color: _sourceBadgeColor(item.dataSourceId), fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirm-before-remove dialog for long-pressed favorites.
  Future<void> _confirmRemoveFavorite(FavoriteItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: const Color(0xFF23262D),
        title: const Text('取消收藏', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text('从收藏中移除「${item.name}」？',
            style: const TextStyle(color: Color(0xFF9AA5B1), fontSize: 13)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF60738E))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除', style: TextStyle(color: Color(0xFFC15466))),
          ),
        ],
      ),
    );
    if (ok == true) {
      await FavoriteService.instance.remove(item.symbol, item.dataSourceId);
      await _loadFavorites();
      await _refreshFavoriteStatus();
    }
  }

  /// Map a market tag to a short Chinese label for the favorites group header.
  static String _marketLabel(String market) {
    switch (market) {
      case 'sh':
        return '沪 A';
      case 'sz':
        return '深 A';
      case 'hk':
        return '港股';
      case 'us':
        return '美股';
      case 'crypto':
        return '加密货币';
      default:
        return market.toUpperCase();
    }
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: '涨了吗',
      applicationVersion: '1.1.0',
      applicationIcon: const Icon(Icons.show_chart),
      children: const <Widget>[
        SizedBox(height: 16),
        Text('基于 Flutter + k_chart 构建的多数据源行情看盘应用。'),
        SizedBox(height: 8),
        Text('支持数据源：东方财富、币安'),
      ],
    );
  }

  // ─────────────────────────── Symbol dialog ─────────────────────────────

  Future<void> _showSymbolDialog() async {
    _symbolController.clear();
    List<StockSearchResult> suggestions = <StockSearchResult>[];
    bool searching = false;
    Timer? debounce;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF23262D),
              title: const Text('搜索股票',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: _symbolController,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: '代码 / 名称 / 拼音首字母',
                        hintStyle: TextStyle(color: Color(0xFF60738E)),
                        prefixIcon: Icon(Icons.search,
                            color: Color(0xFF60738E), size: 20),
                        isDense: true,
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF4C86CD)),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF4C86CD)),
                        ),
                      ),
                      onChanged: (value) {
                        debounce?.cancel();
                        if (value.trim().isEmpty) {
                          setState(() {
                            suggestions = <StockSearchResult>[];
                            searching = false;
                          });
                          return;
                        }
                        setState(() => searching = true);
                        debounce = Timer(
                          const Duration(milliseconds: 300),
                          () async {
                            final results =
                                await StockSearchService.instance.search(value);
                            if (ctx.mounted) {
                              setState(() {
                                suggestions = results;
                                searching = false;
                              });
                            }
                          },
                        );
                      },
                      onSubmitted: (_) {
                        debounce?.cancel();
                        Navigator.of(ctx).pop();
                        if (suggestions.isNotEmpty) {
                          final s = suggestions.first;
                          final ds = _factory.findById(s.dataSourceId);
                          if (ds != null) {
                            _changeSymbolTo(ds.normalizeSymbol(s.symbol), ds);
                          }
                        } else {
                          _changeSymbol();
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: searching
                          ? const Padding(
                              padding: EdgeInsets.all(20),
                              child: Center(
                                child: SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFF4C86CD)),
                                ),
                              ),
                            )
                          : suggestions.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Text(
                                    _symbolController.text.trim().isEmpty
                                        ? '输入代码 / 名称 / 拼音搜索'
                                        : '无匹配结果',
                                    style: const TextStyle(
                                        color: Color(0xFF60738E),
                                        fontSize: 13),
                                  ),
                                )
                              : ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: suggestions.length,
                                  itemBuilder: (BuildContext _, int i) {
                                    final s = suggestions[i];
                                    return InkWell(
                                      onTap: () {
                                        debounce?.cancel();
                                        Navigator.of(ctx).pop();
                                        final ds = _factory.findById(s.dataSourceId);
                                        if (ds != null) {
                                          _changeSymbolTo(ds.normalizeSymbol(s.symbol), ds);
                                        }
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 10, horizontal: 4),
                                        child: Row(
                                          children: <Widget>[
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: <Widget>[
                                                  Text(s.name,
                                                      style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 15)),
                                                  const SizedBox(height: 2),
                                                  Text(s.code.toUpperCase(),
                                                      style: const TextStyle(
                                                          color: Color(
                                                              0xFF60738E),
                                                          fontSize: 12)),
                                                ],
                                              ),
                                            ),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: _sourceBadgeColor(s.dataSourceId).withValues(alpha: 0.2),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                _sourceBadgeLabel(s.dataSourceId),
                                                style: TextStyle(
                                                    color: _sourceBadgeColor(s.dataSourceId),
                                                    fontSize: 11),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                                s.market == 'sh'
                                                    ? '沪A'
                                                    : s.market == 'sz'
                                                        ? '深A'
                                                        : s.market == 'hk'
                                                            ? '港股'
                                                            : s.market == 'us'
                                                                ? '美股'
                                                                : '加密',
                                                style: const TextStyle(
                                                    color: Color(0xFF4C86CD),
                                                    fontSize: 12)),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () {
                    debounce?.cancel();
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('取消',
                      style: TextStyle(color: Color(0xFF60738E))),
                ),
                TextButton(
                  onPressed: () {
                    debounce?.cancel();
                    Navigator.of(ctx).pop();
                    if (suggestions.isNotEmpty) {
                      final s = suggestions.first;
                      final ds = _factory.findById(s.dataSourceId);
                      if (ds != null) {
                        _changeSymbolTo(ds.normalizeSymbol(s.symbol), ds);
                      }
                    } else {
                      _changeSymbol();
                    }
                  },
                  child: const Text('确定',
                      style: TextStyle(color: Color(0xFF4C86CD))),
                ),
              ],
            );
          },
        );
      },
    );

    // Clean up the debounce timer after the dialog closes.
    debounce?.cancel();
  }

  // ─────────────────────────── Helpers ───────────────────────────────────

  static String _fmtClock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Format share count as 万 / 亿.
  static String _fmtVolume(double v) {
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(2)}亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(2)}万';
    return v.toStringAsFixed(0);
  }

  /// Format yuan amount as 万 / 亿.
  static String _fmtAmount(double a) {
    if (a >= 100000000) return '${(a / 100000000).toStringAsFixed(2)}亿';
    if (a >= 10000) return '${(a / 10000).toStringAsFixed(2)}万';
    return a.toStringAsFixed(0);
  }

  /// Badge color for a data-source id, shown in the search dropdown.
  static Color _sourceBadgeColor(String id) {
    switch (id) {
      case 'eastmoney':
        return const Color(0xFF4DAA90);
      case 'binance':
        return const Color(0xFFF0B90B);
      default:
        return const Color(0xFF4C86CD);
    }
  }

  /// Badge label text for a data-source id, shown in the search dropdown.
  static String _sourceBadgeLabel(String id) {
    switch (id) {
      case 'eastmoney':
        return '东方财富';
      case 'binance':
        return '币安';
      default:
        return id;
    }
  }
}
