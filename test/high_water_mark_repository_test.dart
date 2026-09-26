import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/database/database_service.dart';
import 'package:rebalance/core/performance/high_water_mark_manager.dart';
import 'package:rebalance/core/performance/high_water_mark_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('persists and restores latest HWM with Decimal precision', () async {
    final db = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final repository = HighWaterMarkRepository(db);
    await repository.save(
      HighWaterMarkRecord(
        value: Decimal.parse('120000.123456789123456789'),
        reason: 'INITIALIZED',
        effectiveAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await repository.save(
      HighWaterMarkRecord(
        value: Decimal.parse('125000.987654321987654321'),
        reason: 'NEW_HIGH_COMMITTED',
        effectiveAt: DateTime.utc(2026, 2, 1),
      ),
    );
    final restored = await repository.loadLatest();
    expect(restored?.value, Decimal.parse('125000.987654321987654321'));
    expect(restored?.reason, 'NEW_HIGH_COMMITTED');
    expect(restored?.effectiveAt, DateTime.utc(2026, 2, 1));
  });
}
