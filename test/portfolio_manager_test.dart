import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/portfolio/portfolio_manager.dart';

void main() {
  const manager = PortfolioManager();
  final price = Decimal.parse('60000');

  test('values a 1.5 BTC and 110000 USDT portfolio', () {
    final result = manager.valueAmounts(
      btcQuantity: Decimal.parse('1.5'),
      usdtQuantity: Decimal.parse('110000'),
      btcPrice: price,
    );
    expect(result.btcValue, Decimal.parse('90000'));
    expect(result.totalEquity, Decimal.parse('200000'));
    expect(result.btcWeight, Decimal.parse('0.45'));
    expect(result.usdtWeight, Decimal.parse('0.55'));
  });

  test('aggregates all three accounts before calculating weights', () {
    final result = manager.valueAccounts([
      AccountBalance(
        role: AccountRole.funding,
        name: 'Funding',
        btc: Decimal.parse('0.25'),
        usdt: Decimal.parse('5000'),
      ),
      AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.parse('1.25'),
        usdt: Decimal.parse('55000'),
      ),
      AccountBalance(
        role: AccountRole.profit,
        name: 'Profit',
        btc: Decimal.zero,
        usdt: Decimal.parse('50000'),
      ),
    ], price);
    expect(result.btcQuantity, Decimal.parse('1.50'));
    expect(result.usdtQuantity, Decimal.parse('110000'));
    expect(result.totalEquity, Decimal.parse('200000'));
  });

  test('zero portfolio has zero weights', () {
    final result = manager.valueAmounts(
      btcQuantity: Decimal.zero,
      usdtQuantity: Decimal.zero,
      btcPrice: price,
    );
    expect(result.btcWeight, Decimal.zero);
    expect(result.usdtWeight, Decimal.zero);
  });

  test('non-terminating ratios are limited to 18 decimal places', () {
    final result = manager.valueAmounts(
      btcQuantity: Decimal.one,
      usdtQuantity: Decimal.parse('120000'),
      btcPrice: price,
    );
    expect(result.btcWeight, Decimal.parse('0.333333333333333333'));
    expect(result.btcWeight + result.usdtWeight, Decimal.one);
  });

  test('rejects zero price and negative balances', () {
    expect(
      () => manager.valueAmounts(
        btcQuantity: Decimal.one,
        usdtQuantity: Decimal.zero,
        btcPrice: Decimal.zero,
      ),
      throwsA(isA<PortfolioCalculationException>()),
    );
    expect(
      () => manager.valueAmounts(
        btcQuantity: Decimal.parse('-0.1'),
        usdtQuantity: Decimal.zero,
        btcPrice: price,
      ),
      throwsA(isA<PortfolioCalculationException>()),
    );
  });
}
