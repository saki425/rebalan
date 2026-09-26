import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/market/market_state.dart';
import 'package:rebalance/core/paper/paper_trading_engine.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);
  final config = PaperTradingConfig(
    targetBtcWeight: Decimal.parse('0.50'),
    triggerDeviation: Decimal.parse('0.10'),
    repairRatio: Decimal.parse('0.25'),
    feeRate: Decimal.parse('0.001'),
    slippageRate: Decimal.parse('0.001'),
    minimumOrderUsdt: Decimal.parse('10'),
    cooldown: const Duration(seconds: 30),
  );

  MarketState market({
    Decimal? price,
    ConnectionStatus status = ConnectionStatus.connected,
    DateTime? eventAt,
  }) => MarketState(
    price: price ?? Decimal.parse('75000'),
    change24h: Decimal.zero,
    websocketStatus: status,
    apiStatus: ConnectionStatus.connected,
    lastEventAt: eventAt ?? now,
    lastRestCalibration: now,
  );

  PaperTradingEngine createEngine() => PaperTradingEngine(
    broker: PaperBroker(
      initialBtc: Decimal.one,
      initialUsdt: Decimal.parse('50000'),
      feeRate: config.feeRate,
      slippageRate: config.slippageRate,
    ),
    config: config,
  );

  test('uses real market state but simulates a filled sell locally', () {
    final engine = createEngine();
    final result = engine.evaluate(market(), now);
    expect(result.state, PaperEngineState.filled);
    expect(result.order?.clientOrderId, 'paper-1');
    expect(result.order?.idempotencyKey, isNotEmpty);
    expect(result.order?.fee, greaterThan(Decimal.zero));
    expect(engine.broker.btc, lessThan(Decimal.one));
    expect(engine.broker.usdt, greaterThan(Decimal.parse('50000')));
  });

  test('partially filled order blocks every subsequent evaluation', () {
    final engine = createEngine();
    final first = engine.evaluate(
      market(),
      now,
      fillRatio: Decimal.parse('0.5'),
    );
    expect(first.state, PaperEngineState.partiallyFilled);
    final balances = (engine.broker.btc, engine.broker.usdt);

    final second = engine.evaluate(
      market(price: Decimal.parse('80000')),
      now.add(const Duration(seconds: 5)),
    );
    expect(second.state, PaperEngineState.partiallyFilled);
    expect(second.reason, 'UNFINISHED_ORDER');
    expect(second.order?.clientOrderId, first.order?.clientOrderId);
    expect((engine.broker.btc, engine.broker.usdt), balances);

    final completed = engine.completeOrder(now.add(const Duration(seconds: 6)));
    expect(completed.state, PaperEngineState.filled);
  });

  test('cooldown blocks a new order after fill', () {
    final engine = createEngine();
    expect(engine.evaluate(market(), now).state, PaperEngineState.filled);
    final result = engine.evaluate(
      market(
        price: Decimal.parse('100000'),
        eventAt: now.add(const Duration(seconds: 1)),
      ),
      now.add(const Duration(seconds: 1)),
    );
    expect(result.state, PaperEngineState.cooldown);
  });

  test('disconnected or stale market never submits an order', () {
    final disconnected = createEngine().evaluate(
      market(status: ConnectionStatus.disconnected),
      now,
    );
    expect(disconnected.state, PaperEngineState.paused);
    expect(disconnected.reason, 'WEBSOCKET_DISCONNECTED');

    final staleEngine = createEngine();
    final stale = staleEngine.evaluate(
      market(eventAt: now.subtract(const Duration(seconds: 16))),
      now,
    );
    expect(stale.state, PaperEngineState.paused);
    expect(stale.reason, 'STALE_MARKET_PRICE');
    expect(staleEngine.broker.activeOrder, isNull);
  });

  test('minimum order protection skips tiny orders', () {
    final tinyConfig = PaperTradingConfig(
      targetBtcWeight: config.targetBtcWeight,
      triggerDeviation: config.triggerDeviation,
      repairRatio: Decimal.parse('0.000001'),
      feeRate: config.feeRate,
      slippageRate: config.slippageRate,
      minimumOrderUsdt: Decimal.parse('100'),
      cooldown: config.cooldown,
    );
    final broker = PaperBroker(
      initialBtc: Decimal.one,
      initialUsdt: Decimal.parse('50000'),
      feeRate: tinyConfig.feeRate,
      slippageRate: tinyConfig.slippageRate,
    );
    final result = PaperTradingEngine(
      broker: broker,
      config: tinyConfig,
    ).evaluate(market(), now);
    expect(result.state, PaperEngineState.idle);
    expect(result.reason, 'BELOW_MINIMUM_ORDER');
    expect(broker.activeOrder, isNull);
  });
}
