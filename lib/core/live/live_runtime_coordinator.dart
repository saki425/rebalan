import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';
import '../market/binance_market_data_service.dart';
import 'binance_live_client.dart';
import 'credential_store.dart';
import 'live_strategy_runner.dart';

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
      final account = await _readStrategyAccount(_client!);
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
    } catch (error) {
      _emit('LIVE_ERROR', '$error');
    } finally {
      _checking = false;
    }
  }

  Future<AccountBalance> _readStrategyAccount(BinanceLiveClient client) async {
    final data = await client.account();
    final balances = (data['balances'] as List<dynamic>).cast<Map<String, dynamic>>();
    Decimal balance(String asset) {
      final row = balances.firstWhere((item) => item['asset'] == asset, orElse: () => {'free': '0', 'locked': '0'});
      return Decimal.parse(row['free'] as String) + Decimal.parse(row['locked'] as String);
    }
    return AccountBalance(role: AccountRole.strategy, name: 'Strategy Account', btc: balance('BTC'), usdt: balance('USDT'));
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _client?.close();
    _client = null;
    _runner = null;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  void _emit(String state, String reason) {
    if (!_events.isClosed) _events.add(LiveRuntimeEvent(state: state, reason: reason));
  }
}

class LiveRuntimeConfig {
  const LiveRuntimeConfig({required this.enabled, required this.confirmation, required this.checkInterval, required this.targetBtcWeight, required this.triggerDeviation, required this.repairRatio});
  final bool enabled;
  final String confirmation;
  final Duration checkInterval;
  final Decimal targetBtcWeight, triggerDeviation, repairRatio;
}

class LiveTradingConfirmation {
  static const phrase = 'ENABLE LIVE TRADING';
}

class LiveRuntimeEvent {
  const LiveRuntimeEvent({required this.state, required this.reason});
  final String state;
  final String reason;
}
