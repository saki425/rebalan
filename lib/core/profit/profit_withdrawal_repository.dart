import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import '../performance/high_water_mark_manager.dart';
import 'paper_profit_executor.dart';

class ProfitWithdrawalRepository {
  const ProfitWithdrawalRepository(this.database);
  final Database database;

  Future<void> save({
    required PaperProfitTransfer transfer,
    required HighWaterMarkRecord highWaterMark,
    required String? strategyClientOrderId,
    required String btcPrice,
  }) async {
    final existing = await database.query(
      'transfers',
      columns: ['id'],
      where: 'idempotency_key = ?',
      whereArgs: [transfer.idempotencyKey],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    final accounts = await database.query('accounts', columns: ['id', 'role']);
    final ids = {
      for (final row in accounts) row['role'] as String: row['id'] as int,
    };
    int? tradeId;
    if (strategyClientOrderId != null) {
      final trades = await database.rawQuery(
        'SELECT trades.id FROM trades JOIN orders ON orders.id = trades.order_id WHERE orders.client_order_id = ? LIMIT 1',
        [strategyClientOrderId],
      );
      tradeId = trades.isEmpty ? null : trades.single['id'] as int;
    }
    final now = highWaterMark.effectiveAt.toUtc().toIso8601String();
    await database.transaction((transaction) async {
      final transferId = await transaction.insert('transfers', {
        'client_transfer_id': transfer.idempotencyKey,
        'exchange_transfer_id': transfer.transferId,
        'from_account_id': ids['STRATEGY'],
        'to_account_id': ids['PROFIT'],
        'asset': 'USDT',
        'amount': transfer.amount.toString(),
        'before_balance': transfer.strategyBefore.toString(),
        'after_balance': transfer.strategyAfter.toString(),
        'transfer_type': 'PROFIT_WITHDRAWAL',
        'status': transfer.status,
        'idempotency_key': transfer.idempotencyKey,
        'note': 'PAPER profit withdrawal',
        'created_at': now,
        'updated_at': now,
      });
      await transaction.insert('profit_withdrawals', {
        'transfer_id': transferId,
        'strategy_trade_id': tradeId,
        'btc_price': btcPrice,
        'strategy_equity': transfer.decision.currentEquity.toString(),
        'high_water_mark': transfer.decision.highWaterMark.toString(),
        'new_profit': transfer.decision.newProfit.toString(),
        'withdrawal_ratio': transfer.decision.newProfit == Decimal.zero
            ? '0'
            : (transfer.decision.requestedAmount / transfer.decision.newProfit)
                  .toDecimal(scaleOnInfinitePrecision: 18)
                  .toString(),
        'actual_amount': transfer.amount.toString(),
        'created_at': now,
      });
      await transaction.insert('high_water_marks', {
        'value_usdt': highWaterMark.value.toString(),
        'adjusted_equity_usdt': highWaterMark.value.toString(),
        'reason': highWaterMark.reason,
        'effective_at': now,
      });
    });
  }
}
