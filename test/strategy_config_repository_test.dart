import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/database/database_service.dart';
import 'package:rebalance/features/settings/strategy_config_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('loads defaults and persists a strategy parameter', () async {
    final database = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final repository = StrategyConfigRepository(database);
    expect((await repository.load())['targetBTCWeight'], '0.50');
    await repository.save('targetBTCWeight', '0.55');
    expect((await repository.load())['targetBTCWeight'], '0.55');
    await database.close();
  });

  test('refuses to silently create an unknown parameter', () async {
    final database = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final repository = StrategyConfigRepository(database);
    await expectLater(repository.save('unknownSetting', '1'), throwsStateError);
    await database.close();
  });
}
