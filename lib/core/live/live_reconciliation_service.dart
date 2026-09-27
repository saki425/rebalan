import 'package:sqflite/sqflite.dart';
import 'package:decimal/decimal.dart';

import '../recovery/execution_repository.dart';
import 'binance_live_client.dart';

class LiveReconciliationResult {
  const LiveReconciliationResult({
    required this.ok,
    required this.reason,
    required this.recoveredOrders,
  });
  final bool ok;
  final String reason;
  final int recoveredOrders;
}

/// Repairs local order/trade state from Binance after startup or a websocket
/// reconnect. It is deliberately conservative: an unknown remote status
/// blocks trading instead of retrying an order.
class LiveReconciliationService {
  LiveReconciliationService({required this.database, required this.client});

  final Database database;
  final BinanceLiveClient client;

  Future<LiveReconciliationResult> reconcile() async {
    final repository = ExecutionRepository(database);
    final local = await repository.loadOpenOrders();
    final remoteRows = await client.openOrders();
    final remoteIds =
        remoteRows.map((row) => '${row['clientOrderId']}').toSet();
    var recovered = 0;

    for (final order in local) {
      final response = order.exchangeOrderId == null
          ? await client.queryOrder(
              symbol: order.symbol,
              clientOrderId: order.clientOrderId,
            )
          : await client.queryOrderById(
              symbol: order.symbol,
              orderId: order.exchangeOrderId!,
            );
      await repository.reconcileOrder(
        clientOrderId: order.clientOrderId,
        exchangeOrderId: response.orderId,
        status: _normalizeStatus(response.status),
        executedQuantity: response.executedQuantity,
        quoteQuantity: response.cumulativeQuoteQuantity,
      );
      if (response.executedQuantity > Decimal.zero) {
        final trades = await client.myTrades(
          symbol: order.symbol,
          orderId: response.orderId,
        );
        await repository.saveExchangeTrades(
          clientOrderId: order.clientOrderId,
          trades: trades,
        );
      }
      recovered++;
    }

    final localAfter = await repository.loadOpenOrders();
    final localIds = localAfter.map((item) => item.clientOrderId).toSet();
    if (!localIds.containsAll(remoteIds) || !remoteIds.containsAll(localIds)) {
      return LiveReconciliationResult(
        ok: false,
        reason: 'LOCAL_BINANCE_ORDER_MISMATCH',
        recoveredOrders: recovered,
      );
    }
    return LiveReconciliationResult(
      ok: true,
      reason: recovered == 0 ? 'RECONCILED' : 'ORDERS_RECOVERED',
      recoveredOrders: recovered,
    );
  }

  String _normalizeStatus(String status) => switch (status) {
        'NEW' => 'NEW',
        'PARTIALLY_FILLED' => 'PARTIALLY_FILLED',
        'FILLED' => 'FILLED',
        'CANCELED' => 'CANCELED',
        'REJECTED' => 'CANCELED',
        'EXPIRED' => 'CANCELED',
        _ => status,
      };
}
