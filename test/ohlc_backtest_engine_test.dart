import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/backtest/backtest_engine.dart';
import 'package:rebalance/core/backtest/ohlc_backtest_engine.dart';

void main() {
  final config = BacktestConfig(
    targetBtcWeight: Decimal.parse('0.5'),
    triggerDeviation: Decimal.parse('0.1'),
    repairRatio: Decimal.parse('0.25'),
    feeRate: Decimal.parse('0.001'),
    slippageRate: Decimal.parse('0.0002'),
    cooldown: Duration.zero,
  );

  test('uses OHLC threshold crossing when close never crosses', () {
    final result = const OhlcBacktestEngine().run(
      candles: [
        HistoricalCandle(
          openTime: DateTime.utc(2024),
          open: Decimal.parse('50000'),
          high: Decimal.parse('80000'),
          low: Decimal.parse('49000'),
          close: Decimal.parse('50000'),
        ),
      ],
      initialCapital: Decimal.parse('100000'),
      config: config,
    );
    expect(result.tradeCount, greaterThan(0));
    expect(result.sellCount, greaterThan(0));
  });

  test('marks differing high-first and low-first paths ambiguous', () {
    final result = const OhlcBacktestEngine().run(
      candles: [
        HistoricalCandle(
          openTime: DateTime.utc(2024),
          open: Decimal.parse('50000'),
          high: Decimal.parse('150000'),
          low: Decimal.parse('15000'),
          close: Decimal.parse('50000'),
        ),
      ],
      initialCapital: Decimal.parse('100000'),
      config: config,
    );
    expect(result.ambiguousCandles, isNotEmpty);
  });

  test('fees and slippage are reported separately', () {
    final result = const OhlcBacktestEngine().run(
      candles: [
        HistoricalCandle(
          openTime: DateTime.utc(2024),
          open: Decimal.parse('50000'),
          high: Decimal.parse('80000'),
          low: Decimal.parse('50000'),
          close: Decimal.parse('70000'),
        ),
      ],
      initialCapital: Decimal.parse('100000'),
      config: config,
    );
    expect(result.totalFees, greaterThan(Decimal.zero));
    expect(result.totalSlippage, greaterThan(Decimal.zero));
    expect(
      result.grossRebalancingProfit,
      result.netRebalancingProfit + result.totalFees + result.totalSlippage,
    );
  });
}
