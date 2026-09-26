import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/funding/paper_funding_executor.dart';

void main() {
  PaperFundingExecutor executor({
    required AccountBalance strategy,
    Decimal? fee,
    Decimal? slippage,
  }) => PaperFundingExecutor(
    fundingAccount: AccountBalance(
      role: AccountRole.funding,
      name: 'Funding',
      btc: Decimal.zero,
      usdt: Decimal.parse('20000'),
    ),
    strategyAccount: strategy,
    feeRate: fee ?? Decimal.zero,
    slippageRate: slippage ?? Decimal.zero,
  );

  test('buys 10000 BTC value and transfers BTC plus 10000 USDT', () {
    final service = executor(
      strategy: AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.one,
        usdt: Decimal.parse('50000'),
      ),
    );
    final result = service.execute(
      idempotencyKey: 'deposit-1',
      depositUsdt: Decimal.parse('20000'),
      btcPrice: Decimal.parse('50000'),
      targetBtcWeight: Decimal.parse('0.50'),
    );
    expect(result.order?.quoteAmount, Decimal.parse('10000'));
    expect(result.order?.btcQuantity, Decimal.parse('0.2'));
    expect(result.transfers, hasLength(2));
    expect(result.transfers.map((item) => item.asset), ['BTC', 'USDT']);
    expect(result.transfers.last.amount, Decimal.parse('10000'));
    expect(result.fundingAfter.usdt, Decimal.zero);
    expect(result.strategyAfter.btc, Decimal.parse('1.2'));
    expect(result.strategyAfter.usdt, Decimal.parse('60000'));
  });

  test('high BTC allocation skips buy and transfers all USDT', () {
    final service = executor(
      strategy: AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.parse('1.4'),
        usdt: Decimal.parse('50000'),
      ),
    );
    final result = service.execute(
      idempotencyKey: 'deposit-2',
      depositUsdt: Decimal.parse('20000'),
      btcPrice: Decimal.parse('50000'),
      targetBtcWeight: Decimal.parse('0.50'),
    );
    expect(result.order, isNull);
    expect(result.transfers, hasLength(1));
    expect(result.transfers.single.asset, 'USDT');
    expect(result.transfers.single.amount, Decimal.parse('20000'));
    expect(result.strategyAfter.usdt, Decimal.parse('70000'));
  });

  test('same idempotency key cannot buy or transfer twice', () {
    final service = executor(
      strategy: AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.one,
        usdt: Decimal.parse('50000'),
      ),
    );
    PaperFundingResult run() => service.execute(
      idempotencyKey: 'external-deposit-tx-123',
      depositUsdt: Decimal.parse('20000'),
      btcPrice: Decimal.parse('50000'),
      targetBtcWeight: Decimal.parse('0.50'),
    );
    final first = run();
    final balances = (
      service.fundingAccount.usdt,
      service.strategyAccount.btc,
      service.strategyAccount.usdt,
    );
    final second = run();
    expect(identical(first, second), isTrue);
    expect((
      service.fundingAccount.usdt,
      service.strategyAccount.btc,
      service.strategyAccount.usdt,
    ), balances);
  });

  test('fee and slippage reduce received assets without creating funds', () {
    final service = executor(
      strategy: AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.one,
        usdt: Decimal.parse('50000'),
      ),
      fee: Decimal.parse('0.001'),
      slippage: Decimal.parse('0.001'),
    );
    final result = service.execute(
      idempotencyKey: 'deposit-with-costs',
      depositUsdt: Decimal.parse('20000'),
      btcPrice: Decimal.parse('50000'),
      targetBtcWeight: Decimal.parse('0.50'),
    );
    expect(result.order!.feeUsdt, Decimal.parse('10'));
    expect(result.order!.btcQuantity, lessThan(Decimal.parse('0.2')));
    expect(result.transfers.last.amount, Decimal.parse('9990'));
    expect(result.fundingAfter.usdt, Decimal.zero);
  });

  test('insufficient funding balance aborts before side effects', () {
    final service = executor(
      strategy: AccountBalance(
        role: AccountRole.strategy,
        name: 'Strategy',
        btc: Decimal.one,
        usdt: Decimal.parse('50000'),
      ),
    );
    expect(
      () => service.execute(
        idempotencyKey: 'too-large',
        depositUsdt: Decimal.parse('20001'),
        btcPrice: Decimal.parse('50000'),
        targetBtcWeight: Decimal.parse('0.50'),
      ),
      throwsA(isA<FundingExecutionException>()),
    );
    expect(service.fundingAccount.usdt, Decimal.parse('20000'));
  });
}
