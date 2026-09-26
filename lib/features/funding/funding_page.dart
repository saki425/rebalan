import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/domain/models.dart';
import '../../core/funding/funding_manager.dart';
import '../../core/funding/funding_execution_repository.dart';
import '../../core/funding/paper_funding_executor.dart';
import '../../core/portfolio/portfolio_manager.dart';
import '../settings/strategy_config_repository.dart';

class FundingPage extends StatefulWidget {
  const FundingPage({super.key, required this.snapshot, this.database});
  final DashboardSnapshot snapshot;
  final Database? database;

  @override
  State<FundingPage> createState() => _FundingPageState();
}

class _FundingPageState extends State<FundingPage> {
  final _manager = const FundingManager();
  late final TextEditingController _depositController;
  FundingPlan? _plan;
  String? _error;
  PaperFundingResult? _execution;
  bool _executing = false;

  AccountBalance get _funding => widget.snapshot.byRole(AccountRole.funding);
  AccountBalance get _strategy => widget.snapshot.byRole(AccountRole.strategy);

  @override
  void initState() {
    super.initState();
    _depositController = TextEditingController(text: _funding.usdt.toString());
  }

  @override
  void dispose() {
    _depositController.dispose();
    super.dispose();
  }

  void _calculate() {
    try {
      final deposit = Decimal.parse(_depositController.text.trim());
      final plan = _manager.calculate(
        strategyAccount: _strategy,
        depositUsdt: deposit,
        btcPrice: widget.snapshot.btcPrice,
        targetBtcWeight: widget.snapshot.config.targetBtcWeight,
      );
      setState(() {
        _plan = plan;
        _error = null;
      });
    } catch (error) {
      setState(() {
        _plan = null;
        _error = '请输入有效的非负 USDT 金额：$error';
      });
    }
  }

  Future<void> _executePaper() async {
    final database = widget.database;
    if (database == null || _executing) return;
    _calculate();
    if (_plan == null) return;
    setState(() => _executing = true);
    try {
      final values = await StrategyConfigRepository(database).load();
      final executor = PaperFundingExecutor(
        fundingAccount: _funding,
        strategyAccount: _strategy,
        feeRate: Decimal.parse(values['tradingFeeRate']!),
        slippageRate: Decimal.parse(values['slippageTolerance']!),
      );
      final result = executor.execute(
        idempotencyKey:
            'paper-funding-${DateTime.now().toUtc().microsecondsSinceEpoch}',
        depositUsdt: Decimal.parse(_depositController.text.trim()),
        btcPrice: widget.snapshot.btcPrice,
        targetBtcWeight: widget.snapshot.config.targetBtcWeight,
      );
      await FundingExecutionRepository(database).save(result);
      if (mounted) {
        setState(() {
          _execution = result;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Paper 执行失败：$error');
    } finally {
      if (mounted) setState(() => _executing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = const PortfolioManager().valueAccount(
      _strategy,
      widget.snapshot.btcPrice,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Funding Account 配置')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('当前为 PAPER：可模拟购买和内部划转并写入本地流水，不会调用真实下单或划转接口。'),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('账户1资产', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  _row('BTC', '${_fixed(_funding.btc, 8)} BTC'),
                  _row('USDT', _money(_funding.usdt)),
                  _row(
                    '总资产',
                    _money(_funding.equity(widget.snapshot.btcPrice)),
                  ),
                  const Divider(height: 30),
                  Text(
                    '账户2当前结构',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  _row('BTC 比例', _percent(current.btcWeight)),
                  _row('USDT 比例', _percent(current.usdtWeight)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('新增资金配置', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _depositController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '准备投入的 USDT',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => setState(() {}),
                        icon: const Icon(Icons.refresh),
                        label: const Text('读取资产比例'),
                      ),
                      FilledButton.icon(
                        onPressed: _calculate,
                        icon: const Icon(Icons.calculate),
                        label: const Text('计算配置'),
                      ),
                      const FilledButton(onPressed: null, child: Text('下单购买')),
                      const FilledButton(
                        onPressed: null,
                        child: Text('划转至账户2'),
                      ),
                      FilledButton(
                        onPressed: widget.database == null || _executing
                            ? null
                            : _executePaper,
                        child: Text(_executing ? '执行中…' : 'Paper 自动配置并划转'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_plan != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('配置结果', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    _row('购买 BTC 金额', _money(_plan!.buyBtcValue)),
                    _row(
                      '预计 BTC 数量',
                      '${_fixed(_plan!.buyBtcQuantity, 8)} BTC',
                    ),
                    _row('保留并划转 USDT', _money(_plan!.remainingUsdt)),
                    const Divider(height: 26),
                    _row(
                      '转入后 BTC 比例',
                      _percent(_plan!.projectedStrategy.btcWeight),
                    ),
                    _row(
                      '转入后 USDT 比例',
                      _percent(_plan!.projectedStrategy.usdtWeight),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_execution != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Paper 执行完成',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    _row('幂等键', _execution!.idempotencyKey),
                    _row('订单', _execution!.order?.orderId ?? '无需购买'),
                    _row('划转记录', '${_execution!.transfers.length} 条'),
                    _row('状态', _execution!.state.name.toUpperCase()),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Widget _row(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 5),
  child: Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(color: Color(0xFF9AA4B2))),
      ),
      Text(value),
    ],
  ),
);
String _fixed(Decimal value, int places) =>
    value.toDouble().toStringAsFixed(places);
String _money(Decimal value) => '\$${value.toDouble().toStringAsFixed(2)}';
String _percent(Decimal value) =>
    '${(value.toDouble() * 100).toStringAsFixed(2)}%';
