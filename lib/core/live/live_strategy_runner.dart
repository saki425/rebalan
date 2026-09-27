import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';
import '../market/market_state.dart';
import '../strategy/rebalance_engine.dart';
import 'binance_live_client.dart';
import 'live_execution_service.dart';

/// One guarded LIVE strategy check.  The decision is shared with PAPER and
/// BACKTEST through RebalanceEngine; only order execution differs.
class LiveStrategyRunner {
  const LiveStrategyRunner({
    required this.database,
    required this.client,
    required this.accountId,
    this.rebalance = const RebalanceEngine(),
  });

  final Database database;
  final BinanceLiveClient client;
  final int accountId;
  final RebalanceEngine rebalance;

  Future<LiveStrategyCheckResult> check({
    required AccountBalance strategyAccount,
    required MarketState market,
    required Decimal targetBtcWeight,
    required Decimal triggerDeviation,
    required Decimal repairRatio,
    required String clientOrderId,
    required String idempotencyKey,
  }) async {
    if (market.websocketStatus != ConnectionStatus.connected ||
        market.apiStatus == ConnectionStatus.disconnected) {
      return const LiveStrategyCheckResult.blocked('MARKET_NOT_READY');
    }
    final open = await database.query(
      'orders',
      columns: ['id'],
      where: 'account_id = ? AND status IN (?, ?, ?)',
      whereArgs: [accountId, 'ORDER_SUBMITTED', 'NEW', 'PARTIALLY_FILLED'],
      limit: 1,
    );
    if (open.isNotEmpty) {
      return const LiveStrategyCheckResult.blocked('UNFINISHED_ORDER');
    }
    final decision = rebalance.evaluate(
      btcQuantity: strategyAccount.btc,
      usdtQuantity: strategyAccount.usdt,
      btcPrice: market.price,
      targetBtcWeight: targetBtcWeight,
      triggerDeviation: triggerDeviation,
      repairRatio: repairRatio,
    );
    if (!decision.shouldTrade) {
      return LiveStrategyCheckResult.noTrade(decision.reason);
    }
    final execution = LiveExecutionService(database: database, client: client);
    final response = await execution.marketOrder(
      accountId: accountId,
      side: decision.side == RebalanceSide.buy ? 'BUY' : 'SELL',
      requestedQuantity: decision.btcQuantity,
      referencePrice: market.price,
      clientOrderId: clientOrderId,
      idempotencyKey: idempotencyKey,
      reason: decision.reason,
    );
    return LiveStrategyCheckResult.submitted(
      reason: decision.reason,
      orderId: response.orderId,
      status: response.status,
    );
  }
}

class LiveStrategyCheckResult {
  const LiveStrategyCheckResult._({required this.status, required this.reason, this.orderId, this.orderStatus});
  const LiveStrategyCheckResult.blocked(String reason) : this._(status: LiveCheckStatus.blocked, reason: reason);
  const LiveStrategyCheckResult.noTrade(String reason) : this._(status: LiveCheckStatus.noTrade, reason: reason);
  const LiveStrategyCheckResult.submitted({required String reason, required String orderId, required String status}) : this._(status: LiveCheckStatus.submitted, reason: reason, orderId: orderId, orderStatus: status);
  final LiveCheckStatus status;
  final String reason;
  final String? orderId;
  final String? orderStatus;
}

enum LiveCheckStatus { blocked, noTrade, submitted }
