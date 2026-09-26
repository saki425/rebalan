import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import 'high_water_mark_manager.dart';

class HighWaterMarkRepository {
  const HighWaterMarkRepository(this.database);
  final Database database;

  Future<void> save(HighWaterMarkRecord record) async {
    await database.insert('high_water_marks', {
      'value_usdt': record.value.toString(),
      'adjusted_equity_usdt': record.value.toString(),
      'reason': record.reason,
      'effective_at': record.effectiveAt.toUtc().toIso8601String(),
    });
  }

  Future<HighWaterMarkRecord?> loadLatest() async {
    final rows = await database.query(
      'high_water_marks',
      orderBy: 'effective_at DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return HighWaterMarkRecord(
      value: Decimal.parse(row['value_usdt'] as String),
      reason: row['reason'] as String,
      effectiveAt: DateTime.parse(row['effective_at'] as String).toUtc(),
    );
  }
}
