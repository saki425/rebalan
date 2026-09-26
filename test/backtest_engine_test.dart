import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/backtest/backtest_engine.dart';
import 'package:rebalance/core/strategy/rebalance_engine.dart';

void main() {
  const engine = BacktestEngine();
  final config = BacktestConfig(
    targetBtcWeight: Decimal.one,
    triggerDeviation: Decimal.zero,
    repairRatio: Decimal.one,
    feeRate: Decimal.zero,
    slippageRate: Decimal.zero,
    cooldown: Duration.zero,
  );

  test('uses shared rebalance engine and produces curves and metrics', () {
    final result = engine.run(
      prices: [
        HistoricalPrice(
          time: DateTime.utc(2024),
          close: Decimal.parse('50000'),
        ),
        HistoricalPrice(
          time: DateTime.utc(2024, 7),
          close: Decimal.parse('75000'),
        ),
        HistoricalPrice(
          time: DateTime.utc(2025),
          close: Decimal.parse('75000'),
        ),
      ],
      initialBtc: Decimal.one,
      initialUsdt: Decimal.parse('50000'),
      config: BacktestConfig(
        targetBtcWeight: Decimal.parse('0.50'),
        triggerDeviation: Decimal.parse('0.10'),
        repairRatio: Decimal.parse('0.25'),
        feeRate: Decimal.zero,
        slippageRate: Decimal.zero,
        cooldown: Duration.zero,
      ),
    );
    expect(result.trades, hasLength(1));
    expect(result.trades.single.side, RebalanceSide.sell);
    expect(result.trades.single.weightBefore, Decimal.parse('0.6'));
    expect(
      (result.trades.single.weightAfter - Decimal.parse('0.575')).abs(),
      lessThan(Decimal.parse('0.000000000000000001')),
    );
    expect(result.curve, hasLength(3));
    expect(result.annualReturns.keys, containsAll(['2024', '2025']));
    expect(result.monthlyReturns.keys, contains('2024-07'));
    expect(result.totalFees, Decimal.zero);
  });

  test('applies fee and adverse slippage using Decimal balances', () {
    final result = engine.run(
      prices: [
        HistoricalPrice(
          time: DateTime.utc(2024),
          close: Decimal.parse('50000'),
        ),
        HistoricalPrice(
          time: DateTime.utc(2024, 2),
          close: Decimal.parse('75000'),
        ),
      ],
      initialBtc: Decimal.one,
      initialUsdt: Decimal.parse('50000'),
      config: BacktestConfig(
        targetBtcWeight: Decimal.parse('0.50'),
        triggerDeviation: Decimal.parse('0.10'),
        repairRatio: Decimal.parse('0.25'),
        feeRate: Decimal.parse('0.001'),
        slippageRate: Decimal.parse('0.001'),
        cooldown: Duration.zero,
      ),
    );
    expect(result.tradeCount, 1);
    expect(result.totalFees, greaterThan(Decimal.zero));
    expect(result.finalEquity, lessThan(Decimal.parse('125000')));
  });

  test('cooldown prevents repeated trades', () {
    final result = engine.run(
      prices: [
        HistoricalPrice(
          time: DateTime.utc(2024),
          close: Decimal.parse('50000'),
        ),
        HistoricalPrice(
          time: DateTime.utc(2024, 1, 1, 0, 1),
          close: Decimal.parse('100000'),
        ),
        HistoricalPrice(
          time: DateTime.utc(2024, 1, 1, 0, 2),
          close: Decimal.parse('200000'),
        ),
      ],
      initialBtc: Decimal.one,
      initialUsdt: Decimal.parse('50000'),
      config: BacktestConfig(
        targetBtcWeight: Decimal.parse('0.50'),
        triggerDeviation: Decimal.parse('0.10'),
        repairRatio: Decimal.parse('0.25'),
        feeRate: Decimal.zero,
        slippageRate: Decimal.zero,
        cooldown: Duration(hours: 1),
      ),
    );
    expect(result.tradeCount, 1);
  });

  test('rejects empty historical series', () {
    expect(
      () => engine.run(
        prices: const [],
        initialBtc: Decimal.one,
        initialUsdt: Decimal.zero,
        config: config,
      ),
      throwsArgumentError,
    );
  });
}
