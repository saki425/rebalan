import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/funding/funding_manager.dart';

void main() {
  const manager = FundingManager();
  final price = Decimal.parse('50000');
  final target = Decimal.parse('0.50');

  test('50/50 strategy plus 20000 deposit buys 10000 BTC value', () {
    final plan = manager.calculate(
      strategyAccount: AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.one,
        usdt: Decimal.parse('50000'),
      ),
      depositUsdt: Decimal.parse('20000'),
      btcPrice: price,
      targetBtcWeight: target,
    );
    expect(plan.buyBtcValue, Decimal.parse('10000'));
    expect(plan.buyBtcQuantity, Decimal.parse('0.2'));
    expect(plan.remainingUsdt, Decimal.parse('10000'));
    expect(plan.projectedStrategy.btcWeight, Decimal.parse('0.5'));
  });

  test('BTC already at target value buys no BTC', () {
    final plan = manager.calculate(
      strategyAccount: AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.parse('1.4'),
        usdt: Decimal.parse('50000'),
      ),
      depositUsdt: Decimal.parse('20000'),
      btcPrice: price,
      targetBtcWeight: target,
    );
    expect(plan.strategyBefore.btcValue, Decimal.parse('70000'));
    expect(plan.buyBtcValue, Decimal.zero);
    expect(plan.remainingUsdt, Decimal.parse('20000'));
    expect(plan.projectedStrategy.btcWeight, Decimal.parse('0.5'));
  });

  test('buy amount is capped by available deposit', () {
    final plan = manager.calculate(
      strategyAccount: AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.zero,
        usdt: Decimal.parse('100000'),
      ),
      depositUsdt: Decimal.parse('10000'),
      btcPrice: price,
      targetBtcWeight: target,
    );
    expect(plan.rawBuyBtcValue, Decimal.parse('55000'));
    expect(plan.buyBtcValue, Decimal.parse('10000'));
    expect(plan.remainingUsdt, Decimal.zero);
  });

  test('rejects wrong account, negative deposit, and invalid target', () {
    final funding = AccountBalance(
      role: AccountRole.funding,
      name: 'Funding',
      btc: Decimal.zero,
      usdt: Decimal.one,
    );
    expect(
      () => manager.calculate(
        strategyAccount: funding,
        depositUsdt: Decimal.one,
        btcPrice: price,
        targetBtcWeight: target,
      ),
      throwsA(isA<FundingCalculationException>()),
    );
    final strategy = AccountBalance(
      role: AccountRole.strategy,
      name: 'Strategy',
      btc: Decimal.zero,
      usdt: Decimal.one,
    );
    expect(
      () => manager.calculate(
        strategyAccount: strategy,
        depositUsdt: Decimal.parse('-1'),
        btcPrice: price,
        targetBtcWeight: target,
      ),
      throwsA(isA<FundingCalculationException>()),
    );
    expect(
      () => manager.calculate(
        strategyAccount: strategy,
        depositUsdt: Decimal.one,
        btcPrice: price,
        targetBtcWeight: Decimal.parse('1.1'),
      ),
      throwsA(isA<FundingCalculationException>()),
    );
  });
}
