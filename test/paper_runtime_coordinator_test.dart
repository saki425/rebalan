import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/database/database_service.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/market/binance_market_data_service.dart';
import 'package:rebalance/core/market/market_state.dart';
import 'package:rebalance/core/runtime/paper_runtime_coordinator.dart';
import 'package:rebalance/features/settings/strategy_config_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('runtime stays stopped until PAPER auto rebalance is enabled', () async {
    final database = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final market = BinanceMarketDataService(
      httpClient: MockClient(
        (_) async => http.Response(
          '{"symbol":"BTCUSDT","lastPrice":"50000","priceChangePercent":"0"}',
          200,
        ),
      ),
    );
    await market.calibrate();
    final runtime = PaperRuntimeCoordinator(
      database: database,
      marketData: market,
      strategyAccount: _strategy,
      profitAccount: _profit,
    );
    expect(await runtime.start(), isFalse);
    expect(runtime.isRunning, isFalse);
    await runtime.dispose();
    await market.stop();
    await database.close();
  });

  test('enabled PAPER runtime starts once and stops cleanly', () async {
    final database = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final settings = StrategyConfigRepository(database);
    await settings.save('enableAutoRebalance', 'true');
    await settings.save('strategyCheckInterval', '60');
    final market = BinanceMarketDataService(
      httpClient: MockClient(
        (_) async => http.Response(
          '{"symbol":"BTCUSDT","lastPrice":"50000","priceChangePercent":"0"}',
          200,
        ),
      ),
    );
    await market.calibrate();
    final runtime = PaperRuntimeCoordinator(
      database: database,
      marketData: market,
      strategyAccount: _strategy,
      profitAccount: _profit,
    );
    expect(await runtime.start(), isTrue);
    expect(await runtime.start(), isTrue);
    expect(runtime.isRunning, isTrue);
    await runtime.stop();
    expect(runtime.isRunning, isFalse);
    await runtime.dispose();
    await market.stop();
    await database.close();
  });

  test('filled PAPER sell applies protected profit withdrawal', () async {
    final database = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final settings = StrategyConfigRepository(database);
    await settings.save('enableAutoRebalance', 'true');
    await settings.save('enableProfitWithdrawal', 'true');
    await settings.save('strategyCheckInterval', '60');
    final market = BinanceMarketDataService(
      httpClient: MockClient(
        (_) async => http.Response(
          '{"symbol":"BTCUSDT","lastPrice":"50000","priceChangePercent":"0"}',
          200,
        ),
      ),
    );
    await market.calibrate();
    final runtime = PaperRuntimeCoordinator(
      database: database,
      marketData: market,
      strategyAccount: _strategy,
      profitAccount: _profit,
    );
    expect(await runtime.start(), isTrue);
    final now = DateTime.now().toUtc();
    final event = runtime.evaluateNow(
      MarketState(
        price: Decimal.parse('75000'),
        change24h: Decimal.zero,
        websocketStatus: ConnectionStatus.connected,
        apiStatus: ConnectionStatus.connected,
        lastEventAt: now,
        lastRestCalibration: now,
      ),
      now,
    );
    expect(event.state.name, 'filled');
    await runtime.stop();
    expect(await database.query('profit_withdrawals'), hasLength(1));
    final transfer = (await database.query(
      'transfers',
      where: 'transfer_type = ?',
      whereArgs: ['PROFIT_WITHDRAWAL'],
    )).single;
    expect(transfer['amount'], '1000');
    await runtime.dispose();
    await market.stop();
    await database.close();
  });
}

final _strategy = AccountBalance(
  role: AccountRole.strategy,
  name: 'Strategy Account',
  btc: Decimal.parse('1'),
  usdt: Decimal.parse('50000'),
);

final _profit = AccountBalance(
  role: AccountRole.profit,
  name: 'Profit Account',
  btc: Decimal.zero,
  usdt: Decimal.zero,
);
