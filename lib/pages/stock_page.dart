import 'dart:async';

import 'package:flutter/material.dart';
import 'package:k_chart/chart_translations.dart';
import 'package:k_chart/flutter_k_chart.dart';

import '../data_sources/data_source.dart';
import '../data_sources/data_source_factory.dart';
import '../data_sources/sina_data_source.dart';
import '../models/stock_quote.dart';
import '../services/stock_search_service.dart';

/// A selectable K-line period. [scale] is the candle length in minutes
/// (Sina's `scale` parameter): 5/15/30/60 intraday, 240 daily.
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

  // Two-finger long-press comparison: when two fingers rest on the chart
  // simultaneously for ~450ms, the candles under each finger are selected and
  // their data + mutual price change are shown in a bottom info bar. Because
  // k_chart's _KChartWidgetState keeps scaleX/scrollX private, the
  // coordinate→index math only works in the initial (unscaled/unscrolled)
  // state, so a comparison bumps _chartResetKey to rebuild KChartWidget.
  int? _selIndex1;
  int? _selIndex2;
  int _chartResetKey = 0;
  double _chartWidth = 0;
  final Map<int, _PointerTrack> _pointers = <int, _PointerTrack>{};

  static const Duration _longPressThreshold = Duration(milliseconds: 450);
  static const double _moveTolerance = 20.0;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _symbolController.text = _symbol;
    _initDataSource();
  }

  Future<void> _initDataSource() async {
    if (mounted) {
      setState(() {
        _dataSource = SinaDataSource.instance;
      });
      _loadAll();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _symbolController.dispose();
    for (final _PointerTrack t in _pointers.values) {
      t.timer?.cancel();
    }
    _pointers.clear();
    super.dispose();
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
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) => _refreshQuote());
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

  bool get _isIntraday => _scale < 240;

  @override
  Widget build(BuildContext context) {
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
        title: Text(_quote != null
            ? '${_quote!.name}  ${_symbol.toUpperCase()}'
            : _symbol.toUpperCase()),
        actions: <Widget>[
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
      body: Column(
        children: <Widget>[
          _buildQuoteHeader(),
          _buildPeriodBar(),
          _buildIndicatorBar(),
          Expanded(child: _buildChart()),
          if (_selIndex1 != null && _selIndex2 != null) _buildSelectionBar(),
        ],
      ),
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
        final double chartWidth = constraints.maxWidth;
        _chartWidth = chartWidth;
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
              ),
            ),
            // Two-finger long-press overlay: observe pointers without blocking
            // the chart's own pan/zoom or single-finger long-press crosshair.
            // When two fingers rest still for ~450ms, the candles beneath them
            // are selected for comparison.
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerCancel,
              ),
            ),
            // Native-style dual overlay: two crosshair lines + an OHLC info box
            // per selected candle. IgnorePointer so it never steals touches.
            if (_selIndex1 != null &&
                _selIndex2 != null &&
                _klineData.isNotEmpty)
              _buildCompareOverlay(chartWidth),
            if (_loading && _klineData.isEmpty)
              const Center(child: CircularProgressIndicator()),
            if (_klineData.isEmpty && !_loading)
              const Center(
                child: Text(
                  '暂无K线数据',
                  style: TextStyle(color: Color(0xFF60738E)),
                ),
              ),
          ],
        );
      },
    );
  }

  // ─────────────────────── Two-finger long-press compare ─────────────────

  void _onPointerDown(PointerDownEvent event) {
    final track = _PointerTrack(event.localPosition, DateTime.now());
    _pointers[event.pointer] = track;
    track.timer = Timer(_longPressThreshold, () {
      track.longPressed = true;
      _tryTriggerComparison();
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    final track = _pointers[event.pointer];
    if (track == null) return;
    // A finger that drifts beyond the tolerance before the long-press fires
    // is treated as a drag/pan, not a selection.
    if (!track.longPressed &&
        (event.localPosition - track.downLocal).distance > _moveTolerance) {
      track.timer?.cancel();
      track.timer = null;
    }
  }

  void _onPointerUp(PointerUpEvent event) => _cancelPointer(event.pointer);

  void _onPointerCancel(PointerCancelEvent event) =>
      _cancelPointer(event.pointer);

  void _cancelPointer(int pointer) {
    final track = _pointers.remove(pointer);
    track?.timer?.cancel();
  }

  /// When at least two fingers are long-pressing simultaneously, select the
  /// candles under the earliest two and reveal the comparison bar.
  void _tryTriggerComparison() {
    final held = _pointers.values
        .where((_PointerTrack t) => t.longPressed)
        .toList()
      ..sort((_PointerTrack a, _PointerTrack b) =>
          a.downTime.compareTo(b.downTime));
    if (held.length < 2) return;
    if (_chartWidth == 0 || _klineData.isEmpty) return;
    final int i1 = _xToCandleIndex(held[0].downLocal.dx, _chartWidth);
    final int i2 = _xToCandleIndex(held[1].downLocal.dx, _chartWidth);
    if (i1 < 0 || i2 < 0) return;
    setState(() {
      _selIndex1 = i1;
      _selIndex2 = i2;
      // Rebuild KChartWidget so scaleX/scrollX reset to defaults; the
      // coordinate→index math above assumes this initial state.
      _chartResetKey++;
    });
  }

  void _clearSelection() {
    setState(() {
      _selIndex1 = null;
      _selIndex2 = null;
    });
  }

  // ─────────────────────────── Candle selection ──────────────────────────

  /// Map a screen x-coordinate to a candle index, assuming the chart is in
  /// its initial state (scaleX=1.0, scrollX=0). This mirrors the math in
  /// k_chart's BaseChartPainter.calculateSelectedX, but only works when the
  /// chart has not been zoomed/panned — which is why a comparison rebuilds
  /// KChartWidget via _chartResetKey.
  int _xToCandleIndex(double x, double chartWidth) {
    final int itemCount = _klineData.length;
    if (itemCount == 0) return -1;
    const double xFrontPadding = 100.0; // KChartWidget default
    final double pointWidth = _chartStyle.pointWidth; // 11.0
    // scaleX=1.0, scrollX=0 → mTranslateX = getMinTranslateX()
    final double mDataLen = itemCount * pointWidth;
    double minTranslateX =
        -mDataLen + chartWidth - pointWidth / 2 - xFrontPadding;
    if (minTranslateX > 0) minTranslateX = 0;
    // xToTranslateX: translateX = -mTranslateX + x / scaleX (scaleX=1.0)
    final double translateX = -minTranslateX + x;
    // getX(position) = position * mPointWidth + mPointWidth / 2
    // → position = (translateX - mPointWidth/2) / mPointWidth
    int index = ((translateX - pointWidth / 2) / pointWidth).round();
    if (index < 0) index = 0;
    if (index >= itemCount) index = itemCount - 1;
    return index;
  }

  /// Inverse of [_xToCandleIndex]: map a candle index back to its screen
  /// x-coordinate, assuming the chart is in its initial (reset) state.
  double _candleIndexToX(int index, double chartWidth) {
    const double xFrontPadding = 100.0; // KChartWidget default
    final double pointWidth = _chartStyle.pointWidth; // 11.0
    final int itemCount = _klineData.length;
    final double mDataLen = itemCount * pointWidth;
    double minTranslateX =
        -mDataLen + chartWidth - pointWidth / 2 - xFrontPadding;
    if (minTranslateX > 0) minTranslateX = 0;
    // translateX = index * pointWidth + pointWidth / 2, and
    // x = translateX + minTranslateX (from translateX = -minTranslateX + x).
    return index * pointWidth + pointWidth / 2 + minTranslateX;
  }

  // ─────────────────────────── Compare overlay ───────────────────────────

  /// Native-style dual overlay drawn on top of the chart once two candles are
  /// selected: a dashed vertical crosshair at each candle's screen-x plus an
  /// OHLC info box beside each. Only renders correctly while the chart is in
  /// its initial (reset) state, which is why comparison bumps _chartResetKey.
  Widget _buildCompareOverlay(double chartWidth) {
    final int? i1 = _selIndex1;
    final int? i2 = _selIndex2;
    if (i1 == null || i2 == null) return const SizedBox.shrink();
    final double x1 = _candleIndexToX(i1, chartWidth);
    final double x2 = _candleIndexToX(i2, chartWidth);
    final KLineEntity e1 = _klineData[i1];
    final KLineEntity e2 = _klineData[i2];
    final bool left1 = x1 < chartWidth / 2;
    final bool left2 = x2 < chartWidth / 2;
    // If both boxes would land on the same side, drop the second below the
    // first so they don't overlap.
    final double top2 = (left1 == left2) ? 72.0 : 0.0;

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: <Widget>[
            CustomPaint(
              size: Size.infinite,
              painter: _CompareCrossPainter(
                x1: x1,
                x2: x2,
                color: _chartColors.selectBorderColor,
              ),
            ),
            _compareInfoBox(e1, left1, 0, chartWidth),
            _compareInfoBox(e2, left2, top2, chartWidth),
          ],
        ),
      ),
    );
  }

  Widget _compareInfoBox(
      KLineEntity e, bool left, double topOffset, double chartWidth) {
    const double boxW = 116;
    final double leftPos = left ? 4.0 : chartWidth - boxW - 4;
    return Positioned(
      left: leftPos,
      top: 24 + topOffset,
      child: Container(
        width: boxW,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: _chartColors.selectFillColor,
          border:
              Border.all(color: _chartColors.selectBorderColor, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(_fmtDate(e.time),
                style:
                    const TextStyle(color: Color(0xFF9AA5B1), fontSize: 9)),
            const SizedBox(height: 2),
            _row('开', e.open.toStringAsFixed(2)),
            _row('高', e.high.toStringAsFixed(2)),
            _row('低', e.low.toStringAsFixed(2)),
            _row('收', e.close.toStringAsFixed(2)),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(k,
              style:
                  const TextStyle(color: Color(0xFF60738E), fontSize: 9)),
          Text(v,
              style:
                  const TextStyle(color: Color(0xFFD7DCE3), fontSize: 9)),
        ],
      ),
    );
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
                    '多数据源 A 股看盘',
                    style: TextStyle(color: Color(0xFF60738E), fontSize: 12),
                  ),
              ],
            ),
          ),
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

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: '涨了吗',
      applicationVersion: '1.1.0',
      applicationIcon: const Icon(Icons.show_chart),
      children: const <Widget>[
        SizedBox(height: 16),
        Text('基于 Flutter + k_chart 构建的多数据源股票看盘应用。'),
        SizedBox(height: 8),
        Text('支持数据源：新浪财经、东方财富'),
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
                                                color: s.dataSourceId == 'sina'
                                                    ? const Color(0xFFE8783C).withValues(alpha: 0.2)
                                                    : const Color(0xFF4DAA90).withValues(alpha: 0.2),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                s.dataSourceId == 'sina' ? '新浪' : '东方财富',
                                                style: TextStyle(
                                                    color: s.dataSourceId == 'sina'
                                                        ? const Color(0xFFE8783C)
                                                        : const Color(0xFF4DAA90),
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
                                                            : '美股',
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
}

/// Per-finger tracking state for the two-finger long-press comparison.
class _PointerTrack {
  _PointerTrack(this.downLocal, this.downTime);

  /// Finger position (chart-local coordinates) at the moment of touch-down.
  final Offset downLocal;

  /// When the finger first touched the screen — used to order simultaneous
  /// long-presses deterministically.
  final DateTime downTime;

  /// One-shot timer that fires [_StockPageState._longPressThreshold] after
  /// touch-down; cancelled if the finger drifts beyond the move tolerance.
  Timer? timer;

  /// True once [timer] has fired (the finger rested still long enough).
  bool longPressed = false;
}

/// Draws a dashed vertical crosshair line at each of two selected candles'
/// screen-x positions, mimicking k_chart's native selection crosshair.
class _CompareCrossPainter extends CustomPainter {
  _CompareCrossPainter({
    required this.x1,
    required this.x2,
    required this.color,
  });

  final double x1;
  final double x2;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;
    for (final double x in <double>[x1, x2]) {
      _drawDashedVertical(canvas, x, size.height, paint);
    }
  }

  void _drawDashedVertical(Canvas canvas, double x, double h, Paint paint) {
    const double dash = 4.0;
    const double gap = 3.0;
    double y = 0;
    while (y < h) {
      canvas.drawLine(Offset(x, y), Offset(x, y + dash), paint);
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_CompareCrossPainter old) =>
      x1 != old.x1 || x2 != old.x2 || color != old.color;
}
