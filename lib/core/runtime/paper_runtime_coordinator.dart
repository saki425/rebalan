import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:decimal/decimal.dart';

import '../../features/settings/strategy_config_repository.dart';
import '../domain/models.dart';
import '../market/binance_market_data_service.dart';
import '../market/market_state.dart';
import '../paper/paper_trading_engine.dart';
import '../performance/high_water_mark_manager.dart';
import '../performance/high_water_mark_repository.dart';
import '../performance/performance_manager.dart';
import '../profit/paper_profit_executor.dart';
import '../profit/profit_manager.dart';
import '../profit/profit_withdrawal_repository.dart';
import '../recovery/execution_repository.dart';
import '../strategy/account2_strategy_runner.dart';
import '../notifications/notification_service.dart';

class PaperRuntimeCoordinator {
  PaperRuntimeCoordinator({
    required this.database,
    required this.marketData,
    required this.strategyAccount,
    required this.profitAccount,
    this.notifications,
  });

  final Database database;
  final BinanceMarketDataService marketData;
  final AccountBalance strategyAccount;
  final AccountBalance profitAccount;
  final NotificationService? notifications;
  final _states = StreamController<StrategyRuntimeEvent>.broadcast();
  Account2StrategyRunner? _runner;
  StreamSubscription<StrategyRuntimeEvent>? _subscription;
  Future<void> _writes = Future.value();
  HighWaterMarkManager? _highWaterMark;
  PerformanceManager? _performance;
  late AccountBalance _paperProfitAccount;
  late Map<String, String> _configuration;

  Stream<StrategyRuntimeEvent> get states => _states.stream;
  bool get isRunning => _runner?.isRunning == true;

  StrategyRuntimeEvent evaluateNow(MarketState market, DateTime now) {
    final runner = _runner;
    if (runner == null) throw StateError('Paper runtime is not running');
    runner.updateMarketState(market);
    return runner.checkNow(now);
  }

  Future<bool> start() async {
    if (isRunning) return true;
    final configRepository = StrategyConfigRepository(database);
    final values = await configRepository.load();
    if (values['runMode'] != 'PAPER' ||
        values['enableAutoRebalance'] != 'true') {
      return false;
    }
    if (marketData.current.price <= Decimal.zero) return false;
    final config = await configRepository.loadPaperConfig();
    _configuration = values;
    _paperProfitAccount = profitAccount;
    final latestHigh = await HighWaterMarkRepository(database).loadLatest();
    final initialEquity = strategyAccount.equity(marketData.current.price);
    _highWaterMark = HighWaterMarkManager(
      initialHighWaterMark: latestHigh?.value ?? initialEquity,
    );
    _performance = PerformanceManager(initialCapital: initialEquity);
    if (latestHigh == null) {
      await HighWaterMarkRepository(database).save(
        HighWaterMarkRecord(
          value: initialEquity,
          reason: 'INITIALIZED',
          effectiveAt: DateTime.now().toUtc(),
        ),
      );
    }
    final runner = Account2StrategyRunner(
      paperEngine: PaperTradingEngine(
        broker: PaperBroker(
          initialBtc: strategyAccount.btc,
          initialUsdt: strategyAccount.usdt,
          feeRate: config.feeRate,
          slippageRate: config.slippageRate,
        ),
        config: config,
      ),
      checkInterval: Duration(
        seconds: int.parse(values['strategyCheckInterval']!),
      ),
    );
    _runner = runner;
    _subscription = runner.events.listen((event) {
      if (!_states.isClosed) _states.add(event);
      if (event.state == StrategyRuntimeState.filled && event.order != null) {
        unawaited(_notifyTrade(event.order!));
      }
      _writes = _writes.then((_) async {
        await _persist(event);
        await _withdrawProfit(event);
      });
    });
    runner.start(marketData.states);
    if (marketData.current.lastEventAt != null) {
      runner.updateMarketState(marketData.current);
    }
    return true;
  }

  Future<void> _notifyTrade(PaperOrder order) async {
    try {
      await notifications?.tradeFilled(order);
    } catch (_) {
      // Notification failure must never interrupt trading or persistence.
    }
  }

  Future<void> _withdrawProfit(StrategyRuntimeEvent event) async {
    final order = event.order;
    final runner = _runner;
    if (event.state != StrategyRuntimeState.filled ||
        order == null ||
        order.side.name != 'sell' ||
        runner == null) {
      return;
    }
    final broker = runner.paperEngine.broker;
    final at = event.occurredAt.toUtc();
    final executor = PaperProfitExecutor(
      strategyAccount: AccountBalance(
        role: AccountRole.strategy,
        name: strategyAccount.name,
        btc: broker.btc,
        usdt: broker.usdt,
      ),
      profitAccount: _paperProfitAccount,
      highWaterMark: _highWaterMark!,
      performance: _performance!,
    );
    final transfer = executor.execute(
      idempotencyKey: '${order.idempotencyKey}:profit',
      at: at,
      request: ProfitWithdrawalRequest(
        side: order.side,
        orderFilled: true,
        strategyBtc: broker.btc,
        strategyUsdt: broker.usdt,
        btcPrice: order.marketPrice,
        availableProfitUsdt: broker.usdt,
        safeTransferLimit: Decimal.parse(
          _configuration['safeProfitTransferLimit']!,
        ),
        withdrawalRatio: Decimal.parse(
          _configuration['profitWithdrawalRatio']!,
        ),
        maxBtcWeightAfterTransfer: Decimal.parse(
          _configuration['maxBTCWeightAfterProfitTransfer']!,
        ),
        enabled: _configuration['enableProfitWithdrawal'] == 'true',
      ),
    );
    if (transfer == null) return;
    broker.withdrawUsdt(transfer.amount);
    _paperProfitAccount = executor.profitAccount;
    final record = _highWaterMark!.history.last;
    await ProfitWithdrawalRepository(database).save(
      transfer: transfer,
      highWaterMark: record,
      strategyClientOrderId: order.clientOrderId,
      btcPrice: order.marketPrice.toString(),
    );
  }

  Future<void> _persist(StrategyRuntimeEvent event) async {
    if (event.order case final order?) {
      await ExecutionRepository(database).savePaperOrder(order);
    }
    await database.insert('strategy_events', {
      'event_type': event.state.name.toUpperCase(),
      'state_to': event.state.name.toUpperCase(),
      'reason': event.reason,
      'payload_json': event.order == null
          ? null
          : jsonEncode({
              'clientOrderId': event.order!.clientOrderId,
              'status': event.order!.status.name,
              'executedBtc': event.order!.executedBtc.toString(),
              'executedQuote': event.order!.executedQuote.toString(),
              'fee': event.order!.fee.toString(),
            }),
      'correlation_id': event.order?.clientOrderId,
      'created_at': event.occurredAt.toUtc().toIso8601String(),
    });
  }

  Future<void> stop() async {
    await _runner?.stop();
    // Broadcast stream delivery is asynchronous. Allow the final FILLED event
    // to reach the persistence queue before cancelling its subscription.
    await Future<void>.delayed(Duration.zero);
    await _subscription?.cancel();
    _subscription = null;
    await _writes;
    _runner = null;
  }

  Future<void> dispose() async {
    await stop();
    await _states.close();
  }
}
