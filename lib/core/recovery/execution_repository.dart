import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import '../paper/paper_trading_engine.dart';

class PersistedOrder {
  const PersistedOrder({
    required this.clientOrderId,
    required this.exchangeOrderId,
    required this.symbol,
    required this.status,
    required this.idempotencyKey,
    required this.updatedAt,
  });
  final String clientOrderId;
  final String? exchangeOrderId;
  final String symbol;
  final String status;
  final String idempotencyKey;
  final DateTime updatedAt;
  bool get isOpen => const {
        'SUBMITTED',
        'PARTIALLY_FILLED',
        'ORDER_SUBMITTED',
        'NEW',
        'UNKNOWN',
      }.contains(status);
}

class TransferWrite {
  const TransferWrite({
    required this.clientTransferId,
    required this.fromAccountId,
    required this.toAccountId,
    required this.asset,
    required this.amount,
    required this.beforeBalance,
    required this.afterBalance,
    required this.transferType,
    required this.status,
    required this.idempotencyKey,
    required this.createdAt,
    this.note,
  });
  final String clientTransferId;
  final int fromAccountId;
  final int toAccountId;
  final String asset;
  final Decimal amount;
  final Decimal beforeBalance;
  final Decimal afterBalance;
  final String transferType;
  final String status;
  final String idempotencyKey;
  final DateTime createdAt;
  final String? note;
}

class ExecutionRepository {
  const ExecutionRepository(this.database);
  final Database database;

  Future<int> strategyAccountId() async {
    final rows = await database.query(
      'accounts',
      columns: ['id'],
      where: 'role = ?',
      whereArgs: ['STRATEGY'],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Strategy account is missing');
    return rows.single['id'] as int;
  }

  Future<void> savePaperOrder(PaperOrder order) async {
    final accountId = await strategyAccountId();
    final now = DateTime.now().toUtc().toIso8601String();
    await database.insert(
        'orders',
        {
          'client_order_id': order.clientOrderId,
          'account_id': accountId,
          'symbol': 'BTCUSDT',
          'side': order.side.name.toUpperCase(),
          'order_type': 'MARKET',
          'status': _status(order.status),
          'requested_quantity': order.requestedBtc.toString(),
          'executed_quantity': order.executedBtc.toString(),
          'quote_quantity': order.executedQuote.toString(),
          'reason': 'PAPER_REBALANCE',
          'idempotency_key': order.idempotencyKey,
          'created_at': order.createdAt.toUtc().toIso8601String(),
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await database.update(
      'orders',
      {
        'status': _status(order.status),
        'executed_quantity': order.executedBtc.toString(),
        'quote_quantity': order.executedQuote.toString(),
        'updated_at': now,
      },
      where: 'idempotency_key = ?',
      whereArgs: [order.idempotencyKey],
    );
    if (order.status == SimulatedOrderStatus.filled &&
        order.executedBtc > Decimal.zero) {
      final rows = await database.query(
        'orders',
        columns: ['id'],
        where: 'idempotency_key = ?',
        whereArgs: [order.idempotencyKey],
        limit: 1,
      );
      await database.insert(
          'trades',
          {
            'order_id': rows.single['id'] as int,
            'exchange_trade_id': 'paper-trade:${order.clientOrderId}',
            'price': order.executionPrice.toString(),
            'btc_quantity': order.executedBtc.toString(),
            'usdt_quantity': order.executedQuote.toString(),
            'fee_asset': 'USDT',
            'fee_amount': order.fee.toString(),
            'executed_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> saveTransfer(TransferWrite transfer) async {
    final at = transfer.createdAt.toUtc().toIso8601String();
    await database.insert(
        'transfers',
        {
          'client_transfer_id': transfer.clientTransferId,
          'from_account_id': transfer.fromAccountId,
          'to_account_id': transfer.toAccountId,
          'asset': transfer.asset,
          'amount': transfer.amount.toString(),
          'before_balance': transfer.beforeBalance.toString(),
          'after_balance': transfer.afterBalance.toString(),
          'transfer_type': transfer.transferType,
          'status': transfer.status,
          'idempotency_key': transfer.idempotencyKey,
          'note': transfer.note,
          'created_at': at,
          'updated_at': at,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<PersistedOrder>> loadOpenOrders() async {
    final rows = await database.query(
      'orders',
      where:
          "status IN ('SUBMITTED', 'PARTIALLY_FILLED', 'ORDER_SUBMITTED', 'NEW', 'UNKNOWN')",
      orderBy: 'created_at ASC',
    );
    return rows
        .map(
          (row) => PersistedOrder(
            clientOrderId: row['client_order_id'] as String,
            exchangeOrderId: row['exchange_order_id'] as String?,
            symbol: row['symbol'] as String,
            status: row['status'] as String,
            idempotencyKey: row['idempotency_key'] as String,
            updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
          ),
        )
        .toList(growable: false);
  }

  Future<void> reconcileOrder({
    required String clientOrderId,
    required String exchangeOrderId,
    required String status,
    required Decimal executedQuantity,
    required Decimal quoteQuantity,
  }) async {
    await database.update(
      'orders',
      {
        'exchange_order_id': exchangeOrderId,
        'status': status,
        'executed_quantity': executedQuantity.toString(),
        'quote_quantity': quoteQuantity.toString(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'client_order_id = ?',
      whereArgs: [clientOrderId],
    );
  }

  Future<void> saveExchangeTrades({
    required String clientOrderId,
    required List<Map<String, dynamic>> trades,
  }) async {
    final rows = await database.query(
      'orders',
      columns: ['id'],
      where: 'client_order_id = ?',
      whereArgs: [clientOrderId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final orderId = rows.single['id'] as int;
    for (final trade in trades) {
      final tradeId = '${trade['id']}';
      await database.insert(
          'trades',
          {
            'order_id': orderId,
            'exchange_trade_id': tradeId,
            'price': '${trade['price'] ?? '0'}',
            'btc_quantity': '${trade['qty'] ?? '0'}',
            'usdt_quantity': '${trade['quoteQty'] ?? '0'}',
            'fee_asset': '${trade['commissionAsset'] ?? 'USDT'}',
            'fee_amount': '${trade['commission'] ?? '0'}',
            'executed_at': DateTime.fromMillisecondsSinceEpoch(
              (trade['time'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch,
              isUtc: true,
            ).toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<bool> containsOrderIdempotencyKey(String key) async =>
      (await database.rawQuery(
        'SELECT 1 FROM orders WHERE idempotency_key = ? LIMIT 1',
        [key],
      ))
          .isNotEmpty;
  Future<bool> containsTransferIdempotencyKey(String key) async =>
      (await database.rawQuery(
        'SELECT 1 FROM transfers WHERE idempotency_key = ? LIMIT 1',
        [key],
      ))
          .isNotEmpty;

  String _status(SimulatedOrderStatus status) => switch (status) {
        SimulatedOrderStatus.submitted => 'SUBMITTED',
        SimulatedOrderStatus.partiallyFilled => 'PARTIALLY_FILLED',
        SimulatedOrderStatus.filled => 'FILLED',
        SimulatedOrderStatus.rejected => 'REJECTED',
      };
}
