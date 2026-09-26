import 'package:flutter/material.dart';

import 'core/market/binance_market_data_service.dart';
import 'features/dashboard/dashboard_page.dart';
import 'features/dashboard/dashboard_repository.dart';

class RebalanceApp extends StatelessWidget {
  const RebalanceApp({
    super.key,
    required this.repository,
    required this.marketDataService,
  });
  final DashboardRepository repository;
  final BinanceMarketDataService marketDataService;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BTC Rebalance',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFF4B740),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF0B0E11),
      cardTheme: const CardThemeData(
        color: Color(0xFF181C22),
        margin: EdgeInsets.zero,
      ),
      useMaterial3: true,
    ),
    home: DashboardPage(
      repository: repository,
      marketDataService: marketDataService,
    ),
  );
}
