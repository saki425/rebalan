import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/performance/performance_manager.dart';

void main() {
  final at = DateTime.utc(2026, 1, 1);

  test('account1 to account2 injection is not trading profit', () {
    final manager = PerformanceManager(initialCapital: Decimal.parse('100000'));
    manager.recordFlow(
      CashFlow(
        type: CashFlowType.internalTransferIn,
        amount: Decimal.parse('20000'),
        occurredAt: at,
        referenceId: 'funding-transfer-1',
      ),
    );
    final result = manager.calculate(Decimal.parse('120000'));
    expect(result.netCapitalFlows, Decimal.parse('20000'));
    expect(result.tradingPnl, Decimal.zero);
  });

  test('profit transfer to account3 is not a trading loss', () {
    final manager = PerformanceManager(initialCapital: Decimal.parse('100000'));
    manager.recordFlow(
      CashFlow(
        type: CashFlowType.internalTransferIn,
        amount: Decimal.parse('20000'),
        occurredAt: at,
        referenceId: 'funding-transfer-1',
      ),
    );
    manager.recordFlow(
      CashFlow(
        type: CashFlowType.profitWithdrawal,
        amount: Decimal.parse('1000'),
        occurredAt: at,
        referenceId: 'profit-transfer-1',
      ),
    );
    final result = manager.calculate(Decimal.parse('124000'));
    expect(result.profitWithdrawn, Decimal.parse('1000'));
    expect(result.tradingPnl, Decimal.parse('5000'));
  });

  test('external deposits and withdrawals are isolated from pnl', () {
    final manager = PerformanceManager(initialCapital: Decimal.parse('100000'));
    manager.recordFlow(
      CashFlow(
        type: CashFlowType.externalDeposit,
        amount: Decimal.parse('10000'),
        occurredAt: at,
        referenceId: 'deposit',
      ),
    );
    manager.recordFlow(
      CashFlow(
        type: CashFlowType.externalWithdrawal,
        amount: Decimal.parse('4000'),
        occurredAt: at,
        referenceId: 'withdrawal',
      ),
    );
    final result = manager.calculate(Decimal.parse('108500'));
    expect(result.netCapitalFlows, Decimal.parse('6000'));
    expect(result.tradingPnl, Decimal.parse('2500'));
  });

  test('fees are idempotent and gross pnl adds fees back', () {
    final manager = PerformanceManager(initialCapital: Decimal.parse('100000'));
    manager.recordFee(Decimal.parse('25'), referenceId: 'trade-1');
    manager.recordFee(Decimal.parse('25'), referenceId: 'trade-1');
    final result = manager.calculate(Decimal.parse('100975'));
    expect(result.totalFees, Decimal.parse('25'));
    expect(result.tradingPnl, Decimal.parse('975'));
    expect(result.grossTradingPnl, Decimal.parse('1000'));
  });

  test('duplicate transfer reference is ignored', () {
    final manager = PerformanceManager(initialCapital: Decimal.parse('100000'));
    final flow = CashFlow(
      type: CashFlowType.internalTransferIn,
      amount: Decimal.parse('20000'),
      occurredAt: at,
      referenceId: 'same-transfer',
    );
    manager.recordFlow(flow);
    manager.recordFlow(flow);
    expect(manager.calculate(Decimal.parse('120000')).tradingPnl, Decimal.zero);
    expect(manager.flows, hasLength(1));
  });
}
