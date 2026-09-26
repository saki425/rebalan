import 'package:flutter/material.dart';

import 'app.dart';
import 'core/accounts/local_account_balance_source.dart';
import 'core/database/database_service.dart';
import 'core/live/credential_store.dart';
import 'core/market/binance_market_data_service.dart';
import 'features/dashboard/dashboard_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = await DatabaseService.open();
  const credentialStore = SecureCredentialStore();
  final accountSource = LocalAccountBalanceSource(credentials: credentialStore);
  runApp(
    RebalanceApp(
      repository: DashboardRepository(
        database,
        accountBalanceSource: accountSource,
      ),
      marketDataService: BinanceMarketDataService(),
    ),
  );
}
