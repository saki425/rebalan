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
import 'live_transfer_reconciliation_service.dart';
import '../performance/high_water_mark_manager.dart';
import '../performance/high_water_mark_repository.dart';
import '../portfolio/portfolio_manager.dart';
import '../accounts/account_read_client.dart';
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
    this.accountBalances,
  });

  final Database database;
  final BinanceMarketDataService marketData;
  final BinanceCredentials credentials;
  final int accountId;
  final LiveRuntimeConfig config;
  final AccountBalanceSource? accountBalances;
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
    _log('start requested enabled=${config.enabled} accountId=$accountId');
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
      await LiveTransferReconciliationService(
        database: database,
        client: client,
      ).reconcileUnknownTransfers();
      await _reconcileAllBalances(client);
      if (!reconciliation.ok) {
        _paused = true;
        _emit('LIVE_PAUSED', reconciliation.reason);
        _log('startup reconciliation FAILED: ${reconciliation.reason}');
        client.close();
        _client = null;
        _runner = null;
        return false;
      }
      await _initializeHighWaterMark(client);
      _log('startup reconciliation OK; LIVE HWM ready');
      _timer = Timer.periodic(config.checkInterval, (_) => unawaited(_check()));
      await _check();
      return true;
    } catch (error) {
      client.close();
      _emit('LIVE_ERROR', '$error');
      _log('start ERROR: $error');
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
        _log(
            'paused websocket=${market.websocketStatus} price=${market.price}');
        return;
      }
      if (_paused || !_wasWebsocketConnected) {
        final reconciliation = await LiveReconciliationService(
          database: database,
          client: _client!,
        ).reconcile();
        await LiveTransferReconciliationService(
          database: database,
          client: _client!,
        ).reconcileUnknownTransfers();
        await _reconcileAllBalances(_client!);
        if (!reconciliation.ok) {
          _paused = true;
          _emit('LIVE_PAUSED', reconciliation.reason);
          _log('reconnect reconciliation FAILED: ${reconciliation.reason}');
          return;
        }
        _paused = false;
        _emit('LIVE_RECONCILED', reconciliation.reason);
        _log('reconnect reconciliation OK: ${reconciliation.reason}');
      }
      _wasWebsocketConnected = true;
      final account = await _readStrategyAccount(_client!);
      _log(
          'check price=${market.price} BTC=${account.btc} USDT=${account.usdt}');
      await _savePortfolioSnapshot(account, market.price);
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
      _log(
          'result=${result.status.name} reason=${result.reason} order=${result.orderId ?? '-'} status=${result.orderStatus ?? '-'}');
      if (result.status == LiveCheckStatus.submitted &&
          result.orderStatus == 'FILLED') {
        await _maybeWithdrawProfit(account, market.price, result);
      }
    } catch (error) {
      _emit('LIVE_ERROR', '$error');
      _log('check ERROR: $error');
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
    _log('profit evaluation after SELL order=${result.orderId}');
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
      _log(
          'profit skipped reason=${decision.reason.name} newProfit=${decision.newProfit} transfer=${decision.transferAmount}');
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
    final transferRows = await database.query(
      'transfers',
      columns: ['id'],
      where: 'idempotency_key = ?',
      whereArgs: ['profit-${result.orderId}-${decision.transferAmount}'],
      limit: 1,
    );
    if (transferRows.isNotEmpty) {
      final orderRows = await database.query(
        'orders',
        columns: ['id'],
        where: 'exchange_order_id = ?',
        whereArgs: [result.orderId],
        limit: 1,
      );
      final tradeRows = orderRows.isEmpty
          ? const <Map<String, Object?>>[]
          : await database.query(
              'trades',
              columns: ['id'],
              where: 'order_id = ?',
              whereArgs: [orderRows.single['id']],
              limit: 1,
            );
      await database.insert(
          'profit_withdrawals',
          {
            'transfer_id': transferRows.single['id'],
            'strategy_trade_id':
                tradeRows.isEmpty ? null : tradeRows.single['id'],
            'btc_price': price.toString(),
            'strategy_equity': decision.currentEquity.toString(),
            'high_water_mark': decision.highWaterMark.toString(),
            'new_profit': decision.newProfit.toString(),
            'withdrawal_ratio': config.profitWithdrawalRatio.toString(),
            'actual_amount': decision.transferAmount.toString(),
            'created_at': DateTime.now().toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
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
    _log('profit transfer submitted amount=${decision.transferAmount}');
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
    final liveLatest =
        latest != null && latest.reason.startsWith('LIVE_') ? latest : null;
    _log('HWM equity=$equity previous=${liveLatest?.value ?? '-'}');
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
      _log('HWM initialized value=$equity');
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
      _log('HWM advanced $before -> ${manager.value}');
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

  Future<void> _reconcileAllBalances(BinanceLiveClient client) async {
    final source = accountBalances;
    if (source == null) return;
    final balances = await source.fetchBalances();
    final rows = await database.query('accounts', columns: ['id', 'role']);
    final ids = {
      for (final row in rows) row['role'] as String: row['id'] as int
    };
    final price = marketData.current.price;
    if (price <= Decimal.zero)
      throw StateError('REST balance reconcile needs price');
    final now = DateTime.now().toUtc().toIso8601String();
    final batch = database.batch();
    for (final balance in balances) {
      final id = ids[balance.role.name.toUpperCase()];
      if (id == null)
        throw StateError('Missing local account ${balance.role.name}');
      batch.insert('account_snapshots', {
        'account_id': id,
        'btc_balance': balance.btc.toString(),
        'usdt_balance': balance.usdt.toString(),
        'btc_price': price.toString(),
        'equity_usdt': balance.equity(price).toString(),
        'source': 'LIVE_REST_RECONCILE',
        'captured_at': now,
      });
    }
    await batch.commit(noResult: true);
    _log('all account balances reconciled count=${balances.length}');
  }

  Future<void> _savePortfolioSnapshot(
    AccountBalance account,
    Decimal price,
  ) async {
    final equity = account.equity(price);
    final first = await database.query(
      'portfolio_snapshots',
      columns: ['initial_capital'],
      orderBy: 'captured_at ASC, id ASC',
      limit: 1,
    );
    final initial = first.isEmpty
        ? equity
        : Decimal.parse(first.single['initial_capital'] as String);
    final feeRows = await database.query('trades', columns: ['fee_amount']);
    final fees = feeRows.fold(
      Decimal.zero,
      (sum, row) => sum + Decimal.parse(row['fee_amount'] as String),
    );
    await database.insert('portfolio_snapshots', {
      'btc_price': price.toString(),
      'btc_quantity': account.btc.toString(),
      'usdt_quantity': account.usdt.toString(),
      'equity_usdt': equity.toString(),
      'btc_weight': account.btcWeight(price).toString(),
      'initial_capital': initial.toString(),
      'net_deposits': '0',
      'net_withdrawals': '0',
      'trading_pnl': (equity - initial).toString(),
      'total_fees': fees.toString(),
      'captured_at': DateTime.now().toUtc().toIso8601String(),
    });
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

  void _log(String message) => print('[LIVE] $message');
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
