import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'schema.dart';

class DatabaseService {
  DatabaseService._();

  static Future<Database> open({
    DatabaseFactory? factory,
    String? databasePath,
  }) async {
    final selectedFactory = factory ?? databaseFactory;
    final path =
        databasePath ??
        p.join(await selectedFactory.getDatabasesPath(), 'btc_rebalance.db');
    return selectedFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: databaseVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          for (final statement in schemaStatements) {
            await db.execute(statement);
          }
          await _seed(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            final now = DateTime.now().toUtc().toIso8601String();
            await db.insert('strategy_config', {
              'key': 'safeProfitTransferLimit',
              'value': '1000',
              'value_type': 'decimal',
              'updated_at': now,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        },
      ),
    );
  }

  static Future<void> _seed(Database db) async {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final account in const [
      ('FUNDING', 'Funding Account'),
      ('STRATEGY', 'Strategy Account'),
      ('PROFIT', 'Profit Account'),
    ]) {
      await db.insert('accounts', {
        'role': account.$1,
        'display_name': account.$2,
        'created_at': now,
        'updated_at': now,
      });
    }
    final defaults = <String, (String, String)>{
      'targetBTCWeight': ('0.50', 'decimal'),
      'triggerDeviation': ('0.10', 'decimal'),
      'repairRatio': ('0.25', 'decimal'),
      'profitWithdrawalRatio': ('0.20', 'decimal'),
      'strategyCheckInterval': ('5', 'integer'),
      'RESTBalanceSyncInterval': ('60', 'integer'),
      'FullSyncInterval': ('300', 'integer'),
      'maxBTCWeightAfterProfitTransfer': ('0.58', 'decimal'),
      'minOrderUSDT': ('10', 'decimal'),
      'cooldownSeconds': ('30', 'integer'),
      'tradingFeeRate': ('0.001', 'decimal'),
      'slippageTolerance': ('0.001', 'decimal'),
      'safeProfitTransferLimit': ('1000', 'decimal'),
      'enableProfitWithdrawal': ('false', 'boolean'),
      'enableAutoFunding': ('false', 'boolean'),
      'enableAutoRebalance': ('false', 'boolean'),
      'runMode': ('PAPER', 'string'),
    };
    for (final entry in defaults.entries) {
      await db.insert('strategy_config', {
        'key': entry.key,
        'value': entry.value.$1,
        'value_type': entry.value.$2,
        'updated_at': now,
      });
    }
  }
}
