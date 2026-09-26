import 'package:decimal/decimal.dart';

enum AccountRole { funding, strategy, profit }

enum StrategyStatus {
  running,
  paused,
  rebalancing,
  waitingOrder,
  apiError,
  websocketDisconnected,
}

enum ConnectionStatus { connected, disconnected, unknown }

class AccountBalance {
  AccountBalance({
    required this.role,
    required this.name,
    required this.btc,
    required this.usdt,
    Decimal? totalProfitReceived,
  }) : totalProfitReceived = totalProfitReceived ?? Decimal.zero;
  final AccountRole role;
  final String name;
  final Decimal btc;
  final Decimal usdt;
  final Decimal totalProfitReceived;

  Decimal btcValue(Decimal price) => btc * price;
  Decimal equity(Decimal price) => btcValue(price) + usdt;
  Decimal btcWeight(Decimal price) {
    final total = equity(price);
    return total == Decimal.zero
        ? Decimal.zero
        : (btcValue(price) / total).toDecimal(scaleOnInfinitePrecision: 18);
  }
}

class StrategyConfig {
  const StrategyConfig({
    required this.targetBtcWeight,
    required this.triggerDeviation,
    required this.repairRatio,
    required this.profitWithdrawalRatio,
    required this.strategyCheckIntervalSeconds,
    required this.restBalanceSyncIntervalSeconds,
    required this.fullSyncIntervalSeconds,
    required this.maxBtcWeightAfterProfitTransfer,
  });
  factory StrategyConfig.defaults() => StrategyConfig(
    targetBtcWeight: Decimal.parse('0.50'),
    triggerDeviation: Decimal.parse('0.10'),
    repairRatio: Decimal.parse('0.25'),
    profitWithdrawalRatio: Decimal.parse('0.20'),
    strategyCheckIntervalSeconds: 5,
    restBalanceSyncIntervalSeconds: 60,
    fullSyncIntervalSeconds: 300,
    maxBtcWeightAfterProfitTransfer: Decimal.parse('0.58'),
  );
  final Decimal targetBtcWeight;
  final Decimal triggerDeviation;
  final Decimal repairRatio;
  final Decimal profitWithdrawalRatio;
  final int strategyCheckIntervalSeconds;
  final int restBalanceSyncIntervalSeconds;
  final int fullSyncIntervalSeconds;
  final Decimal maxBtcWeightAfterProfitTransfer;
  Decimal get upperTrigger => targetBtcWeight + triggerDeviation;
  Decimal get lowerTrigger => targetBtcWeight - triggerDeviation;
}

class DashboardSnapshot {
  const DashboardSnapshot({
    required this.btcPrice,
    required this.change24h,
    required this.websocketStatus,
    required this.apiStatus,
    required this.lastRestCalibration,
    required this.accounts,
    required this.strategyStatus,
    required this.config,
    required this.strategyProfit,
    required this.profitWithdrawn,
    required this.highWaterMark,
    required this.maxDrawdown,
    required this.cagr,
    required this.totalFees,
    required this.isDemo,
  });
  final Decimal btcPrice;
  final Decimal change24h;
  final ConnectionStatus websocketStatus;
  final ConnectionStatus apiStatus;
  final DateTime? lastRestCalibration;
  final List<AccountBalance> accounts;
  final StrategyStatus strategyStatus;
  final StrategyConfig config;
  final Decimal strategyProfit;
  final Decimal profitWithdrawn;
  final Decimal highWaterMark;
  final Decimal maxDrawdown;
  final Decimal cagr;
  final Decimal totalFees;
  final bool isDemo;

  AccountBalance byRole(AccountRole role) =>
      accounts.firstWhere((account) => account.role == role);
  Decimal get totalBtc =>
      accounts.fold(Decimal.zero, (sum, account) => sum + account.btc);
  Decimal get totalUsdt =>
      accounts.fold(Decimal.zero, (sum, account) => sum + account.usdt);
  Decimal get totalEquity => totalBtc * btcPrice + totalUsdt;
}
