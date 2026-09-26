import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/performance/high_water_mark_manager.dart';
import 'package:rebalance/core/profit/profit_manager.dart';
import 'package:rebalance/core/strategy/rebalance_engine.dart';

void main() {
  const manager = ProfitManager();

  ProfitWithdrawalRequest request({
    RebalanceSide side = RebalanceSide.sell,
    bool filled = true,
    Decimal? btc,
    Decimal? usdt,
    Decimal? available,
    Decimal? safeLimit,
    bool enabled = true,
  }) => ProfitWithdrawalRequest(
    side: side,
    orderFilled: filled,
    strategyBtc: btc ?? Decimal.parse('1.1'),
    strategyUsdt: usdt ?? Decimal.parse('45000'),
    btcPrice: Decimal.parse('50000'),
    availableProfitUsdt: available ?? Decimal.parse('5000'),
    safeTransferLimit: safeLimit ?? Decimal.parse('10000'),
    withdrawalRatio: Decimal.parse('0.20'),
    maxBtcWeightAfterTransfer: Decimal.parse('0.58'),
    enabled: enabled,
  );

  test('withdraws 20 percent of new profit after a filled sell', () {
    final decision = manager.evaluate(
      request(),
      HighWaterMarkManager(initialHighWaterMark: Decimal.parse('95000')),
    );
    expect(decision.newProfit, Decimal.parse('5000'));
    expect(decision.requestedAmount, Decimal.parse('1000'));
    expect(decision.transferAmount, Decimal.parse('1000'));
    expect(decision.shouldTransfer, isTrue);
    expect(decision.btcWeightAfter, lessThan(Decimal.parse('0.58')));
  });

  test('safe transfer and available profit limits are both respected', () {
    final hwm = HighWaterMarkManager(
      initialHighWaterMark: Decimal.parse('95000'),
    );
    expect(
      manager
          .evaluate(request(safeLimit: Decimal.parse('600')), hwm)
          .transferAmount,
      Decimal.parse('600'),
    );
    expect(
      manager
          .evaluate(request(available: Decimal.parse('400')), hwm)
          .transferAmount,
      Decimal.parse('400'),
    );
  });

  test('58 percent weight protection reduces transfer amount', () {
    final decision = manager.evaluate(
      request(
        btc: Decimal.parse('1.15'),
        usdt: Decimal.parse('42500'),
        available: Decimal.parse('5000'),
      ),
      HighWaterMarkManager(initialHighWaterMark: Decimal.parse('95000')),
    );
    expect(decision.btcWeightBefore, Decimal.parse('0.575'));
    expect(decision.transferAmount, lessThan(Decimal.parse('1000')));
    expect(decision.transferAmount, greaterThan(Decimal.zero));
    expect(decision.btcWeightAfter, lessThanOrEqualTo(Decimal.parse('0.58')));
  });

  test('buy, partial order, disabled setting, and no profit are denied', () {
    final profitable = HighWaterMarkManager(
      initialHighWaterMark: Decimal.parse('95000'),
    );
    expect(
      manager.evaluate(request(side: RebalanceSide.buy), profitable).reason,
      ProfitDecisionReason.notFilledSell,
    );
    expect(
      manager.evaluate(request(filled: false), profitable).reason,
      ProfitDecisionReason.notFilledSell,
    );
    expect(
      manager.evaluate(request(enabled: false), profitable).reason,
      ProfitDecisionReason.disabled,
    );
    expect(
      manager
          .evaluate(
            request(),
            HighWaterMarkManager(initialHighWaterMark: Decimal.parse('100000')),
          )
          .reason,
      ProfitDecisionReason.noNewProfit,
    );
  });
}
