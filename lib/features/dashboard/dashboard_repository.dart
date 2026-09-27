import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/accounts/account_read_client.dart';
import '../../core/accounts/local_account_balance_source.dart';
import '../../core/domain/models.dart';
import '../settings/strategy_config_repository.dart';

class DashboardRepository {
  DashboardRepository(this.database, {this.accountBalanceSource});
  final Database database;
  final AccountBalanceSource? accountBalanceSource;

  Future<DashboardSnapshot> load() async {
    final rows = await database.query('accounts', orderBy: 'id');
    if (rows.length != 3) {
      throw StateError('Expected exactly three system accounts.');
    }
    final config = await StrategyConfigRepository(
      database,
    ).loadStrategyConfig();
    if (accountBalanceSource == null) return emptySnapshot(config: config);
    late final List<AccountBalance> balances;
    try {
      balances = await accountBalanceSource!.fetchBalances();
    } on MissingAccountCredentials {
      return emptySnapshot(config: config);
    }
    await _saveSnapshots(rows, balances);
    final metrics = await _loadMetrics();
    final enriched = balances
        .map(
          (account) => account.role == AccountRole.profit
              ? AccountBalance(
                  role: account.role,
                  name: account.name,
                  btc: account.btc,
                  usdt: account.usdt,
                  totalProfitReceived: metrics.profitWithdrawn,
                )
              : account,
        )
        .toList(growable: false);
    return _snapshot(
      accounts: enriched,
      isDemo: false,
      config: config,
      metrics: metrics,
    );
  }

  Future<void> _saveSnapshots(
    List<Map<String, Object?>> accountRows,
    List<AccountBalance> balances,
  ) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final ids = {
      for (final row in accountRows) row['role'] as String: row['id'] as int,
    };
    final batch = database.batch();
    for (final balance in balances) {
      final role = balance.role.name.toUpperCase();
      batch.insert('account_snapshots', {
        'account_id': ids[role],
        'btc_balance': balance.btc.toString(),
        'usdt_balance': balance.usdt.toString(),
        'btc_price': '0',
        'equity_usdt': balance.usdt.toString(),
        'source': 'BINANCE_API',
        'captured_at': now,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<_DashboardMetrics> _loadMetrics() async {
    final profitRows = await database.query(
      'profit_withdrawals',
      columns: ['actual_amount'],
    );
    final feeRows = await database.query('trades', columns: ['fee_amount']);
    final highRows = await database.query(
      'high_water_marks',
      columns: ['value_usdt'],
      orderBy: 'effective_at DESC, id DESC',
      limit: 1,
    );
    Decimal sum(List<Map<String, Object?>> rows, String column) => rows.fold(
          Decimal.zero,
          (total, row) => total + Decimal.parse(row[column] as String),
        );
    return _DashboardMetrics(
      profitWithdrawn: sum(profitRows, 'actual_amount'),
      totalFees: sum(feeRows, 'fee_amount'),
      highWaterMark: highRows.isEmpty
          ? Decimal.zero
          : Decimal.parse(highRows.single['value_usdt'] as String),
    );
  }

  static DashboardSnapshot demoSnapshot({StrategyConfig? config}) => _snapshot(
        accounts: [
          AccountBalance(
            role: AccountRole.funding,
            name: 'Funding Account',
            btc: Decimal.zero,
            usdt: Decimal.zero,
          ),
          AccountBalance(
            role: AccountRole.strategy,
            name: 'Strategy Account',
            btc: Decimal.zero,
            usdt: Decimal.zero,
          ),
          AccountBalance(
            role: AccountRole.profit,
            name: 'Profit Account',
            btc: Decimal.zero,
            usdt: Decimal.zero,
            totalProfitReceived: Decimal.zero,
          ),
        ],
        isDemo: true,
        config: config,
      );

  /// No synthetic balances are shown before all real account credentials exist.
  static DashboardSnapshot emptySnapshot({StrategyConfig? config}) => _snapshot(
        accounts: [
          AccountBalance(
              role: AccountRole.funding,
              name: 'Funding Account',
              btc: Decimal.zero,
              usdt: Decimal.zero),
          AccountBalance(
              role: AccountRole.strategy,
              name: 'Strategy Account',
              btc: Decimal.zero,
              usdt: Decimal.zero),
          AccountBalance(
              role: AccountRole.profit,
              name: 'Profit Account',
              btc: Decimal.zero,
              usdt: Decimal.zero),
        ],
        isDemo: true,
        config: config,
        btcPrice: Decimal.zero,
        change24h: Decimal.zero,
        strategyProfit: Decimal.zero,
        profitWithdrawn: Decimal.zero,
        highWaterMark: Decimal.zero,
        maxDrawdown: Decimal.zero,
        cagr: Decimal.zero,
        totalFees: Decimal.zero,
      );

  static DashboardSnapshot _snapshot({
    required List<AccountBalance> accounts,
    required bool isDemo,
    StrategyConfig? config,
    _DashboardMetrics? metrics,
    Decimal? btcPrice,
    Decimal? change24h,
    Decimal? strategyProfit,
    Decimal? profitWithdrawn,
    Decimal? highWaterMark,
    Decimal? maxDrawdown,
    Decimal? cagr,
    Decimal? totalFees,
  }) =>
      DashboardSnapshot(
        btcPrice: btcPrice ?? Decimal.zero,
        change24h: change24h ?? Decimal.zero,
        websocketStatus: ConnectionStatus.unknown,
        apiStatus: ConnectionStatus.unknown,
        lastRestCalibration: null,
        accounts: accounts,
        strategyStatus: StrategyStatus.paused,
        config: config ?? StrategyConfig.defaults(),
        strategyProfit: strategyProfit ?? Decimal.zero,
        profitWithdrawn:
            profitWithdrawn ?? metrics?.profitWithdrawn ?? Decimal.zero,
        highWaterMark: highWaterMark ?? metrics?.highWaterMark ?? Decimal.zero,
        maxDrawdown: maxDrawdown ?? Decimal.zero,
        cagr: cagr ?? Decimal.zero,
        totalFees: totalFees ?? metrics?.totalFees ?? Decimal.zero,
        isDemo: isDemo,
      );
}

class _DashboardMetrics {
  const _DashboardMetrics({
    required this.profitWithdrawn,
    required this.totalFees,
    required this.highWaterMark,
  });
  final Decimal profitWithdrawn;
  final Decimal totalFees;
  final Decimal highWaterMark;
}
