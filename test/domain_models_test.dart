import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/domain/models.dart';

void main() {
  test('portfolio calculations retain decimal precision', () {
    final account = AccountBalance(
      role: AccountRole.strategy,
      name: 'Strategy',
      btc: Decimal.parse('1.5'),
      usdt: Decimal.parse('110000'),
    );
    final price = Decimal.parse('60000');
    expect(account.btcValue(price), Decimal.parse('90000'));
    expect(account.equity(price), Decimal.parse('200000'));
    expect(account.btcWeight(price), Decimal.parse('0.45'));
  });

  test('default strategy boundaries are 40 and 60 percent', () {
    final config = StrategyConfig.defaults();
    expect(config.lowerTrigger, Decimal.parse('0.40'));
    expect(config.upperTrigger, Decimal.parse('0.60'));
    expect(config.repairRatio, Decimal.parse('0.25'));
  });
}
