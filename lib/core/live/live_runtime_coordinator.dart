import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';
import '../market/binance_market_data_service.dart';
import 'binance_live_client.dart';
import 'credential_store.dart';
import 'live_strategy_runner.dart';
import 'live_reconciliation_service.dart';
import 'live_execution_service.dart';
import '../performance/high_water_mark_manager.dart';
import '../performance/high_water_mark_repository.dart';
import '../portfolio/portfolio_manager.dart';
import '../profit/profit_manager.dart';
import '../strategy/rebalance_engine.dart';

/// Runtime coordinator for the guarded LIVE path. It is intentionally opt-in:
/// callers must provide the explicit confirmation phrase and a restricted API.
class LiveRuntimeCoordinator {
  LiveRuntimeCoordinator({
    required this.database,
    required this.marketData,
    required this.credentials,
    required this.accountId,
    required this.config,
  });

  final Database database;
  final BinanceMarketDataService marketData;
  final BinanceCredentials credentials;
  final int accountId;
  final LiveRuntimeConfig config;
  final _events = StreamController<LiveRuntimeEvent>.broadcast();
  Timer? _timer;
  BinanceLiveClient? _client;
  LiveStrategyRunner? _runner;
  bool _checking = false;
  bool _paused = false;
  bool _wasWebsocketConnected = false;
  HighWaterMarkManager? _highWaterMark;

  Stream<LiveRuntimeEvent> get events => _events.stream;
  bool get isRunning => _timer?.isActive == true;

  Future<bool> start() async {
    if (isRunning) return true;
    if (!config.enabled ||
        config.confirmation != LiveTradingConfirmation.phrase ||
        !credentials.isValid) {
      _emit('LIVE_BLOCKED', 'EXPLICIT_CONFIRMATION_OR_CREDENTIALS_MISSING');
      return false;
    }
    final client = BinanceLiveClient(credentials: credentials);
    try {
      await client.synchronizeTime();
      final restrictions = await client.apiRestrictions();
      final ipRestricted = restrictions['ipRestrict'] == true;
      final withdrawals = restrictions['enableWithdrawals'] == true;
      final trading = restrictions['enableSpotAndMarginTrading'] == true;
      if (!ipRestricted || withdrawals || !trading) {
        _emit('LIVE_BLOCKED', 'API_PERMISSIONS_UNSAFE');
        client.close();
        return false;
      }
      _client = client;
      _runner = LiveStrategyRunner(
        database: database,
        client: client,
        accountId: accountId,
      );
      final reconciliation = await LiveReconciliationService(
        database: database,
        client: client,
      ).reconcile();
      if (!reconciliation.ok) {
        _paused = true;
        _emit('LIVE_PAUSED', reconciliation.reason);
        client.close();
        _client = null;
        _runner = null;
        return false;
      }
      await _initializeHighWaterMark(client);
      _timer = Timer.periodic(config.checkInterval, (_) => unawaited(_check()));
      await _check();
      return true;
    } catch (error) {
      client.close();
      _emit('LIVE_ERROR', '$error');
      return false;
    }
  }

  Future<void> _check() async {
    if (_checking || !isRunning) return;
    _checking = true;
    try {
      final market = marketData.current;
      final websocketConnected =
          market.websocketStatus == ConnectionStatus.connected;
      if (!websocketConnected || market.isStale(DateTime.now().toUtc())) {
        _paused = true;
        _wasWebsocketConnected = false;
        _emit('LIVE_PAUSED', 'WEBSOCKET_DISCONNECTED_OR_PRICE_STALE');
        return;
      }
      if (_paused || !_wasWebsocketConnected) {
        final reconciliation = await LiveReconciliationService(
          database: database,
          client: _client!,
        ).reconcile();
        if (!reconciliation.ok) {
          _paused = true;
          _emit('LIVE_PAUSED', reconciliation.reason);
          return;
        }
        _paused = false;
        _emit('LIVE_RECONCILED', reconciliation.reason);
      }
      _wasWebsocketConnected = true;
      final account = await _readStrategyAccount(_client!);
      await _observeHighWaterMark(account, market.price);
      final result = await _runner!.check(
        strategyAccount: account,
        market: market,
        targetBtcWeight: config.targetBtcWeight,
        triggerDeviation: config.triggerDeviation,
        repairRatio: config.repairRatio,
        clientOrderId: 'live-${DateTime.now().toUtc().microsecondsSinceEpoch}',
        idempotencyKey: 'live-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      );
      _emit(result.status.name.toUpperCase(), result.reason);
      if (result.status == LiveCheckStatus.submitted &&
          result.orderStatus == 'FILLED') {
        await _maybeWithdrawProfit(account, market.price, result);
      }
    } catch (error) {
      _emit('LIVE_ERROR', '$error');
    } finally {
      _checking = false;
    }
  }

  Future<void> _maybeWithdrawProfit(
    AccountBalance account,
    Decimal price,
    LiveStrategyCheckResult result,
  ) async {
    if (!config.enableProfitWithdrawal ||
        _highWaterMark == null ||
        result.side != RebalanceSide.sell) {
      return;
    }
    final profitCredentials =
        await const SecureCredentialStore().read(AccountRole.profit);
    if (profitCredentials == null || !profitCredentials.isValid) {
      _emit('PROFIT_WITHDRAWAL_BLOCKED', 'PROFIT_ACCOUNT_CREDENTIALS_MISSING');
      return;
    }
    final row = await database.query(
      'accounts',
      columns: ['id', 'binance_email'],
      where: 'role = ?',
      whereArgs: ['PROFIT'],
      limit: 1,
    );
    final toEmail = row.isEmpty ? null : row.single['binance_email'] as String?;
    if (toEmail == null || toEmail.isEmpty) {
      _emit('PROFIT_WITHDRAWAL_BLOCKED', 'PROFIT_ACCOUNT_EMAIL_MISSING');
      return;
    }
    final refreshed = await _readStrategyAccount(_client!);
    final decision = const ProfitManager().evaluate(
      ProfitWithdrawalRequest(
        side: RebalanceSide.sell,
        orderFilled: true,
        strategyBtc: refreshed.btc,
        strategyUsdt: refreshed.usdt,
        btcPrice: price,
        availableProfitUsdt: refreshed.usdt,
        safeTransferLimit: config.safeTransferLimit,
        withdrawalRatio: config.profitWithdrawalRatio,
        maxBtcWeightAfterTransfer: config.maxBtcWeightAfterProfitTransfer,
        enabled: true,
      ),
      _highWaterMark!,
    );
    if (!decision.shouldTransfer) {
      _emit('PROFIT_WITHDRAWAL_SKIPPED', decision.reason.name.toUpperCase());
      return;
    }
    final profitAccountId = row.single['id'] as int;
    final execution =
        LiveExecutionService(database: database, client: _client!);
    await execution.siblingTransfer(
      fromAccountId: accountId,
      toAccountId: profitAccountId,
      toEmail: toEmail,
      asset: 'USDT',
      amount: decision.transferAmount,
      clientTransferId:
          'profit-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      idempotencyKey: 'profit-${result.orderId}-${decision.transferAmount}',
      transferType: 'PROFIT_WITHDRAWAL',
      note: 'LIVE_FILLED_SELL:${result.orderId}',
    );
    final now = DateTime.now().toUtc();
    _highWaterMark!.crystallize(
      equityBeforeWithdrawal: decision.currentEquity,
      profitWithdrawal: decision.transferAmount,
      at: now,
    );
    await HighWaterMarkRepository(database).save(
      HighWaterMarkRecord(
        value: _highWaterMark!.value,
        reason: 'LIVE_PROFIT_CRYSTALLIZED',
        effectiveAt: now,
      ),
    );
    _emit('PROFIT_WITHDRAWAL_FILLED', decision.transferAmount.toString());
  }

  Future<void> _initializeHighWaterMark(BinanceLiveClient client) async {
    final account = await _readStrategyAccount(client);
    final price = marketData.current.price;
    if (price <= Decimal.zero) throw StateError('LIVE price is unavailable');
    final equity = const PortfolioManager()
        .valueAmounts(
          btcQuantity: account.btc,
          usdtQuantity: account.usdt,
          btcPrice: price,
        )
        .totalEquity;
    final repository = HighWaterMarkRepository(database);
    final latest = await repository.loadLatest();
    final liveLatest = latest != null && latest.reason.startsWith('LIVE_')
        ? latest
        : null;
    _highWaterMark = HighWaterMarkManager(
      initialHighWaterMark: liveLatest?.value ?? equity,
    );
    if (liveLatest == null) {
      await repository.save(
        HighWaterMarkRecord(
          value: equity,
          reason: 'LIVE_INITIAL_EQUITY',
          effectiveAt: DateTime.now().toUtc(),
        ),
      );
    }
  }

  Future<void> _observeHighWaterMark(
    AccountBalance account,
    Decimal price,
  ) async {
    final manager = _highWaterMark;
    if (manager == null || price <= Decimal.zero) return;
    final equity = const PortfolioManager()
        .valueAmounts(
          btcQuantity: account.btc,
          usdtQuantity: account.usdt,
          btcPrice: price,
        )
        .totalEquity;
    final before = manager.value;
    final now = DateTime.now().toUtc();
    manager.commitObservedHigh(equity, now);
    if (manager.value > before) {
      await HighWaterMarkRepository(database).save(
        HighWaterMarkRecord(
          value: manager.value,
          reason: 'LIVE_NEW_HIGH_COMMITTED',
          effectiveAt: now,
        ),
      );
    }
  }

  Future<AccountBalance> _readStrategyAccount(BinanceLiveClient client) async {
    final data = await client.account();
    final balances =
        (data['balances'] as List<dynamic>).cast<Map<String, dynamic>>();
    Decimal balance(String asset) {
      final row = balances.firstWhere((item) => item['asset'] == asset,
          orElse: () => {'free': '0', 'locked': '0'});
      return Decimal.parse(row['free'] as String) +
          Decimal.parse(row['locked'] as String);
    }

    return AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy Account',
        btc: balance('BTC'),
        usdt: balance('USDT'));
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _client?.close();
    _client = null;
    _runner = null;
    _highWaterMark = null;
    _paused = false;
    _wasWebsocketConnected = false;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  void _emit(String state, String reason) {
    if (!_events.isClosed) {
      _events.add(LiveRuntimeEvent(state: state, reason: reason));
    }
  }
}

class LiveRuntimeConfig {
  LiveRuntimeConfig(
      {required this.enabled,
      required this.confirmation,
      required this.checkInterval,
      required this.targetBtcWeight,
      required this.triggerDeviation,
      required this.repairRatio,
      this.enableProfitWithdrawal = false,
      Decimal? profitWithdrawalRatio,
      Decimal? safeTransferLimit,
      Decimal? maxBtcWeightAfterProfitTransfer})
      : profitWithdrawalRatio = profitWithdrawalRatio ?? Decimal.parse('0.20'),
        safeTransferLimit = safeTransferLimit ?? Decimal.zero,
        maxBtcWeightAfterProfitTransfer =
            maxBtcWeightAfterProfitTransfer ?? Decimal.parse('0.58');
  final bool enabled;
  final String confirmation;
  final Duration checkInterval;
  final Decimal targetBtcWeight, triggerDeviation, repairRatio;
  final bool enableProfitWithdrawal;
  final Decimal profitWithdrawalRatio;
  final Decimal safeTransferLimit;
  final Decimal maxBtcWeightAfterProfitTransfer;
}

class LiveTradingConfirmation {
  static const phrase = 'ENABLE LIVE TRADING';
}

class LiveRuntimeEvent {
  const LiveRuntimeEvent({required this.state, required this.reason});
  final String state;
  final String reason;
}
