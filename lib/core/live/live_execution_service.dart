import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import 'binance_live_client.dart';
import 'symbol_trading_rules.dart';

class LiveExecutionService {
  const LiveExecutionService({required this.database, required this.client});

  final Database database;
  final BinanceLiveClient client;

  Future<LiveOrderResponse> marketOrder({
    required int accountId,
    required String side,
    required Decimal requestedQuantity,
    required Decimal referencePrice,
    required String clientOrderId,
    required String idempotencyKey,
    required String reason,
    String symbol = 'BTCUSDT',
  }) async {
    final existing = await database.query(
      'orders',
      where: 'idempotency_key = ? OR client_order_id = ?',
      whereArgs: [idempotencyKey, clientOrderId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      throw DuplicateLiveExecutionException(idempotencyKey);
    }
    final rules = SymbolTradingRules.fromExchangeInfo(
      await client.exchangeInfo(symbol: symbol),
      symbol,
    );
    final quantity = rules.validateAndNormalize(
      requestedQuantity: requestedQuantity,
      referencePrice: referencePrice,
    );
    final now = DateTime.now().toUtc().toIso8601String();
    await database.insert('orders', {
      'client_order_id': clientOrderId,
      'account_id': accountId,
      'symbol': symbol,
      'side': side,
      'order_type': 'MARKET',
      'status': 'ORDER_SUBMITTED',
      'requested_quantity': quantity.toString(),
      'executed_quantity': '0',
      'quote_quantity': '0',
      'reason': reason,
      'idempotency_key': idempotencyKey,
      'created_at': now,
      'updated_at': now,
    });
    try {
      final response = await client.placeMarketOrder(
        symbol: symbol,
        side: side,
        quantity: quantity,
        clientOrderId: clientOrderId,
      );
      await _updateOrder(response, clientOrderId);
      return response;
    } on OrderStatusUnknownException {
      await database.update(
        'orders',
        {
          'status': 'UNKNOWN',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'client_order_id = ?',
        whereArgs: [clientOrderId],
      );
      rethrow;
    } catch (_) {
      await database.update(
        'orders',
        {
          'status': 'ERROR',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'client_order_id = ?',
        whereArgs: [clientOrderId],
      );
      rethrow;
    }
  }

  Future<String> siblingTransfer({
    required int fromAccountId,
    required int toAccountId,
    required String toEmail,
    required String asset,
    required Decimal amount,
    required String clientTransferId,
    required String idempotencyKey,
    required String transferType,
    String? note,
  }) async {
    if (amount <= Decimal.zero) throw ArgumentError.value(amount, 'amount');
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await database.insert('transfers', {
        'client_transfer_id': clientTransferId,
        'from_account_id': fromAccountId,
        'to_account_id': toAccountId,
        'asset': asset,
        'amount': amount.toString(),
        'transfer_type': transferType,
        'status': 'SUBMITTED',
        'idempotency_key': idempotencyKey,
        'note': note,
        'created_at': now,
        'updated_at': now,
      });
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw DuplicateLiveExecutionException(idempotencyKey);
      }
      rethrow;
    }
    try {
      final transferId = await client.transferToSibling(
        toEmail: toEmail,
        asset: asset,
        amount: amount,
      );
      await database.update(
        'transfers',
        {
          'exchange_transfer_id': transferId,
          'status': 'SUCCESS',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'idempotency_key = ?',
        whereArgs: [idempotencyKey],
      );
      return transferId;
    } catch (_) {
      // A transport failure can mean Binance accepted the transfer. It is
      // intentionally UNKNOWN and must be reconciled, never blindly retried.
      await database.update(
        'transfers',
        {
          'status': 'UNKNOWN',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'idempotency_key = ?',
        whereArgs: [idempotencyKey],
      );
      rethrow;
    }
  }

  Future<void> _updateOrder(LiveOrderResponse response, String clientOrderId) =>
      database.update(
        'orders',
        {
          'exchange_order_id': response.orderId,
          'status': response.status,
          'executed_quantity': response.executedQuantity.toString(),
          'quote_quantity': response.cumulativeQuoteQuantity.toString(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'client_order_id = ?',
        whereArgs: [clientOrderId],
      );
}

class DuplicateLiveExecutionException implements Exception {
  const DuplicateLiveExecutionException(this.idempotencyKey);
  final String idempotencyKey;

  @override
  String toString() => 'DuplicateLiveExecutionException($idempotencyKey)';
}
