import 'package:flutter/material.dart';

import 'pages/stock_page.dart';

void main() {
  runApp(const StockWatchApp());
}

class StockWatchApp extends StatelessWidget {
  const StockWatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '股票看盘',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF18191D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4C86CD),
          surface: Color(0xFF18191D),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF18191D),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const StockPage(initialSymbol: 'sh600519'),
    );
  }
}
