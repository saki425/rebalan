import '../domain/models.dart';
import '../performance/high_water_mark_manager.dart';
import '../performance/high_water_mark_repository.dart';
import 'execution_repository.dart';

enum RecoveryState {
  loadingDatabase,
  syncingBalances,
  syncingOrders,
  restoringHighWaterMark,
  syncingMarket,
  reconciling,
  ready,
  waitingOrder,
  blocked,
}

class RemoteRecoverySnapshot {
  const RemoteRecoverySnapshot({
    required this.accounts,
    required this.openClientOrderIds,
    required this.apiStatus,
    required this.websocketStatus,
    required this.priceUpdatedAt,
  });
  final List<AccountBalance> accounts;
  final Set<String> openClientOrderIds;
  final ConnectionStatus apiStatus;
  final ConnectionStatus websocketStatus;
  final DateTime priceUpdatedAt;
}

abstract interface class RecoveryRemoteSource {
  Future<RemoteRecoverySnapshot> fetchFullState();
}

class RecoveryReport {
  const RecoveryReport({
    required this.state,
    required this.tradingAllowed,
    required this.reason,
    required this.localOpenOrders,
    required this.highWaterMark,
  });
  final RecoveryState state;
  final bool tradingAllowed;
  final String reason;
  final List<PersistedOrder> localOpenOrders;
  final HighWaterMarkRecord? highWaterMark;
}

class RecoveryCoordinator {
  const RecoveryCoordinator({
    required this.executions,
    required this.highWaterMarks,
    required this.remote,
    this.maximumPriceAge = const Duration(seconds: 15),
  });
  final ExecutionRepository executions;
  final HighWaterMarkRepository highWaterMarks;
  final RecoveryRemoteSource remote;
  final Duration maximumPriceAge;

  Future<RecoveryReport> recover(DateTime now) async {
    try {
      final localOrders = await executions.loadOpenOrders();
      final hwm = await highWaterMarks.loadLatest();
      final remoteState = await remote.fetchFullState();
      if (remoteState.accounts.map((item) => item.role).toSet().length != 3) {
        return _blocked('REMOTE_ACCOUNTS_INCOMPLETE', localOrders, hwm);
      }
      if (remoteState.apiStatus != ConnectionStatus.connected) {
        return _blocked('API_NOT_CONNECTED', localOrders, hwm);
      }
      if (remoteState.websocketStatus != ConnectionStatus.connected) {
        return _blocked('WEBSOCKET_NOT_CONNECTED', localOrders, hwm);
      }
      if (now.difference(remoteState.priceUpdatedAt) > maximumPriceAge) {
        return _blocked('MARKET_PRICE_STALE', localOrders, hwm);
      }
      final localIds = localOrders.map((item) => item.clientOrderId).toSet();
      if (!localIds.containsAll(remoteState.openClientOrderIds) ||
          !remoteState.openClientOrderIds.containsAll(localIds)) {
        return _blocked('OPEN_ORDER_MISMATCH', localOrders, hwm);
      }
      if (localOrders.isNotEmpty) {
        return RecoveryReport(
          state: RecoveryState.waitingOrder,
          tradingAllowed: false,
          reason: 'UNFINISHED_ORDER_RECOVERED',
          localOpenOrders: localOrders,
          highWaterMark: hwm,
        );
      }
      return RecoveryReport(
        state: RecoveryState.ready,
        tradingAllowed: true,
        reason: 'RECONCILED',
        localOpenOrders: localOrders,
        highWaterMark: hwm,
      );
    } catch (error) {
      return RecoveryReport(
        state: RecoveryState.blocked,
        tradingAllowed: false,
        reason: 'RECOVERY_FAILED: $error',
        localOpenOrders: const [],
        highWaterMark: null,
      );
    }
  }

  RecoveryReport _blocked(
    String reason,
    List<PersistedOrder> orders,
    HighWaterMarkRecord? hwm,
  ) => RecoveryReport(
    state: RecoveryState.blocked,
    tradingAllowed: false,
    reason: reason,
    localOpenOrders: orders,
    highWaterMark: hwm,
  );
}
