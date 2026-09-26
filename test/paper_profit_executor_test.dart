import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/performance/high_water_mark_manager.dart';
import 'package:rebalance/core/performance/performance_manager.dart';
import 'package:rebalance/core/profit/paper_profit_executor.dart';
import 'package:rebalance/core/profit/profit_manager.dart';
import 'package:rebalance/core/strategy/rebalance_engine.dart';

void main() {
  final at = DateTime.utc(2026, 1, 1);

  test(
    'paper transfer updates both accounts, HWM, and performance exactly once',
    () {
      final hwm = HighWaterMarkManager(
        initialHighWaterMark: Decimal.parse('95000'),
      );
      final performance = PerformanceManager(
        initialCapital: Decimal.parse('95000'),
      );
      final executor = PaperProfitExecutor(
        strategyAccount: AccountBalance(
          role: AccountRole.strategy,
          name: 'Strategy',
          btc: Decimal.parse('1.1'),
          usdt: Decimal.parse('45000'),
        ),
        profitAccount: AccountBalance(
          role: AccountRole.profit,
          name: 'Profit',
          btc: Decimal.zero,
          usdt: Decimal.parse('10000'),
          totalProfitReceived: Decimal.parse('10000'),
        ),
        highWaterMark: hwm,
        performance: performance,
      );
      final request = ProfitWithdrawalRequest(
        side: RebalanceSide.sell,
        orderFilled: true,
        strategyBtc: Decimal.parse('1.1'),
        strategyUsdt: Decimal.parse('45000'),
        btcPrice: Decimal.parse('50000'),
        availableProfitUsdt: Decimal.parse('5000'),
        safeTransferLimit: Decimal.parse('10000'),
        withdrawalRatio: Decimal.parse('0.20'),
        maxBtcWeightAfterTransfer: Decimal.parse('0.58'),
        enabled: true,
      );
      final first = executor.execute(
        idempotencyKey: 'sell-order-123-profit',
        request: request,
        at: at,
      )!;
      expect(first.amount, Decimal.parse('1000'));
      expect(executor.strategyAccount.usdt, Decimal.parse('44000'));
      expect(executor.profitAccount.usdt, Decimal.parse('11000'));
      expect(
        executor.profitAccount.totalProfitReceived,
        Decimal.parse('11000'),
      );
      expect(hwm.value, Decimal.parse('99000'));
      expect(hwm.assess(Decimal.parse('99000')).newProfit, Decimal.zero);
      expect(
        performance.calculate(Decimal.parse('99000')).tradingPnl,
        Decimal.parse('5000'),
      );

      final second = executor.execute(
        idempotencyKey: 'sell-order-123-profit',
        request: request,
        at: at,
      );
      expect(identical(first, second), isTrue);
      expect(executor.strategyAccount.usdt, Decimal.parse('44000'));
      expect(performance.flows, hasLength(1));
    },
  );

  test('non-eligible order creates no transfer or side effects', () {
    final hwm = HighWaterMarkManager(
      initialHighWaterMark: Decimal.parse('95000'),
    );
    final performance = PerformanceManager(
      initialCapital: Decimal.parse('95000'),
    );
    final executor = PaperProfitExecutor(
      strategyAccount: AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.parse('1.1'),
        usdt: Decimal.parse('45000'),
      ),
      profitAccount: AccountBalance(
        role: AccountRole.profit,
        name: 'Profit',
        btc: Decimal.zero,
        usdt: Decimal.zero,
      ),
      highWaterMark: hwm,
      performance: performance,
    );
    final result = executor.execute(
      idempotencyKey: 'buy-order-no-profit',
      at: at,
      request: ProfitWithdrawalRequest(
        side: RebalanceSide.buy,
        orderFilled: true,
        strategyBtc: Decimal.parse('1.1'),
        strategyUsdt: Decimal.parse('45000'),
        btcPrice: Decimal.parse('50000'),
        availableProfitUsdt: Decimal.parse('5000'),
        safeTransferLimit: Decimal.parse('10000'),
        withdrawalRatio: Decimal.parse('0.20'),
        maxBtcWeightAfterTransfer: Decimal.parse('0.58'),
        enabled: true,
      ),
    );
    expect(result, isNull);
    expect(executor.profitAccount.usdt, Decimal.zero);
    expect(hwm.value, Decimal.parse('95000'));
    expect(performance.flows, isEmpty);
  });
}
