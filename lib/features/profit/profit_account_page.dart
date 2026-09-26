import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/domain/models.dart';

class ProfitAccountPage extends StatelessWidget {
  const ProfitAccountPage({
    super.key,
    required this.database,
    required this.account,
  });
  final Database database;
  final AccountBalance account;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Profit Account')),
    body: FutureBuilder<_ProfitSummary>(
      future: _load(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final summary = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Wrap(
                  spacing: 28,
                  runSpacing: 16,
                  children: [
                    _metric('当前 USDT', account.usdt),
                    _metric('本月利润', summary.month),
                    _metric('今年利润', summary.year),
                    _metric('历史累计利润', summary.total),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                title: const Text('最近一次收款'),
                subtitle: Text(summary.lastAt ?? '暂无'),
                trailing: const Text('Strategy Account'),
              ),
            ),
            const SizedBox(height: 16),
            Text('利润记录', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            if (summary.rows.isEmpty)
              const Card(child: ListTile(title: Text('暂无利润划转')))
            else
              for (final row in summary.rows)
                Card(
                  child: ListTile(
                    title: Text('\$${row.amount.toString()} USDT'),
                    subtitle: Text(row.createdAt),
                    trailing: Text(row.status),
                  ),
                ),
          ],
        );
      },
    ),
  );

  Future<_ProfitSummary> _load() async {
    final rows = await database.rawQuery('''
      SELECT profit_withdrawals.actual_amount,
             profit_withdrawals.created_at,
             transfers.status
      FROM profit_withdrawals
      JOIN transfers ON transfers.id = profit_withdrawals.transfer_id
      ORDER BY profit_withdrawals.created_at DESC
    ''');
    final now = DateTime.now().toUtc();
    final records = rows
        .map(
          (row) => _ProfitRow(
            amount: Decimal.parse(row['actual_amount'] as String),
            createdAt: row['created_at'] as String,
            status: row['status'] as String,
          ),
        )
        .toList(growable: false);
    Decimal sum(bool Function(DateTime at) include) => records.fold(
      Decimal.zero,
      (total, row) => include(DateTime.parse(row.createdAt).toUtc())
          ? total + row.amount
          : total,
    );
    return _ProfitSummary(
      total: sum((_) => true),
      year: sum((at) => at.year == now.year),
      month: sum((at) => at.year == now.year && at.month == now.month),
      lastAt: records.isEmpty ? null : records.first.createdAt,
      rows: records,
    );
  }
}

Widget _metric(String label, Decimal value) => SizedBox(
  width: 170,
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Color(0xFF9AA4B2))),
      const SizedBox(height: 6),
      Text(
        '\$${value.toDouble().toStringAsFixed(2)}',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
    ],
  ),
);

class _ProfitSummary {
  const _ProfitSummary({
    required this.total,
    required this.year,
    required this.month,
    required this.lastAt,
    required this.rows,
  });
  final Decimal total;
  final Decimal year;
  final Decimal month;
  final String? lastAt;
  final List<_ProfitRow> rows;
}

class _ProfitRow {
  const _ProfitRow({
    required this.amount,
    required this.createdAt,
    required this.status,
  });
  final Decimal amount;
  final String createdAt;
  final String status;
}
