import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/database/database_service.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/paper/paper_trading_engine.dart';
import 'package:rebalance/core/performance/high_water_mark_manager.dart';
import 'package:rebalance/core/performance/high_water_mark_repository.dart';
import 'package:rebalance/core/recovery/execution_repository.dart';
import 'package:rebalance/core/recovery/recovery_coordinator.dart';
import 'package:rebalance/core/strategy/rebalance_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeRemoteSource implements RecoveryRemoteSource {
  FakeRemoteSource(this.snapshot);
  final RemoteRecoverySnapshot snapshot;
  @override
  Future<RemoteRecoverySnapshot> fetchFullState() async => snapshot;
}

void main() {
  setUpAll(sqfliteFfiInit);
  final now = DateTime.utc(2026, 1, 1, 12);

  List<AccountBalance> accounts() => [
    AccountBalance(
      role: AccountRole.funding,
      name: 'Funding',
      btc: Decimal.zero,
      usdt: Decimal.zero,
    ),
    AccountBalance(
      role: AccountRole.strategy,
      name: 'Strategy',
      btc: Decimal.one,
      usdt: Decimal.parse('50000'),
    ),
    AccountBalance(
      role: AccountRole.profit,
      name: 'Profit',
      btc: Decimal.zero,
      usdt: Decimal.zero,
    ),
  ];

  PaperOrder order(String id, SimulatedOrderStatus status) => PaperOrder(
    clientOrderId: id,
    idempotencyKey: 'idem-$id',
    side: RebalanceSide.sell,
    marketPrice: Decimal.parse('75000'),
    executionPrice: Decimal.parse('75000'),
    requestedQuote: Decimal.parse('3125'),
    requestedBtc: Decimal.parse('0.041666666666666666'),
    executedQuote: status == SimulatedOrderStatus.partiallyFilled
        ? Decimal.parse('1000')
        : Decimal.zero,
    executedBtc: status == SimulatedOrderStatus.partiallyFilled
        ? Decimal.parse('0.013333333333333333')
        : Decimal.zero,
    fee: Decimal.zero,
    status: status,
    createdAt: now,
  );

  test('order and transfer writes are database-idempotent', () async {
    final db = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final repository = ExecutionRepository(db);
    final paperOrder = order('paper-1', SimulatedOrderStatus.submitted);
    await repository.savePaperOrder(paperOrder);
    await repository.savePaperOrder(paperOrder);
    expect(await db.query('orders'), hasLength(1));

    final accountRows = await db.query('accounts', orderBy: 'id');
    final transfer = TransferWrite(
      clientTransferId: 'transfer-1',
      fromAccountId: accountRows[1]['id'] as int,
      toAccountId: accountRows[2]['id'] as int,
      asset: 'USDT',
      amount: Decimal.parse('1000'),
      beforeBalance: Decimal.parse('45000'),
      afterBalance: Decimal.parse('44000'),
      transferType: 'PROFIT_WITHDRAWAL',
      status: 'SUCCESS',
      idempotencyKey: 'profit-order-1',
      createdAt: now,
    );
    await repository.saveTransfer(transfer);
    await repository.saveTransfer(transfer);
    expect(await db.query('transfers'), hasLength(1));
  });

  test(
    'restart restores unfinished order and never permits duplicate order',
    () async {
      final db = await DatabaseService.open(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(db.close);
      final executions = ExecutionRepository(db);
      await executions.savePaperOrder(
        order('paper-open', SimulatedOrderStatus.partiallyFilled),
      );
      final hwmRepository = HighWaterMarkRepository(db);
      await hwmRepository.save(
        HighWaterMarkRecord(
          value: Decimal.parse('100000'),
          reason: 'INITIALIZED',
          effectiveAt: now,
        ),
      );
      final coordinator = RecoveryCoordinator(
        executions: executions,
        highWaterMarks: hwmRepository,
        remote: FakeRemoteSource(
          RemoteRecoverySnapshot(
            accounts: accounts(),
            openClientOrderIds: {'paper-open'},
            apiStatus: ConnectionStatus.connected,
            websocketStatus: ConnectionStatus.connected,
            priceUpdatedAt: now,
          ),
        ),
      );
      final report = await coordinator.recover(now);
      expect(report.state, RecoveryState.waitingOrder);
      expect(report.tradingAllowed, isFalse);
      expect(report.localOpenOrders.single.clientOrderId, 'paper-open');
      expect(report.highWaterMark?.value, Decimal.parse('100000'));
    },
  );

  test('unknown remote order blocks startup instead of blind retry', () async {
    final db = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final coordinator = RecoveryCoordinator(
      executions: ExecutionRepository(db),
      highWaterMarks: HighWaterMarkRepository(db),
      remote: FakeRemoteSource(
        RemoteRecoverySnapshot(
          accounts: accounts(),
          openClientOrderIds: {'unknown-binance-order'},
          apiStatus: ConnectionStatus.connected,
          websocketStatus: ConnectionStatus.connected,
          priceUpdatedAt: now,
        ),
      ),
    );
    final report = await coordinator.recover(now);
    expect(report.state, RecoveryState.blocked);
    expect(report.reason, 'OPEN_ORDER_MISMATCH');
    expect(report.tradingAllowed, isFalse);
  });

  test('healthy fully reconciled state becomes ready', () async {
    final db = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final coordinator = RecoveryCoordinator(
      executions: ExecutionRepository(db),
      highWaterMarks: HighWaterMarkRepository(db),
      remote: FakeRemoteSource(
        RemoteRecoverySnapshot(
          accounts: accounts(),
          openClientOrderIds: const {},
          apiStatus: ConnectionStatus.connected,
          websocketStatus: ConnectionStatus.connected,
          priceUpdatedAt: now,
        ),
      ),
    );
    final report = await coordinator.recover(now);
    expect(report.state, RecoveryState.ready);
    expect(report.tradingAllowed, isTrue);
  });

  test('stale price and disconnected API block startup', () async {
    final db = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    Future<RecoveryReport> recover(RemoteRecoverySnapshot snapshot) =>
        RecoveryCoordinator(
          executions: ExecutionRepository(db),
          highWaterMarks: HighWaterMarkRepository(db),
          remote: FakeRemoteSource(snapshot),
        ).recover(now);
    final stale = await recover(
      RemoteRecoverySnapshot(
        accounts: accounts(),
        openClientOrderIds: const {},
        apiStatus: ConnectionStatus.connected,
        websocketStatus: ConnectionStatus.connected,
        priceUpdatedAt: now.subtract(const Duration(seconds: 16)),
      ),
    );
    expect(stale.reason, 'MARKET_PRICE_STALE');
    final apiDown = await recover(
      RemoteRecoverySnapshot(
        accounts: accounts(),
        openClientOrderIds: const {},
        apiStatus: ConnectionStatus.disconnected,
        websocketStatus: ConnectionStatus.connected,
        priceUpdatedAt: now,
      ),
    );
    expect(apiDown.reason, 'API_NOT_CONNECTED');
  });

  test(
    'websocket disconnect pauses and a fresh reconciled state resumes',
    () async {
      final db = await DatabaseService.open(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(db.close);
      Future<RecoveryReport> recover(ConnectionStatus websocket) =>
          RecoveryCoordinator(
            executions: ExecutionRepository(db),
            highWaterMarks: HighWaterMarkRepository(db),
            remote: FakeRemoteSource(
              RemoteRecoverySnapshot(
                accounts: accounts(),
                openClientOrderIds: const {},
                apiStatus: ConnectionStatus.connected,
                websocketStatus: websocket,
                priceUpdatedAt: now,
              ),
            ),
          ).recover(now);
      final paused = await recover(ConnectionStatus.disconnected);
      expect(paused.tradingAllowed, isFalse);
      expect(paused.reason, 'WEBSOCKET_NOT_CONNECTED');
      final resumed = await recover(ConnectionStatus.connected);
      expect(resumed.tradingAllowed, isTrue);
      expect(resumed.reason, 'RECONCILED');
    },
  );
}
