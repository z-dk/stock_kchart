# 股票看盘 (stock_kchart)

一个使用 Flutter 构建的 Android 股票看盘应用，接入 **新浪财经** 行情接口，使用
`k_chart`（`flutter_k_chart` 的空安全维护版）展示 K 线，并每 3 秒定时刷新实时行情。

## 功能

- 实时行情：当前价、涨跌额、涨跌幅、开/高/低/昨收、成交量、成交额
- K 线图：蜡烛图 / 分时图切换，主图指标（MA / BOLL）、副图指标（MACD / KDJ / RSI）、
  成交量显隐，支持缩放、平移、长按十字光标
- 多周期：5 分 / 15 分 / 30 分 / 60 分 / 日 K
- 股票切换：输入 6 位代码自动识别沪深前缀（6/9 开头 → sh，0/3 开头 → sz），
  也可直接输入 `sh600519`、`sz000001`
- **每 3 秒**自动拉取最新行情，并把最新价更新到 K 线最后一根蜡烛 + 重算指标

## 目录结构

```
lib/
├── main.dart                      # 入口、深色主题
├── models/
│   └── stock_quote.dart           # 新浪实时行情数据模型（解析 33 字段 hq 响应）
├── services/
│   └── sina_api_service.dart      # 新浪接口封装：实时报价 + K 线历史
└── pages/
    └── stock_page.dart            # 看盘主页：行情头 + 周期/指标栏 + KChart + 3s 定时器
```

## 新浪接口说明

| 用途 | 接口 | 编码 |
|------|------|------|
| 实时报价 | `https://hq.sinajs.cn/list=<symbol>` | **GB18030**（股票名是中文） |
| K 线历史 | `https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/CN_MarketData.getKLineData?symbol=<symbol>&scale=<分钟>&ma=no&datalen=<条数>` | UTF-8 JSON |

- 实时接口必须带 `Referer: https://finance.sina.com.cn/`，否则返回 403。
- 实时接口的中文股票名是 GB18030 编码，使用 [`charset`](https://pub.dev/packages/charset)
  包的 `gbk.decode(bodyBytes)` 解码（Dart 3 兼容；`gbk_codec`/`enough_convert` 均因
  `sdk <3.0.0` 约束无法在 Dart 3 上解析）。
- K 线接口返回纯 ASCII JSON，可直接 `jsonDecode`。

## 运行

### 1. 环境要求

- Flutter 3.x（Dart 3.x）
- Android SDK（build-tools、platforms）
- **JDK 17+**（Android Gradle Plugin 8/9 要求；JDK 8 无法构建）

> 本机的默认 `JAVA_HOME` 若为 JDK 8，构建会报错。请将 `JAVA_HOME` 指向 JDK 17：
> ```powershell
> $env:JAVA_HOME = "C:\Users\zdk\.jdks\ms-17.0.20"   # 本机 IntelliJ 自带 JDK 17
> $env:PATH = "D:\flutter\bin;$env:JAVA_HOME\bin;$env:PATH"
> ```

### 2. 安装依赖

```bash
flutter pub get
```

### 3. 运行

```bash
flutter run                  # 连接设备/模拟器后运行
# 或构建 debug APK
flutter build apk --debug
```

## 关于 flutter_k_chart

pub.dev 上的 `flutter_k_chart` 最新版为 0.2.0，发布于 5 年前，早于 Dart 空安全
（2021），在 Flutter 3.x / Dart 3.x 上**无法解析依赖**。

本项目改用其空安全维护版 [`k_chart`](https://pub.dev/packages/k_chart)（同源 API，
主库文件仍为 `flutter_k_chart.dart`，`KChartWidget` / `KLineEntity` / `DataUtil` /
`MainState` / `SecondaryState` 等用法完全一致），作为直接替代。

## 验证

```bash
flutter analyze   # No issues found
flutter test      # 行情解析与代码归一化单元测试通过
```
