import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

class RecordsPage extends StatefulWidget {
  const RecordsPage({super.key, required this.database});
  final Database database;

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _tables = const [
    ('orders', '订单'),
    ('trades', '成交'),
    ('transfers', '划转'),
    ('profit_withdrawals', '利润'),
    ('deposits', '存入'),
    ('withdrawals', '提出'),
    ('strategy_events', '策略事件'),
    ('system_logs', '日志'),
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tables.length, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('交易与资金记录'),
          bottom: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: [for (final item in _tables) Tab(text: item.$2)],
          ),
        ),
        body: TabBarView(
          controller: _tabs,
          children: [
            for (final item in _tables)
              _RecordList(database: widget.database, table: item.$1),
          ],
        ),
      );
}

class _RecordList extends StatelessWidget {
  const _RecordList({required this.database, required this.table});
  final Database database;
  final String table;

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<Map<String, Object?>>>(
        future: database.query(table, orderBy: 'id DESC', limit: 200),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snapshot.data!;
          if (rows.isEmpty) return const Center(child: Text('暂无记录'));
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: rows.length,
            separatorBuilder: (_, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final row = rows[index];
              final title = _title(row);
              final details = row.entries
                  .where((entry) => entry.key != 'id')
                  .map((entry) => '${entry.key}: ${entry.value ?? '—'}')
                  .join('\n');
              return Card(
                child: ExpansionTile(
                  title: Text(title),
                  subtitle: Text(_time(row)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(details),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );

  String _title(Map<String, Object?> row) =>
      '${row['side'] ?? row['transfer_type'] ?? row['level'] ?? table}  #${row['id']}';
  String _time(Map<String, Object?> row) =>
      '${row['executed_at'] ?? row['created_at'] ?? '—'}';
}
