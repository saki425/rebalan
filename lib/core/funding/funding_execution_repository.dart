import 'package:sqflite/sqflite.dart';

import 'paper_funding_executor.dart';

class FundingExecutionRepository {
  const FundingExecutionRepository(this.database);
  final Database database;

  Future<void> save(PaperFundingResult result) async {
    final accountRows = await database.query(
      'accounts',
      columns: ['id', 'role'],
    );
    final ids = {
      for (final row in accountRows) row['role'] as String: row['id'] as int,
    };
    final fundingId = ids['FUNDING']!;
    final strategyId = ids['STRATEGY']!;
    final now = DateTime.now().toUtc().toIso8601String();
    await database.transaction((transaction) async {
      await transaction.insert('deposits', {
        'account_id': fundingId,
        'exchange_id': result.idempotencyKey,
        'asset': 'USDT',
        'amount': result.plan.depositUsdt.toString(),
        'status': 'PAPER_CONFIRMED',
        'occurred_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      if (result.order case final order?) {
        final clientOrderId = '${result.idempotencyKey}:order';
        await transaction.insert('orders', {
          'client_order_id': clientOrderId,
          'exchange_order_id': clientOrderId,
          'account_id': fundingId,
          'symbol': 'BTCUSDT',
          'side': 'BUY',
          'order_type': 'MARKET',
          'status': order.status,
          'requested_quantity': order.btcQuantity.toString(),
          'executed_quantity': order.btcQuantity.toString(),
          'quote_quantity': order.quoteAmount.toString(),
          'reason': 'PAPER_FUNDING_ALLOCATION',
          'idempotency_key': '${result.idempotencyKey}:order',
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        final rows = await transaction.query(
          'orders',
          columns: ['id'],
          where: 'client_order_id = ?',
          whereArgs: [clientOrderId],
          limit: 1,
        );
        await transaction.insert('trades', {
          'order_id': rows.single['id'] as int,
          'exchange_trade_id': '$clientOrderId:trade',
          'price': order.price.toString(),
          'btc_quantity': order.btcQuantity.toString(),
          'usdt_quantity': order.quoteAmount.toString(),
          'fee_asset': 'USDT',
          'fee_amount': order.feeUsdt.toString(),
          'executed_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final transfer in result.transfers) {
        final clientTransferId = '${result.idempotencyKey}:${transfer.asset}';
        await transaction.insert('transfers', {
          'client_transfer_id': clientTransferId,
          'exchange_transfer_id': clientTransferId,
          'from_account_id': fundingId,
          'to_account_id': strategyId,
          'asset': transfer.asset,
          'amount': transfer.amount.toString(),
          'before_balance': transfer.fromBefore.toString(),
          'after_balance': transfer.fromAfter.toString(),
          'transfer_type': 'INTERNAL_TRANSFER',
          'status': transfer.status,
          'idempotency_key': '${result.idempotencyKey}:${transfer.asset}',
          'note': 'PAPER funding allocation',
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }
}
