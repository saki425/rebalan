import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/performance/high_water_mark_manager.dart';

void main() {
  final at = DateTime.utc(2026, 1, 1);

  test('capital injection raises HWM and is not new profit', () {
    final manager = HighWaterMarkManager(
      initialHighWaterMark: Decimal.parse('100000'),
    );
    manager.applyCapitalFlow(
      signedAmount: Decimal.parse('20000'),
      reason: 'FUNDING_TO_STRATEGY',
      at: at,
    );
    final assessment = manager.assess(Decimal.parse('120000'));
    expect(manager.value, Decimal.parse('120000'));
    expect(assessment.newProfit, Decimal.zero);
  });

  test('only equity above adjusted HWM is new profit', () {
    final manager = HighWaterMarkManager(
      initialHighWaterMark: Decimal.parse('120000'),
    );
    expect(
      manager.assess(Decimal.parse('125000')).newProfit,
      Decimal.parse('5000'),
    );
    expect(manager.assess(Decimal.parse('118000')).newProfit, Decimal.zero);
  });

  test('crystallization prevents withdrawing the same profit twice', () {
    final manager = HighWaterMarkManager(
      initialHighWaterMark: Decimal.parse('120000'),
    );
    final first = manager.assess(Decimal.parse('125000'));
    expect(first.newProfit, Decimal.parse('5000'));
    manager.crystallize(
      equityBeforeWithdrawal: Decimal.parse('125000'),
      profitWithdrawal: Decimal.parse('1000'),
      at: at,
    );
    expect(manager.value, Decimal.parse('124000'));
    expect(manager.assess(Decimal.parse('124000')).newProfit, Decimal.zero);
    expect(
      manager.assess(Decimal.parse('130000')).newProfit,
      Decimal.parse('6000'),
    );
  });

  test(
    'ordinary withdrawal lowers HWM without creating a drawdown artifact',
    () {
      final manager = HighWaterMarkManager(
        initialHighWaterMark: Decimal.parse('100000'),
      );
      manager.applyCapitalFlow(
        signedAmount: Decimal.parse('-10000'),
        reason: 'EXTERNAL_WITHDRAWAL',
        at: at,
      );
      expect(manager.value, Decimal.parse('90000'));
      expect(manager.assess(Decimal.parse('90000')).newProfit, Decimal.zero);
    },
  );
}
