import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/database/database_service.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/funding/funding_execution_repository.dart';
import 'package:rebalance/core/funding/paper_funding_executor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'paper funding persists deposit, order and both transfers once',
    () async {
      final database = await DatabaseService.open(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      final executor = PaperFundingExecutor(
        fundingAccount: AccountBalance(
          role: AccountRole.funding,
          name: 'Funding',
          btc: Decimal.zero,
          usdt: Decimal.parse('20000'),
        ),
        strategyAccount: AccountBalance(
          role: AccountRole.strategy,
          name: 'Strategy',
          btc: Decimal.one,
          usdt: Decimal.parse('50000'),
        ),
        feeRate: Decimal.zero,
        slippageRate: Decimal.zero,
      );
      final result = executor.execute(
        idempotencyKey: 'external-deposit-1',
        depositUsdt: Decimal.parse('20000'),
        btcPrice: Decimal.parse('50000'),
        targetBtcWeight: Decimal.parse('0.5'),
      );
      final repository = FundingExecutionRepository(database);
      await repository.save(result);
      await repository.save(result);
      expect(await database.query('deposits'), hasLength(1));
      expect(await database.query('orders'), hasLength(1));
      expect(await database.query('trades'), hasLength(1));
      expect(await database.query('transfers'), hasLength(2));
      await database.close();
    },
  );
}
