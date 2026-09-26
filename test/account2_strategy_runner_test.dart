import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/market/market_state.dart';
import 'package:rebalance/core/paper/paper_trading_engine.dart';
import 'package:rebalance/core/strategy/account2_strategy_runner.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);

  Account2StrategyRunner createRunner() {
    final config = PaperTradingConfig(
      targetBtcWeight: Decimal.parse('0.50'),
      triggerDeviation: Decimal.parse('0.10'),
      repairRatio: Decimal.parse('0.25'),
      feeRate: Decimal.zero,
      slippageRate: Decimal.zero,
      minimumOrderUsdt: Decimal.parse('10'),
      cooldown: const Duration(seconds: 30),
    );
    return Account2StrategyRunner(
      paperEngine: PaperTradingEngine(
        broker: PaperBroker(
          initialBtc: Decimal.one,
          initialUsdt: Decimal.parse('50000'),
          feeRate: config.feeRate,
          slippageRate: config.slippageRate,
        ),
        config: config,
      ),
      checkInterval: const Duration(seconds: 5),
    );
  }

  MarketState market({
    Decimal? price,
    ConnectionStatus websocket = ConnectionStatus.connected,
    ConnectionStatus api = ConnectionStatus.connected,
  }) => MarketState(
    price: price ?? Decimal.parse('75000'),
    change24h: Decimal.zero,
    websocketStatus: websocket,
    apiStatus: api,
    lastEventAt: now,
    lastRestCalibration: now,
  );

  test('market callback only caches state and never submits', () async {
    final runner = createRunner();
    final states = StreamController<MarketState>();
    runner.start(states.stream);
    states.add(market());
    await Future<void>.delayed(Duration.zero);
    expect(runner.latestMarket?.price, Decimal.parse('75000'));
    expect(runner.paperEngine.broker.activeOrder, isNull);
    await states.close();
    await runner.dispose();
  });

  test('scheduled check emits explicit filled state transitions', () async {
    final runner = createRunner()..updateMarketState(market());
    final eventsFuture = runner.events.take(4).toList();
    final result = runner.checkNow(now);
    expect(result.state, StrategyRuntimeState.filled);
    final events = await eventsFuture;
    expect(events.map((event) => event.state), [
      StrategyRuntimeState.calculating,
      StrategyRuntimeState.triggered,
      StrategyRuntimeState.rebalancing,
      StrategyRuntimeState.filled,
    ]);
    await runner.dispose();
  });

  test('continuous checks cannot duplicate a partially filled order', () async {
    final runner = createRunner()..updateMarketState(market());
    final first = runner.checkNow(now, fillRatio: Decimal.parse('0.5'));
    expect(first.state, StrategyRuntimeState.partiallyFilled);
    final firstId = first.order?.clientOrderId;

    for (var second = 1; second <= 10; second++) {
      runner.updateMarketState(
        market(price: Decimal.parse('${75000 + second}')),
      );
      final next = runner.checkNow(now.add(Duration(seconds: second)));
      expect(next.state, StrategyRuntimeState.partiallyFilled);
      expect(next.reason, 'UNFINISHED_ORDER');
      expect(next.order?.clientOrderId, firstId);
    }
    expect(runner.paperEngine.broker.activeOrder?.clientOrderId, firstId);
    await runner.dispose();
  });

  test('API and WebSocket health prevent strategy evaluation', () async {
    final runner = createRunner()
      ..updateMarketState(market(api: ConnectionStatus.disconnected));
    expect(runner.checkNow(now).state, StrategyRuntimeState.apiError);
    expect(runner.paperEngine.broker.activeOrder, isNull);

    runner.updateMarketState(market(websocket: ConnectionStatus.disconnected));
    expect(
      runner.checkNow(now).state,
      StrategyRuntimeState.websocketDisconnected,
    );
    expect(runner.paperEngine.broker.activeOrder, isNull);
    await runner.dispose();
  });

  test('missing market state is safe', () async {
    final runner = createRunner();
    final result = runner.checkNow(now);
    expect(result.state, StrategyRuntimeState.websocketDisconnected);
    expect(result.reason, 'MARKET_NOT_READY');
    await runner.dispose();
  });
}
