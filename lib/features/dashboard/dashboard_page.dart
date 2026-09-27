import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/domain/models.dart';
import '../../core/market/binance_market_data_service.dart';
import '../../core/market/market_state.dart';
import '../../core/portfolio/portfolio_manager.dart';
import '../../core/runtime/paper_runtime_coordinator.dart';
import '../../core/strategy/account2_strategy_runner.dart';
import '../../core/accounts/local_account_balance_source.dart';
import '../../core/performance/high_water_mark_repository.dart';
import '../../core/recovery/execution_repository.dart';
import '../../core/recovery/local_recovery_remote_source.dart';
import '../../core/recovery/recovery_coordinator.dart';
import '../../core/live/binance_live_client.dart';
import '../../core/live/credential_store.dart';
import '../../core/live/live_execution_service.dart';
import '../../core/live/live_trading_gate.dart';
import '../../core/live/live_runtime_coordinator.dart';
import '../backtest/backtest_page.dart';
import 'dashboard_repository.dart';
import '../funding/funding_page.dart';
import '../records/records_page.dart';
import '../profit/profit_account_page.dart';
import '../settings/credentials_page.dart';
import '../settings/strategy_config_repository.dart';
import '../settings/strategy_settings_page.dart';
import '../../core/notifications/notification_service.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.repository,
    required this.marketDataService,
  });
  final DashboardRepository repository;
  final BinanceMarketDataService marketDataService;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  DashboardSnapshot? _snapshot;
  Object? _error;
  StreamSubscription<MarketState>? _marketSubscription;
  PaperRuntimeCoordinator? _paperRuntime;
  LiveRuntimeCoordinator? _liveRuntime;
  StreamSubscription<LiveRuntimeEvent>? _liveSubscription;
  StreamSubscription<StrategyRuntimeEvent>? _runtimeSubscription;
  String? _startupMessage;
  String _runMode = 'PAPER';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _marketSubscription?.cancel();
      _marketSubscription = null;
      await _runtimeSubscription?.cancel();
      _runtimeSubscription = null;
      await _liveSubscription?.cancel();
      _liveSubscription = null;
      await _paperRuntime?.dispose();
      _paperRuntime = null;
      await _liveRuntime?.dispose();
      _liveRuntime = null;
      if (mounted) setState(() => _startupMessage = null);
      final snapshot = await widget.repository.load();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
      });
      _marketSubscription = widget.marketDataService.states.listen((market) {
        if (!mounted) return;
        setState(() => _snapshot = _withMarket(_snapshot!, market));
      });
      await widget.marketDataService.start();
      final reconciled = await _reconcile(snapshot);
      if (!reconciled || !mounted) return;
      final values = await StrategyConfigRepository(
        widget.repository.database,
      ).load();
      if (mounted) setState(() => _runMode = values['runMode'] ?? 'PAPER');
      if (values['runMode'] != 'PAPER') return;
      final runtime = PaperRuntimeCoordinator(
        database: widget.repository.database,
        marketData: widget.marketDataService,
        strategyAccount: snapshot.byRole(AccountRole.strategy),
        profitAccount: snapshot.byRole(AccountRole.profit),
        notifications: notificationServiceFromEnvironment(),
      );
      _paperRuntime = runtime;
      _runtimeSubscription = runtime.states.listen((event) {
        if (!mounted || _snapshot == null) return;
        setState(
          () => _snapshot = _withStrategyStatus(
            _snapshot!,
            _strategyStatus(event.state),
          ),
        );
      });
      await runtime.start();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<bool> _reconcile(DashboardSnapshot snapshot) async {
    if (snapshot.isDemo) {
      if (mounted) setState(() => _startupMessage = '未配置真实账户：启动对账未执行');
      return true;
    }
    final source = widget.repository.accountBalanceSource;
    if (source is! LocalAccountBalanceSource) return false;
    final report = await RecoveryCoordinator(
      executions: ExecutionRepository(widget.repository.database),
      highWaterMarks: HighWaterMarkRepository(widget.repository.database),
      remote: LocalRecoveryRemoteSource(
        credentials: source.credentials,
        balances: source,
        marketData: widget.marketDataService,
      ),
    ).recover(DateTime.now().toUtc());
    if (!mounted) return false;
    setState(() {
      _startupMessage = '启动对账：${report.reason}';
      _snapshot = _withStrategyStatus(
        _snapshot!,
        report.state == RecoveryState.waitingOrder
            ? StrategyStatus.waitingOrder
            : report.tradingAllowed
            ? StrategyStatus.paused
            : StrategyStatus.apiError,
      );
    });
    return report.tradingAllowed;
  }

  @override
  void dispose() {
    _marketSubscription?.cancel();
    _runtimeSubscription?.cancel();
    _liveSubscription?.cancel();
    unawaited(_paperRuntime?.dispose());
    unawaited(_liveRuntime?.dispose());
    unawaited(widget.marketDataService.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorView(message: _error.toString());
    }
    if (_snapshot == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return DashboardView(
      snapshot: _snapshot!,
      database: widget.repository.database,
      onRefresh: _load,
      startupMessage: _startupMessage,
      liveRunning: _liveRuntime?.isRunning == true,
      runMode: _runMode,
      onToggleLive: _toggleLive,
    );
  }

  Future<void> _toggleLive() async {
    if (_liveRuntime?.isRunning == true) {
      await _liveRuntime!.stop();
      await _liveSubscription?.cancel();
      _liveSubscription = null;
      if (mounted) setState(() => _startupMessage = 'LIVE 已手动停止');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const _LiveConfirmationDialog(),
    );
    if (confirmed != true || !mounted || _snapshot == null) return;
    try {
      // PAPER and LIVE runtimes must never evaluate the same account together.
      await _paperRuntime?.dispose();
      _paperRuntime = null;
      final credentials = await const SecureCredentialStore().read(
        AccountRole.strategy,
      );
      if (credentials == null || !credentials.isValid)
        throw StateError('请先配置 Strategy Account API');
      final rows = await widget.repository.database.query(
        'accounts',
        columns: ['id', 'role'],
      );
      final strategyId =
          rows.firstWhere((row) => row['role'] == 'STRATEGY')['id'] as int;
      final values = await StrategyConfigRepository(
        widget.repository.database,
      ).load();
      final live = LiveRuntimeCoordinator(
        database: widget.repository.database,
        marketData: widget.marketDataService,
        credentials: credentials,
        accountId: strategyId,
        accountBalances: widget.repository.accountBalanceSource,
        config: LiveRuntimeConfig(
          enabled: true,
          confirmation: LiveTradingConfirmation.phrase,
          checkInterval: Duration(
            seconds: int.parse(values['strategyCheckInterval']!),
          ),
          targetBtcWeight: Decimal.parse(values['targetBTCWeight']!),
          triggerDeviation: Decimal.parse(values['triggerDeviation']!),
          repairRatio: Decimal.parse(values['repairRatio']!),
          enableProfitWithdrawal: values['enableProfitWithdrawal'] == 'true',
          profitWithdrawalRatio: Decimal.parse(
            values['profitWithdrawalRatio']!,
          ),
          safeTransferLimit: Decimal.parse(values['safeProfitTransferLimit']!),
          maxBtcWeightAfterProfitTransfer: Decimal.parse(
            values['maxBTCWeightAfterProfitTransfer']!,
          ),
        ),
      );
      final started = await live.start();
      if (!started) throw StateError('LIVE 安全检查未通过，请检查 API 权限、IP 白名单和提现权限');
      _liveRuntime = live;
      _liveSubscription = live.events.listen((event) {
        if (!mounted) return;
        setState(() => _startupMessage = 'LIVE ${event.state}：${event.reason}');
      });
      if (mounted) setState(() => _startupMessage = 'LIVE 已启动：真实策略检查已开始');
    } catch (error) {
      if (mounted) setState(() => _startupMessage = 'LIVE 启动失败：$error');
    }
  }
}

DashboardSnapshot _withMarket(DashboardSnapshot snapshot, MarketState market) =>
    DashboardSnapshot(
      btcPrice: market.price == Decimal.zero ? snapshot.btcPrice : market.price,
      change24h: market.change24h,
      websocketStatus: market.websocketStatus,
      apiStatus: market.apiStatus,
      lastRestCalibration: market.lastRestCalibration,
      accounts: snapshot.accounts,
      strategyStatus: market.websocketStatus == ConnectionStatus.disconnected
          ? StrategyStatus.websocketDisconnected
          : snapshot.strategyStatus,
      config: snapshot.config,
      strategyProfit: snapshot.strategyProfit,
      profitWithdrawn: snapshot.profitWithdrawn,
      highWaterMark: snapshot.highWaterMark,
      maxDrawdown: snapshot.maxDrawdown,
      cagr: snapshot.cagr,
      totalFees: snapshot.totalFees,
      isDemo: snapshot.isDemo,
    );

DashboardSnapshot _withStrategyStatus(
  DashboardSnapshot snapshot,
  StrategyStatus status,
) => DashboardSnapshot(
  btcPrice: snapshot.btcPrice,
  change24h: snapshot.change24h,
  websocketStatus: snapshot.websocketStatus,
  apiStatus: snapshot.apiStatus,
  lastRestCalibration: snapshot.lastRestCalibration,
  accounts: snapshot.accounts,
  strategyStatus: status,
  config: snapshot.config,
  strategyProfit: snapshot.strategyProfit,
  profitWithdrawn: snapshot.profitWithdrawn,
  highWaterMark: snapshot.highWaterMark,
  maxDrawdown: snapshot.maxDrawdown,
  cagr: snapshot.cagr,
  totalFees: snapshot.totalFees,
  isDemo: snapshot.isDemo,
);

StrategyStatus _strategyStatus(StrategyRuntimeState state) => switch (state) {
  StrategyRuntimeState.idle ||
  StrategyRuntimeState.cooldown ||
  StrategyRuntimeState.filled => StrategyStatus.running,
  StrategyRuntimeState.triggered ||
  StrategyRuntimeState.calculating ||
  StrategyRuntimeState.rebalancing => StrategyStatus.rebalancing,
  StrategyRuntimeState.orderSubmitted ||
  StrategyRuntimeState.partiallyFilled => StrategyStatus.waitingOrder,
  StrategyRuntimeState.apiError ||
  StrategyRuntimeState.error => StrategyStatus.apiError,
  StrategyRuntimeState.websocketDisconnected =>
    StrategyStatus.websocketDisconnected,
};

class DashboardView extends StatelessWidget {
  const DashboardView({
    super.key,
    required this.snapshot,
    this.database,
    this.onRefresh,
    this.startupMessage,
    this.liveRunning = false,
    this.runMode = 'PAPER',
    this.onToggleLive = _noop,
  });
  final DashboardSnapshot snapshot;
  final Database? database;
  final Future<void> Function()? onRefresh;
  final String? startupMessage;
  final bool liveRunning;
  final String runMode;
  final VoidCallback onToggleLive;

  @override
  Widget build(BuildContext context) {
    final strategy = snapshot.byRole(AccountRole.strategy);
    const portfolios = PortfolioManager();
    // An unconfigured real-data state intentionally has no synthetic price.
    // PortfolioManager requires a positive valuation price, so use a neutral
    // unit price only for zero-balance rendering until REST/WebSocket data is
    // available. The displayed market price remains 0.00.
    final valuationPrice = snapshot.btcPrice > Decimal.zero
        ? snapshot.btcPrice
        : Decimal.one;
    final total = portfolios.valueAccounts(snapshot.accounts, valuationPrice);
    final strategyValue = portfolios.valueAccount(strategy, valuationPrice);
    return Scaffold(
      appBar: AppBar(
        title: const Text('BTC / USDT Rebalance'),
        actions: [
          IconButton(
            tooltip: '账户1资金配置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    FundingPage(snapshot: snapshot, database: database),
              ),
            ),
            icon: const Icon(Icons.account_balance_wallet_outlined),
          ),
          IconButton(
            tooltip: '历史回测',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const BacktestPage()),
            ),
            icon: const Icon(Icons.query_stats),
          ),
          if (database case final database?)
            IconButton(
              tooltip: '利润账户',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProfitAccountPage(
                    database: database,
                    account: snapshot.byRole(AccountRole.profit),
                  ),
                ),
              ),
              icon: const Icon(Icons.savings_outlined),
            ),
          if (database case final database?) ...[
            IconButton(
              tooltip: '交易与资金记录',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RecordsPage(database: database),
                ),
              ),
              icon: const Icon(Icons.receipt_long_outlined),
            ),
            IconButton(
              tooltip: '系统参数',
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => StrategySettingsPage(
                      repository: StrategyConfigRepository(database),
                    ),
                  ),
                );
                await onRefresh?.call();
              },
              icon: const Icon(Icons.tune),
            ),
          ],
          IconButton(
            tooltip: '本机 API 凭据',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CredentialsPage(),
                ),
              );
              await onRefresh?.call();
            },
            icon: const Icon(Icons.security_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: ActionChip(
              label: Text(
                runMode == 'LIVE'
                    ? (liveRunning ? 'LIVE · RUNNING' : 'LIVE · READY')
                    : runMode == 'LIVE_TEST'
                    ? 'LIVE_TEST · SAFE'
                    : 'PAPER · SAFE',
              ),
              onPressed: onToggleLive,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: onRefresh ?? () async {},
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (snapshot.isDemo)
              const _Notice(text: '尚未连接真实 Binance 账户 · 请先配置三个子账户 API 凭据'),
            if (startupMessage != null) ...[
              const SizedBox(height: 10),
              _Notice(text: startupMessage!),
            ],
            const SizedBox(height: 16),
            _Section(
              title: '市场信息',
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _Metric(
                    label: 'BTC/USDT',
                    value: _money(snapshot.btcPrice),
                    accent: true,
                  ),
                  _Metric(label: '24h 涨跌', value: _percent(snapshot.change24h)),
                  _Metric(
                    label: 'WebSocket',
                    value: _connection(snapshot.websocketStatus),
                  ),
                  _Metric(
                    label: 'Binance API',
                    value: _connection(snapshot.apiStatus),
                  ),
                  _Metric(
                    label: 'REST 校准',
                    value:
                        snapshot.lastRestCalibration?.toLocal().toString() ??
                        '尚未校准',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: '总资产',
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _Metric(
                    label: 'BTC 数量',
                    value: '${_number(total.btcQuantity, 8)} BTC',
                  ),
                  _Metric(label: 'BTC 市值', value: _money(total.btcValue)),
                  _Metric(label: 'USDT 总额', value: _money(total.usdtQuantity)),
                  _Metric(
                    label: '总资产',
                    value: _money(total.totalEquity),
                    accent: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: '分账户资产',
              trailing: IconButton(
                tooltip: '刷新三个账户余额',
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth >= 900
                      ? (constraints.maxWidth - 24) / 3
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: snapshot.accounts
                        .map(
                          (account) => SizedBox(
                            width: width,
                            child: _AccountCard(
                              account: account,
                              price: valuationPrice,
                              database: database,
                              allAccounts: snapshot.accounts,
                              onRefresh: onRefresh,
                            ),
                          ),
                        )
                        .toList(),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: '策略状态',
              trailing: Chip(
                label: Text(snapshot.strategyStatus.name.toUpperCase()),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _Metric(
                    label: '当前 BTC 比例',
                    value: _percent(strategyValue.btcWeight),
                  ),
                  _Metric(
                    label: '目标比例',
                    value: _percent(snapshot.config.targetBtcWeight),
                  ),
                  _Metric(
                    label: '触发区间',
                    value:
                        '${_percent(snapshot.config.lowerTrigger)} — ${_percent(snapshot.config.upperTrigger)}',
                  ),
                  _Metric(
                    label: '修复比例',
                    value: _percent(snapshot.config.repairRatio),
                  ),
                  _Metric(
                    label: '盈利提取比例',
                    value: _percent(snapshot.config.profitWithdrawalRatio),
                  ),
                  _Metric(
                    label: '累计策略收益',
                    value: _money(snapshot.strategyProfit),
                  ),
                  _Metric(
                    label: '累计已提取',
                    value: _money(snapshot.profitWithdrawn),
                  ),
                  _Metric(
                    label: 'High Water Mark',
                    value: _money(snapshot.highWaterMark),
                  ),
                  _Metric(label: '最大回撤', value: _percent(snapshot.maxDrawdown)),
                  _Metric(label: 'CAGR', value: _percent(snapshot.cagr)),
                  _Metric(label: '累计手续费', value: _money(snapshot.totalFees)),
                  _Metric(
                    label: '检查周期',
                    value: '${snapshot.config.strategyCheckIntervalSeconds}s',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}

void _noop() {}

class _LiveConfirmationDialog extends StatelessWidget {
  const _LiveConfirmationDialog();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('启动真实 LIVE 策略？'),
    content: const Text(
      '这将允许账户2调用 Binance 真实下单接口。请确认已配置 IP 白名单、关闭提现权限，并准备使用真实资金。\n\n确认短语：ENABLE LIVE TRADING',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('确认启动 LIVE'),
      ),
    ],
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.accent = false,
  });
  final String label;
  final String value;
  final bool accent;
  @override
  Widget build(BuildContext context) => Container(
    width: 190,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF20252D),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF9AA4B2))),
        const SizedBox(height: 7),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: accent ? const Color(0xFFF4B740) : null,
          ),
        ),
      ],
    ),
  );
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.price,
    this.database,
    required this.allAccounts,
    this.onRefresh,
  });
  final AccountBalance account;
  final Decimal price;
  final Database? database;
  final List<AccountBalance> allAccounts;
  final Future<void> Function()? onRefresh;
  @override
  Widget build(BuildContext context) {
    final value = const PortfolioManager().valueAccount(account, price);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF20252D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            account.name,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const Divider(height: 24),
          _line('BTC', '${_number(account.btc, 8)} BTC'),
          _line('USDT', _money(account.usdt)),
          _line('总资产', _money(value.totalEquity)),
          if (account.role == AccountRole.strategy)
            _line('BTC 占比', _percent(value.btcWeight)),
          if (account.role == AccountRole.profit)
            _line('累计收到利润', _money(account.totalProfitReceived)),
          if (account.role == AccountRole.strategy && database != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _manualProfitTransfer(context),
              icon: const Icon(Icons.arrow_downward),
              label: const Text('测试提取 USDT 到账户3'),
            ),
          ],
          if (account.role == AccountRole.profit && database != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _manualTransferToFunding(context),
              icon: const Icon(Icons.arrow_upward),
              label: const Text('划转 USDT 到账户1'),
            ),
          ],
          if (account.role == AccountRole.funding && database != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FundingPage(
                    snapshot: DashboardSnapshot(
                      btcPrice: price,
                      change24h: Decimal.zero,
                      websocketStatus: ConnectionStatus.unknown,
                      apiStatus: ConnectionStatus.unknown,
                      lastRestCalibration: null,
                      accounts: allAccounts,
                      strategyStatus: StrategyStatus.paused,
                      config: StrategyConfig.defaults(),
                      strategyProfit: Decimal.zero,
                      profitWithdrawn: Decimal.zero,
                      highWaterMark: Decimal.zero,
                      maxDrawdown: Decimal.zero,
                      cagr: Decimal.zero,
                      totalFees: Decimal.zero,
                      isDemo: false,
                    ),
                    database: database,
                  ),
                ),
              ),
              icon: const Icon(Icons.swap_horiz),
              label: const Text('配置并划转到账户2'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _manualProfitTransfer(BuildContext context) async {
    final amount = await showDialog<Decimal>(
      context: context,
      builder: (_) => _ProfitAmountDialog(maximum: account.usdt),
    );
    if (amount == null || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认真实划转'),
        content: Text(
          '将从 Strategy Account 划转 $amount USDT 到 Profit Account。\n\n这会调用 Binance 真实 API，是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认真实划转'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final progress = ScaffoldMessenger.of(context)
      ..showSnackBar(const SnackBar(content: Text('正在提交真实划转…')));
    try {
      final store = const SecureCredentialStore();
      final credentials = await store.read(AccountRole.strategy);
      final profitCredentials = await store.read(AccountRole.profit);
      if (credentials == null ||
          profitCredentials == null ||
          !credentials.isValid ||
          !profitCredentials.isValid ||
          profitCredentials.accountEmail.isEmpty) {
        throw StateError('请先配置 Strategy 和 Profit 两个子账户 API，并填写 Profit 子账户邮箱');
      }
      final client = BinanceLiveClient(credentials: credentials);
      try {
        await client.synchronizeTime();
        final rawPermissions = await client.apiRestrictions();
        debugPrint('[LIVE_TRANSFER] Strategy API permissions: $rawPermissions');
        final permissions = ApiPermissionSnapshot.fromBinance(rawPermissions);
        if (!permissions.internalTransferEnabled ||
            permissions.withdrawalsEnabled)
          throw StateError('API 必须开启内部划转、关闭提现权限');
        final rows = await database!.query('accounts', columns: ['id', 'role']);
        int id(String role) =>
            rows.firstWhere((row) => row['role'] == role)['id'] as int;
        final execution = LiveExecutionService(
          database: database!,
          client: client,
        );
        final key =
            'manual-profit-${DateTime.now().toUtc().microsecondsSinceEpoch}';
        final transferId = await execution.siblingTransfer(
          fromAccountId: id('STRATEGY'),
          toAccountId: id('PROFIT'),
          toEmail: profitCredentials.accountEmail,
          asset: 'USDT',
          amount: amount,
          clientTransferId: key,
          idempotencyKey: key,
          transferType: 'MANUAL_PROFIT_TEST',
          note: 'Manual profit transfer test; bypassed profit-condition check',
        );
        progress.hideCurrentSnackBar();
        if (context.mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('真实划转成功，Transfer ID: $transferId')),
          );
        await onRefresh?.call();
      } finally {
        client.close();
      }
    } catch (error) {
      progress.hideCurrentSnackBar();
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('真实划转失败：$error')));
    }
  }

  Future<void> _manualTransferToFunding(BuildContext context) async {
    final amount = await showDialog<Decimal>(
      context: context,
      builder: (_) => _ProfitAmountDialog(maximum: account.usdt),
    );
    if (amount == null || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认真实划转'),
        content: Text(
          '将从 Profit Account 划转 $amount USDT 到 Funding Account。\n\n这会调用 Binance 真实 API，是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认真实划转'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context)
      ..showSnackBar(const SnackBar(content: Text('正在提交真实划转…')));
    try {
      final store = const SecureCredentialStore();
      final source = await store.read(AccountRole.profit);
      final destination = await store.read(AccountRole.funding);
      if (source == null ||
          destination == null ||
          !source.isValid ||
          !destination.isValid ||
          destination.accountEmail.isEmpty) {
        throw StateError('请先配置 Profit 和 Funding 两个子账户 API，并填写 Funding 子账户邮箱');
      }
      final client = BinanceLiveClient(credentials: source);
      try {
        await client.synchronizeTime();
        final rawPermissions = await client.apiRestrictions();
        debugPrint('[LIVE_TRANSFER] Profit API permissions: $rawPermissions');
        final permissions = ApiPermissionSnapshot.fromBinance(rawPermissions);
        if (!permissions.internalTransferEnabled ||
            permissions.withdrawalsEnabled)
          throw StateError('API 必须开启内部划转、关闭提现权限');
        final rows = await database!.query('accounts', columns: ['id', 'role']);
        int id(String role) =>
            rows.firstWhere((row) => row['role'] == role)['id'] as int;
        final execution = LiveExecutionService(
          database: database!,
          client: client,
        );
        final key =
            'manual-profit-to-funding-${DateTime.now().toUtc().microsecondsSinceEpoch}';
        final transferId = await execution.siblingTransfer(
          fromAccountId: id('PROFIT'),
          toAccountId: id('FUNDING'),
          toEmail: destination.accountEmail,
          asset: 'USDT',
          amount: amount,
          clientTransferId: key,
          idempotencyKey: key,
          transferType: 'MANUAL_PROFIT_TO_FUNDING',
          note: 'Manual Profit Account to Funding Account transfer',
        );
        messenger.hideCurrentSnackBar();
        if (context.mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('真实划转成功，Transfer ID: $transferId')),
          );
        await onRefresh?.call();
      } finally {
        client.close();
      }
    } catch (error) {
      messenger.hideCurrentSnackBar();
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('真实划转失败：$error')));
    }
  }
}

class _ProfitAmountDialog extends StatefulWidget {
  const _ProfitAmountDialog({required this.maximum});
  final Decimal maximum;
  @override
  State<_ProfitAmountDialog> createState() => _ProfitAmountDialogState();
}

class _ProfitAmountDialogState extends State<_ProfitAmountDialog> {
  late final TextEditingController _controller;
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('真实划转到 Profit Account'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: 'USDT 数量（最多 ${widget.maximum}）'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final value = Decimal.tryParse(_controller.text.trim());
          if (value != null && value > Decimal.zero && value <= widget.maximum)
            Navigator.pop(context, value);
        },
        child: const Text('下一步'),
      ),
    ],
  );
}

Widget _line(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(color: Color(0xFF9AA4B2))),
      ),
      Text(value),
    ],
  ),
);

class _Notice extends StatelessWidget {
  const _Notice({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF3B311B),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline, color: Color(0xFFF4B740)),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Text('数据库初始化失败\n$message', textAlign: TextAlign.center),
    ),
  );
}

String _number(Decimal value, int decimals) =>
    value.toDouble().toStringAsFixed(decimals);
String _money(Decimal value) =>
    value == Decimal.zero ? '--' : '\$${value.toDouble().toStringAsFixed(2)}';
String _percent(Decimal value) =>
    '${(value.toDouble() * 100).toStringAsFixed(2)}%';
String _connection(ConnectionStatus status) => switch (status) {
  ConnectionStatus.connected => 'CONNECTED',
  ConnectionStatus.disconnected => 'DISCONNECTED',
  ConnectionStatus.unknown => 'NOT CONNECTED',
};
