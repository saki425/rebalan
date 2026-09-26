import 'package:sqflite/sqflite.dart';

import 'package:decimal/decimal.dart';

import '../../core/domain/models.dart';
import '../../core/paper/paper_trading_engine.dart';

class StrategyConfigRepository {
  const StrategyConfigRepository(this.database);
  final Database database;

  Future<Map<String, String>> load() async {
    final rows = await database.query('strategy_config', orderBy: 'key');
    return {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
  }

  Future<StrategyConfig> loadStrategyConfig() async {
    final values = await load();
    return StrategyConfig(
      targetBtcWeight: Decimal.parse(values['targetBTCWeight']!),
      triggerDeviation: Decimal.parse(values['triggerDeviation']!),
      repairRatio: Decimal.parse(values['repairRatio']!),
      profitWithdrawalRatio: Decimal.parse(values['profitWithdrawalRatio']!),
      strategyCheckIntervalSeconds: int.parse(values['strategyCheckInterval']!),
      restBalanceSyncIntervalSeconds: int.parse(
        values['RESTBalanceSyncInterval']!,
      ),
      fullSyncIntervalSeconds: int.parse(values['FullSyncInterval']!),
      maxBtcWeightAfterProfitTransfer: Decimal.parse(
        values['maxBTCWeightAfterProfitTransfer']!,
      ),
    );
  }

  Future<PaperTradingConfig> loadPaperConfig() async {
    final values = await load();
    return PaperTradingConfig(
      targetBtcWeight: Decimal.parse(values['targetBTCWeight']!),
      triggerDeviation: Decimal.parse(values['triggerDeviation']!),
      repairRatio: Decimal.parse(values['repairRatio']!),
      feeRate: Decimal.parse(values['tradingFeeRate']!),
      slippageRate: Decimal.parse(values['slippageTolerance']!),
      minimumOrderUsdt: Decimal.parse(values['minOrderUSDT']!),
      cooldown: Duration(seconds: int.parse(values['cooldownSeconds']!)),
    );
  }

  Future<void> save(String key, String value) async {
    final changed = await database.update(
      'strategy_config',
      {'value': value, 'updated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'key = ?',
      whereArgs: [key],
    );
    if (changed != 1) throw StateError('Unknown strategy setting: $key');
  }
}
