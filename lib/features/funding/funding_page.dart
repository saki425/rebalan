import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/domain/models.dart';
import '../../core/funding/funding_manager.dart';
import '../../core/funding/funding_execution_repository.dart';
import '../../core/funding/paper_funding_executor.dart';
import '../../core/portfolio/portfolio_manager.dart';
import '../../core/live/binance_live_client.dart';
import '../../core/live/credential_store.dart';
import '../../core/live/live_execution_service.dart';
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
  LiveOrderResponse? _liveOrder;
  String? _liveMessage;
  bool _liveMode = false;
  bool _executing = false;

  AccountBalance get _funding => widget.snapshot.byRole(AccountRole.funding);
  AccountBalance get _strategy => widget.snapshot.byRole(AccountRole.strategy);

  @override
  void initState() {
    super.initState();
    _depositController = TextEditingController(text: _funding.usdt.toString());
    _loadRunMode();
  }

  Future<void> _loadRunMode() async {
    final database = widget.database;
    if (database == null) return;
    final values = await StrategyConfigRepository(database).load();
    if (mounted) setState(() => _liveMode = values['runMode'] == 'LIVE');
  }

  @override
  void dispose() {
    _depositController.dispose();
    super.dispose();
  }

  void _calculate() {
    try {
      if (widget.snapshot.btcPrice <= Decimal.zero) {
        throw StateError('BTC 价格尚未同步，请先刷新首页市场数据');
      }
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

  Future<bool> _confirmLive(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认使用真实资金'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<(int, int, BinanceCredentials, String)> _liveContext(
    Database database,
  ) async {
    final values = await StrategyConfigRepository(database).load();
    if (values['runMode'] != 'LIVE') {
      throw StateError('当前运行模式不是 LIVE，已阻止真实 Funding 操作');
    }
    final fundingCredentials = await const SecureCredentialStore().read(
      AccountRole.funding,
    );
    final strategyCredentials = await const SecureCredentialStore().read(
      AccountRole.strategy,
    );
    if (fundingCredentials == null || !fundingCredentials.isValid) {
      throw StateError('请先配置 Funding Account API');
    }
    if (strategyCredentials == null ||
        strategyCredentials.accountEmail.trim().isEmpty) {
      throw StateError('请配置 Strategy Account 的 Binance 子账户邮箱');
    }
    final rows = await database.query('accounts', columns: ['id', 'role']);
    final ids = {
      for (final row in rows) row['role'] as String: row['id'] as int,
    };
    return (
      ids['FUNDING']!,
      ids['STRATEGY']!,
      fundingCredentials,
      strategyCredentials.accountEmail.trim(),
    );
  }

  Future<void> _executeLiveBuy() async {
    final database = widget.database;
    if (database == null || _executing) return;
    setState(() {
      _executing = true;
      _error = null;
      _liveMessage = null;
    });
    BinanceLiveClient? client;
    try {
      final (fundingId, _, credentials, _) = await _liveContext(database);
      client = BinanceLiveClient(credentials: credentials);
      await client.synchronizeTime();
      // A disconnected market stream can leave the page snapshot at zero.
      // Fetch a fresh REST price before calculating quantity, otherwise the
      // exchange rule check sees a zero notional and rejects the order.
      final price = widget.snapshot.btcPrice > Decimal.zero
          ? widget.snapshot.btcPrice
          : await client.currentPrice();
      final deposit = Decimal.parse(_depositController.text.trim());
      final plan = _manager.calculate(
        strategyAccount: _strategy,
        depositUsdt: deposit,
        btcPrice: price,
        targetBtcWeight: widget.snapshot.config.targetBtcWeight,
      );
      if (mounted) setState(() => _plan = plan);
      if (plan.buyBtcQuantity <= Decimal.zero) {
        if (mounted) setState(() => _liveMessage = '当前配置无需购买 BTC');
        return;
      }
      if (!await _confirmLive(
        'LIVE 真实买入 BTC',
        '将使用账户1真实资金买入约 ${plan.buyBtcQuantity} BTC，确认继续？',
      )) {
        return;
      }
      final restrictions = await client.apiRestrictions();
      if (restrictions['enableSpotAndMarginTrading'] != true ||
          restrictions['enableWithdrawals'] == true) {
        throw StateError('Funding API 权限不安全：需要开启现货交易并关闭提现权限');
      }
      final response =
          await LiveExecutionService(
            database: database,
            client: client,
          ).marketOrder(
            accountId: fundingId,
            side: 'BUY',
            requestedQuantity: plan.buyBtcQuantity,
            referencePrice: price,
            clientOrderId:
                'funding-buy-${DateTime.now().toUtc().microsecondsSinceEpoch}',
            idempotencyKey:
                'funding-buy-${DateTime.now().toUtc().microsecondsSinceEpoch}',
            reason: 'LIVE_FUNDING_ALLOCATION',
          );
      if (response.status != 'FILLED') {
        throw StateError('账户1订单状态为 ${response.status}，未执行划转');
      }
      if (mounted) {
        setState(() {
          _liveOrder = response;
          _liveMessage = 'LIVE BUY 已成交：${response.executedQuantity} BTC';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'LIVE 买入失败：$error');
    } finally {
      client?.close();
      if (mounted) setState(() => _executing = false);
    }
  }

  Future<void> _executeLiveTransfer() async {
    final database = widget.database;
    final order = _liveOrder;
    if (database == null || order == null || _executing) return;
    if (!await _confirmLive(
      'LIVE 划转到账户2',
      '将把本次成交 BTC 和剩余 USDT 从账户1划转到账户2，确认继续？',
    )) {
      return;
    }
    setState(() {
      _executing = true;
      _error = null;
    });
    BinanceLiveClient? client;
    try {
      final (fundingId, strategyId, credentials, strategyEmail) =
          await _liveContext(database);
      client = BinanceLiveClient(credentials: credentials);
      await client.synchronizeTime();
      final execution = LiveExecutionService(
        database: database,
        client: client,
      );
      if (order.executedQuantity > Decimal.zero) {
        await execution.siblingTransfer(
          fromAccountId: fundingId,
          toAccountId: strategyId,
          toEmail: strategyEmail,
          asset: 'BTC',
          amount: order.executedQuantity,
          clientTransferId: 'funding-btc-${order.orderId}',
          idempotencyKey: 'funding-btc-${order.orderId}',
          transferType: 'INTERNAL_TRANSFER',
          note: 'LIVE_FUNDING_ALLOCATION:${order.orderId}',
        );
      }
      final usdt = _plan?.remainingUsdt ?? Decimal.zero;
      if (usdt > Decimal.zero) {
        await execution.siblingTransfer(
          fromAccountId: fundingId,
          toAccountId: strategyId,
          toEmail: strategyEmail,
          asset: 'USDT',
          amount: usdt,
          clientTransferId: 'funding-usdt-${order.orderId}',
          idempotencyKey: 'funding-usdt-${order.orderId}',
          transferType: 'INTERNAL_TRANSFER',
          note: 'LIVE_FUNDING_ALLOCATION:${order.orderId}',
        );
      }
      if (mounted) {
        setState(() => _liveMessage = 'LIVE 账户1 → 账户2 划转已提交');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'LIVE 划转失败：$error');
    } finally {
      client?.close();
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                _liveMode
                    ? 'LIVE REAL MONEY：账户1真实下单和划转已解锁，每一步都需要人工确认。'
                    : '当前不是 LIVE：真实下单和划转已禁用。请先在系统参数中切换到 LIVE。',
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
                        onPressed: _calculate,
                        icon: const Icon(Icons.refresh),
                        label: const Text('读取资产比例'),
                      ),
                      FilledButton.icon(
                        onPressed: _calculate,
                        icon: const Icon(Icons.calculate),
                        label: const Text('计算配置'),
                      ),
                      FilledButton(
                        onPressed: _liveMode && !_executing
                            ? _executeLiveBuy
                            : null,
                        child: const Text('LIVE 下单购买'),
                      ),
                      FilledButton(
                        onPressed:
                            _liveMode && _liveOrder != null && !_executing
                            ? _executeLiveTransfer
                            : null,
                        child: const Text('LIVE 划转至账户2'),
                      ),
                      FilledButton(
                        onPressed:
                            widget.database == null || _executing || _liveMode
                            ? null
                            : _executePaper,
                        child: Text(
                          _executing
                              ? '执行中…'
                              : _liveMode
                              ? 'Paper 自动配置（LIVE 禁用）'
                              : 'Paper 自动配置并划转',
                        ),
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
          if (_liveMessage != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(_liveMessage!),
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
