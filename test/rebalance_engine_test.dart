import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/strategy/rebalance_engine.dart';

void main() {
  const engine = RebalanceEngine();
  final target = Decimal.parse('0.50');
  final deviation = Decimal.parse('0.10');
  final repair = Decimal.parse('0.25');

  test('60 percent BTC sells only enough to target 57.5 percent', () {
    final decision = engine.evaluate(
      btcQuantity: Decimal.one,
      usdtQuantity: Decimal.parse('50000'),
      btcPrice: Decimal.parse('75000'),
      targetBtcWeight: target,
      triggerDeviation: deviation,
      repairRatio: repair,
    );
    expect(decision.side, RebalanceSide.sell);
    expect(decision.currentBtcWeight, Decimal.parse('0.6'));
    expect(decision.targetAfterBtcWeight, Decimal.parse('0.575'));
    expect(decision.quoteAmount, Decimal.parse('3125'));
  });

  test('40 percent BTC buys only enough to target 42.5 percent', () {
    final decision = engine.evaluate(
      btcQuantity: Decimal.one,
      usdtQuantity: Decimal.parse('60000'),
      btcPrice: Decimal.parse('40000'),
      targetBtcWeight: target,
      triggerDeviation: deviation,
      repairRatio: repair,
    );
    expect(decision.side, RebalanceSide.buy);
    expect(decision.currentBtcWeight, Decimal.parse('0.4'));
    expect(decision.targetAfterBtcWeight, Decimal.parse('0.425'));
    expect(decision.quoteAmount, Decimal.parse('2500'));
  });

  test('does nothing inside trigger band', () {
    final decision = engine.evaluate(
      btcQuantity: Decimal.one,
      usdtQuantity: Decimal.parse('50000'),
      btcPrice: Decimal.parse('50000'),
      targetBtcWeight: target,
      triggerDeviation: deviation,
      repairRatio: repair,
    );
    expect(decision.shouldTrade, isFalse);
    expect(decision.quoteAmount, Decimal.zero);
  });
}
