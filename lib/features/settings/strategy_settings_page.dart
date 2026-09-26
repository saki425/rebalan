import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import 'strategy_config_repository.dart';

class StrategySettingsPage extends StatefulWidget {
  const StrategySettingsPage({super.key, required this.repository});
  final StrategyConfigRepository repository;

  @override
  State<StrategySettingsPage> createState() => _StrategySettingsPageState();
}

class _StrategySettingsPageState extends State<StrategySettingsPage> {
  Map<String, String>? _values;
  String? _error;

  static const _decimalFields = {
    'targetBTCWeight': '目标 BTC 比例（0—1）',
    'triggerDeviation': '触发偏差（0—1）',
    'repairRatio': '偏差修复比例（0—1）',
    'profitWithdrawalRatio': '盈利提取比例（0—1）',
    'maxBTCWeightAfterProfitTransfer': '提盈后最大 BTC 比例',
    'minOrderUSDT': '最小订单 USDT',
    'tradingFeeRate': '手续费率',
    'slippageTolerance': '滑点容忍度',
    'safeProfitTransferLimit': '单次安全提盈上限 USDT',
  };
  static const _integerFields = {
    'strategyCheckInterval': '策略检查周期（秒）',
    'RESTBalanceSyncInterval': '余额同步周期（秒）',
    'FullSyncInterval': '完整同步周期（秒）',
    'cooldownSeconds': '冷却时间（秒）',
  };
  static const _booleanFields = {
    'enableProfitWithdrawal': '自动提取利润',
    'enableAutoFunding': '自动资金配置',
    'enableAutoRebalance': '自动再平衡',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await widget.repository.load();
      if (mounted) setState(() => _values = values);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _edit(String key, String label, bool integer) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        content: _ParameterEditor(
          label: label,
          initialValue: _values![key] ?? '',
          integer: integer,
          validDecimal: (text) => _validDecimal(key, text),
        ),
      ),
    );
    if (value == null) return;
    await widget.repository.save(key, value);
    await _load();
  }

  bool _validDecimal(String key, String text) {
    try {
      final value = Decimal.parse(text);
      if (value < Decimal.zero) return false;
      if (key.contains('Weight') ||
          key.contains('Ratio') ||
          key == 'triggerDeviation' ||
          key == 'tradingFeeRate' ||
          key == 'slippageTolerance') {
        return value <= Decimal.one;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _toggle(String key, bool value) async {
    await widget.repository.save(key, '$value');
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('系统参数')),
    body: _error != null
        ? Center(child: Text(_error!))
        : _values == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Card(
                child: ListTile(
                  leading: Icon(Icons.shield_outlined),
                  title: Text('运行模式：PAPER'),
                  subtitle: Text('LIVE 必须通过 Paper 验证与安全门，不能在参数页直接开启。'),
                ),
              ),
              const SizedBox(height: 12),
              for (final entry in _decimalFields.entries)
                Card(
                  child: ListTile(
                    title: Text(entry.value),
                    trailing: Text(_values![entry.key] ?? '—'),
                    onTap: () => _edit(entry.key, entry.value, false),
                  ),
                ),
              for (final entry in _integerFields.entries)
                Card(
                  child: ListTile(
                    title: Text(entry.value),
                    trailing: Text(_values![entry.key] ?? '—'),
                    onTap: () => _edit(entry.key, entry.value, true),
                  ),
                ),
              for (final entry in _booleanFields.entries)
                Card(
                  child: SwitchListTile(
                    title: Text(entry.value),
                    value: _values![entry.key] == 'true',
                    onChanged: (value) => _toggle(entry.key, value),
                  ),
                ),
            ],
          ),
  );
}

/// Owns its controller for the entire lifetime of the dialog route.  The
/// previous implementation kept the controller in the page state and
/// disposed it as soon as Navigator.pop completed, while the dialog was still
/// running its exit animation.
class _ParameterEditor extends StatefulWidget {
  const _ParameterEditor({
    required this.label,
    required this.initialValue,
    required this.integer,
    required this.validDecimal,
  });

  final String label;
  final String initialValue;
  final bool integer;
  final bool Function(String) validDecimal;

  @override
  State<_ParameterEditor> createState() => _ParameterEditorState();
}

class _ParameterEditorState extends State<_ParameterEditor> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Align(alignment: Alignment.centerLeft, child: Text(widget.label)),
      const SizedBox(height: 12),
      TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      const SizedBox(height: 16),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () {
              final text = _controller.text.trim();
              final valid = widget.integer
                  ? int.tryParse(text) != null && int.parse(text) > 0
                  : widget.validDecimal(text);
              if (valid) Navigator.pop(context, text);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ],
  );
}
