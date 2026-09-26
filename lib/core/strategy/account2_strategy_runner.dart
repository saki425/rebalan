import 'dart:async';

import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import '../market/market_state.dart';
import '../paper/paper_trading_engine.dart';

enum StrategyRuntimeState {
  idle,
  triggered,
  calculating,
  orderSubmitted,
  partiallyFilled,
  filled,
  rebalancing,
  cooldown,
  apiError,
  websocketDisconnected,
  error,
}

class StrategyRuntimeEvent {
  const StrategyRuntimeEvent({
    required this.state,
    required this.reason,
    required this.occurredAt,
    this.order,
  });
  final StrategyRuntimeState state;
  final String reason;
  final DateTime occurredAt;
  final PaperOrder? order;
}

class Account2StrategyRunner {
  Account2StrategyRunner({
    required this.paperEngine,
    required this.checkInterval,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PaperTradingEngine paperEngine;
  final Duration checkInterval;
  final DateTime Function() _clock;
  final _events = StreamController<StrategyRuntimeEvent>.broadcast();
  StreamSubscription<MarketState>? _marketSubscription;
  Timer? _timer;
  MarketState? _latestMarket;
  StrategyRuntimeState _state = StrategyRuntimeState.idle;
  bool _checking = false;

  Stream<StrategyRuntimeEvent> get events => _events.stream;
  StrategyRuntimeState get state => _state;
  MarketState? get latestMarket => _latestMarket;
  bool get isRunning => _timer?.isActive == true;

  void start(Stream<MarketState> marketStates) {
    if (_timer?.isActive == true) return;
    if (checkInterval <= Duration.zero) {
      throw ArgumentError.value(
        checkInterval,
        'checkInterval',
        'must be positive',
      );
    }
    _marketSubscription = marketStates.listen(
      updateMarketState,
      onError: (Object error) => _publish(
        StrategyRuntimeState.error,
        'MARKET_STREAM_ERROR: $error',
        _clock(),
      ),
    );
    _timer = Timer.periodic(checkInterval, (_) => checkNow(_clock()));
  }

  /// Intentionally only caches the newest tick. It never evaluates or submits.
  void updateMarketState(MarketState market) {
    _latestMarket = market;
  }

  StrategyRuntimeEvent checkNow(DateTime now, {Decimal? fillRatio}) {
    if (_checking) {
      return _publish(StrategyRuntimeState.error, 'CHECK_ALREADY_RUNNING', now);
    }
    final market = _latestMarket;
    if (market == null) {
      return _publish(
        StrategyRuntimeState.websocketDisconnected,
        'MARKET_NOT_READY',
        now,
      );
    }
    if (market.websocketStatus != ConnectionStatus.connected) {
      return _publish(
        StrategyRuntimeState.websocketDisconnected,
        'WEBSOCKET_DISCONNECTED',
        now,
      );
    }
    if (market.apiStatus == ConnectionStatus.disconnected) {
      return _publish(
        StrategyRuntimeState.apiError,
        'BINANCE_API_DISCONNECTED',
        now,
      );
    }
    _checking = true;
    try {
      _publish(StrategyRuntimeState.calculating, 'STRATEGY_CHECK', now);
      final result = paperEngine.evaluate(market, now, fillRatio: fillRatio);
      return _mapResult(result, now);
    } catch (error) {
      return _publish(
        StrategyRuntimeState.error,
        'STRATEGY_CHECK_FAILED: $error',
        now,
      );
    } finally {
      _checking = false;
    }
  }

  StrategyRuntimeEvent completePaperOrder(DateTime now) {
    try {
      final result = paperEngine.completeOrder(now);
      return _mapResult(result, now);
    } catch (error) {
      return _publish(
        StrategyRuntimeState.error,
        'ORDER_COMPLETION_FAILED: $error',
        now,
      );
    }
  }

  StrategyRuntimeEvent _mapResult(PaperEvaluation result, DateTime now) {
    switch (result.state) {
      case PaperEngineState.idle:
        return _publish(
          StrategyRuntimeState.idle,
          result.reason,
          now,
          result.order,
        );
      case PaperEngineState.orderSubmitted:
        _publish(
          StrategyRuntimeState.triggered,
          'REBALANCE_TRIGGERED',
          now,
          result.order,
        );
        return _publish(
          StrategyRuntimeState.orderSubmitted,
          result.reason,
          now,
          result.order,
        );
      case PaperEngineState.partiallyFilled:
        if (result.reason != 'UNFINISHED_ORDER') {
          _publish(
            StrategyRuntimeState.triggered,
            'REBALANCE_TRIGGERED',
            now,
            result.order,
          );
          _publish(
            StrategyRuntimeState.orderSubmitted,
            'ORDER_SUBMITTED',
            now,
            result.order,
          );
        }
        return _publish(
          StrategyRuntimeState.partiallyFilled,
          result.reason,
          now,
          result.order,
        );
      case PaperEngineState.filled:
        _publish(
          StrategyRuntimeState.triggered,
          'REBALANCE_TRIGGERED',
          now,
          result.order,
        );
        _publish(
          StrategyRuntimeState.rebalancing,
          'REBALANCING',
          now,
          result.order,
        );
        return _publish(
          StrategyRuntimeState.filled,
          result.reason,
          now,
          result.order,
        );
      case PaperEngineState.cooldown:
        return _publish(
          StrategyRuntimeState.cooldown,
          result.reason,
          now,
          result.order,
        );
      case PaperEngineState.paused:
        return _publish(
          StrategyRuntimeState.websocketDisconnected,
          result.reason,
          now,
          result.order,
        );
      case PaperEngineState.error:
        return _publish(
          StrategyRuntimeState.error,
          result.reason,
          now,
          result.order,
        );
      case PaperEngineState.calculating:
        return _publish(
          StrategyRuntimeState.calculating,
          result.reason,
          now,
          result.order,
        );
    }
  }

  StrategyRuntimeEvent _publish(
    StrategyRuntimeState state,
    String reason,
    DateTime at, [
    PaperOrder? order,
  ]) {
    _state = state;
    final event = StrategyRuntimeEvent(
      state: state,
      reason: reason,
      occurredAt: at,
      order: order,
    );
    if (!_events.isClosed) _events.add(event);
    return event;
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _marketSubscription?.cancel();
    _marketSubscription = null;
    _latestMarket = null;
    _state = StrategyRuntimeState.idle;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}
