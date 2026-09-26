import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import '../portfolio/portfolio_manager.dart';

class FundingPlan {
  const FundingPlan({
    required this.depositUsdt,
    required this.strategyBefore,
    required this.targetBtcWeight,
    required this.rawBuyBtcValue,
    required this.buyBtcValue,
    required this.buyBtcQuantity,
    required this.remainingUsdt,
    required this.projectedStrategy,
  });

  final Decimal depositUsdt;
  final PortfolioValuation strategyBefore;
  final Decimal targetBtcWeight;
  final Decimal rawBuyBtcValue;
  final Decimal buyBtcValue;
  final Decimal buyBtcQuantity;
  final Decimal remainingUsdt;
  final PortfolioValuation projectedStrategy;

  bool get requiresBtcPurchase => buyBtcValue > Decimal.zero;
}

class FundingManager {
  const FundingManager({this.portfolioManager = const PortfolioManager()});
  final PortfolioManager portfolioManager;

  FundingPlan calculate({
    required AccountBalance strategyAccount,
    required Decimal depositUsdt,
    required Decimal btcPrice,
    required Decimal targetBtcWeight,
  }) {
    if (strategyAccount.role != AccountRole.strategy) {
      throw const FundingCalculationException(
        'Funding plan requires the strategy account',
      );
    }
    if (depositUsdt < Decimal.zero) {
      throw const FundingCalculationException('Deposit cannot be negative');
    }
    if (targetBtcWeight < Decimal.zero || targetBtcWeight > Decimal.one) {
      throw const FundingCalculationException(
        'Target BTC weight must be between zero and one',
      );
    }

    final before = portfolioManager.valueAccount(strategyAccount, btcPrice);
    final combinedEquity = before.totalEquity + depositUsdt;
    final targetBtcValue = combinedEquity * targetBtcWeight;
    final rawBuy = targetBtcValue - before.btcValue;
    final buyValue = _clamp(rawBuy, Decimal.zero, depositUsdt);
    final buyQuantity = (buyValue / btcPrice).toDecimal(
      scaleOnInfinitePrecision: PortfolioManager.weightScale,
    );
    final remainingUsdt = depositUsdt - buyValue;
    final projected = portfolioManager.valueAmounts(
      btcQuantity: strategyAccount.btc + buyQuantity,
      usdtQuantity: strategyAccount.usdt + remainingUsdt,
      btcPrice: btcPrice,
    );

    return FundingPlan(
      depositUsdt: depositUsdt,
      strategyBefore: before,
      targetBtcWeight: targetBtcWeight,
      rawBuyBtcValue: rawBuy,
      buyBtcValue: buyValue,
      buyBtcQuantity: buyQuantity,
      remainingUsdt: remainingUsdt,
      projectedStrategy: projected,
    );
  }

  Decimal _clamp(Decimal value, Decimal minimum, Decimal maximum) {
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
  }
}

class FundingCalculationException implements Exception {
  const FundingCalculationException(this.message);
  final String message;
  @override
  String toString() => 'FundingCalculationException: $message';
}
