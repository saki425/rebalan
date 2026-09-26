import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/database/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  test('creates all required tables and safe defaults', () async {
    final db = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name']).toSet();
    for (final table in const {
      'accounts',
      'account_snapshots',
      'orders',
      'trades',
      'transfers',
      'deposits',
      'withdrawals',
      'strategy_events',
      'strategy_config',
      'portfolio_snapshots',
      'profit_withdrawals',
      'high_water_marks',
      'system_logs',
    }) {
      expect(tables, contains(table));
    }
    expect(await db.query('accounts'), hasLength(3));
    final config = {
      for (final row in await db.query('strategy_config'))
        row['key']: row['value'],
    };
    expect(config['runMode'], 'PAPER');
    expect(config['enableAutoRebalance'], 'false');
    expect(config['enableProfitWithdrawal'], 'false');
    expect(config['safeProfitTransferLimit'], '1000');
  });
}
