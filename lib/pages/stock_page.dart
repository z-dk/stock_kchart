import 'dart:async';

import 'package:flutter/material.dart';
import 'package:k_chart/chart_translations.dart';
import 'package:k_chart/flutter_k_chart.dart';

import '../data_sources/data_source.dart';
import '../data_sources/data_source_factory.dart';
import '../models/stock_quote.dart';
import 'settings_page.dart';

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

  // Selection mode: tap to pick 2 candles, then show the close-price change
  // percent in a bottom info bar. Because k_chart's _KChartWidgetState keeps
  // scaleX/scrollX private, the coordinate→index math only works when the
  // chart is in its initial (unscaled/unscrolled) state, so entering select
  // mode bumps _chartResetKey to force a KChartWidget rebuild.
  bool _isSelectMode = false;
  int? _selIndex1;
  int? _selIndex2;
  int _chartResetKey = 0;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _symbolController.text = _symbol;
    _initDataSource();
  }

  Future<void> _initDataSource() async {
    final ds = await _factory.getActive();
    if (mounted) {
      setState(() {
        _dataSource = ds;
      });
      _loadAll();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _symbolController.dispose();
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
          if (_isSelectMode) _buildSelectionBar(),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'toggle_select_mode',
        onPressed: _toggleSelectMode,
        backgroundColor: _isSelectMode ? const Color(0xFFC15466) : const Color(0xFF4C86CD),
        child: Icon(_isSelectMode ? Icons.close : Icons.compare_arrows),
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

  void _toggleSelectMode() {
    setState(() {
      _isSelectMode = !_isSelectMode;
      if (_isSelectMode) {
        // Rebuild KChartWidget so scaleX/scrollX reset to defaults; the
        // coordinate→index math assumes this initial state.
        _chartResetKey++;
        _selIndex1 = null;
        _selIndex2 = null;
      }
    });
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
        return Stack(
          children: <Widget>[
            // AbsorbPointer blocks KChartWidget's own gestures while in
            // select mode so the chart can't be zoomed/panned (which would
            // invalidate the coordinate→index math).
            AbsorbPointer(
              absorbing: _isSelectMode,
              child: KeyedSubtree(
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
            ),
            // Selection-mode overlay: capture taps, map x→candle index.
            if (_isSelectMode)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (TapUpDetails details) {
                    final int index =
                        _xToCandleIndex(details.localPosition.dx, chartWidth);
                    _onSelectCandle(index);
                  },
                  onLongPressStart: (LongPressStartDetails details) {
                    final int index =
                        _xToCandleIndex(details.localPosition.dx, chartWidth);
                    _onSelectCandle(index);
                  },
                  child: Container(color: Colors.transparent),
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
          ],
        );
      },
    );
  }

  // ─────────────────────────── Candle selection ──────────────────────────

  /// Map a screen x-coordinate to a candle index, assuming the chart is in
  /// its initial state (scaleX=1.0, scrollX=0). This mirrors the math in
  /// k_chart's BaseChartPainter.calculateSelectedX, but only works when the
  /// chart has not been zoomed/panned — which is why select mode rebuilds
  /// KChartWidget via _chartResetKey on entry.
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

  void _onSelectCandle(int index) {
    if (index < 0 || index >= _klineData.length) return;
    setState(() {
      if (_selIndex1 == null) {
        _selIndex1 = index;
      } else if (_selIndex2 == null) {
        _selIndex2 = index;
      } else {
        // Both selected already — restart with a new first pick.
        _selIndex1 = index;
        _selIndex2 = null;
      }
    });
  }

  Widget _buildSelectionBar() {
    final int? i1 = _selIndex1;
    final int? i2 = _selIndex2;
    final int n = _klineData.length;

    if (i1 == null) {
      return _selectionHint('选点模式：点击或长按图表选择第 1 根 K 线');
    }
    if (i1 >= n) return const SizedBox.shrink();
    final KLineEntity e1 = _klineData[i1];
    if (i2 == null) {
      return _selectionHint(
        '已选第 1 根：${_fmtDate(e1.time)}  收盘 ${e1.close.toStringAsFixed(2)}，'
        '点击或长按选择第 2 根 K 线',
      );
    }
    if (i2 >= n) return const SizedBox.shrink();
    final KLineEntity e2 = _klineData[i2];
    final double change = e2.close - e1.close;
    final double pct = e1.close == 0 ? 0.0 : change / e1.close * 100;
    final bool up = change >= 0;
    final Color color =
        up ? const Color(0xFF4DAA90) : const Color(0xFFC15466);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: const Color(0xFF1F2229),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '起：${_fmtDate(e1.time)}  ${e1.close.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: Color(0xFF9AA5B1), fontSize: 12),
                ),
              ),
              const Icon(Icons.arrow_forward,
                  color: Color(0xFF60738E), size: 14),
              Expanded(
                child: Text(
                  '终：${_fmtDate(e2.time)}  ${e2.close.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: Color(0xFF9AA5B1), fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${up ? '涨幅' : '跌幅'}：${up ? '+' : ''}${change.toStringAsFixed(2)}  '
            '(${pct.toStringAsFixed(2)}%)',
            style: TextStyle(
                color: color, fontSize: 14, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _selectionHint(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: const Color(0xFF1F2229),
      child: Text(
        text,
        style: const TextStyle(color: Color(0xFF9AA5B1), fontSize: 12),
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
    final sources = _factory.allSources;
    final currentDs = _dataSource;

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
                Text(
                  currentDs?.displayName ?? '加载中...',
                  style: const TextStyle(color: Color(0xFF60738E), fontSize: 12),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '数据源',
              style: TextStyle(color: Color(0xFF60738E), fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
          ...sources.map((ds) => ListTile(
                leading: Icon(
                  currentDs?.id == ds.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: currentDs?.id == ds.id
                      ? const Color(0xFF4DAA90)
                      : const Color(0xFF60738E),
                  size: 18,
                ),
                title: Text(ds.displayName, style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  ds.description,
                  style: const TextStyle(color: Color(0xFF9AA5B1), fontSize: 11),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await _factory.setActive(ds.id);
                  if (mounted) {
                    setState(() {
                      _dataSource = ds;
                    });
                    _loadAll();
                  }
                },
              )),
          const Divider(height: 1, color: Color(0xFF2A2E38)),
          ListTile(
            leading: const Icon(Icons.settings, color: Color(0xFF9AA5B1)),
            title: const Text('设置', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              ).then((_) async {
                // Reload data source after returning from settings
                final ds = await _factory.getActive();
                if (mounted) {
                  setState(() {
                    _dataSource = ds;
                  });
                  _loadAll();
                }
              });
            },
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
      applicationVersion: '1.0.0',
      applicationIcon: const Icon(Icons.show_chart),
      children: const <Widget>[
        SizedBox(height: 16),
        Text('基于 Flutter + k_chart 构建的多数据源股票看盘应用。'),
        SizedBox(height: 8),
        Text('支持数据源：新浪财经 (A 股)、Finnhub (全球)'),
      ],
    );
  }

  // ─────────────────────────── Symbol dialog ─────────────────────────────

  Future<void> _showSymbolDialog() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF23262D),
          title: const Text('输入股票代码',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: TextField(
            controller: _symbolController,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: '如 600519 / sh600519 / 000001',
              hintStyle: TextStyle(color: Color(0xFF60738E)),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF4C86CD)),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF4C86CD)),
              ),
            ),
            onSubmitted: (_) {
              Navigator.of(context).pop();
              _changeSymbol();
            },
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消',
                  style: TextStyle(color: Color(0xFF60738E))),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _changeSymbol();
              },
              child: const Text('确定',
                  style: TextStyle(color: Color(0xFF4C86CD))),
            ),
          ],
        );
      },
    );
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
