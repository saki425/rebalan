import 'package:decimal/decimal.dart';

import '../portfolio/portfolio_manager.dart';

enum RebalanceSide { none, buy, sell }

class RebalanceDecision {
  const RebalanceDecision({
    required this.side,
    required this.currentBtcWeight,
    required this.targetAfterBtcWeight,
    required this.quoteAmount,
    required this.btcQuantity,
    required this.reason,
  });
  final RebalanceSide side;
  final Decimal currentBtcWeight;
  final Decimal targetAfterBtcWeight;
  final Decimal quoteAmount;
  final Decimal btcQuantity;
  final String reason;
  bool get shouldTrade => side != RebalanceSide.none;
}

class RebalanceEngine {
  const RebalanceEngine({this.portfolios = const PortfolioManager()});
  final PortfolioManager portfolios;

  RebalanceDecision evaluate({
    required Decimal btcQuantity,
    required Decimal usdtQuantity,
    required Decimal btcPrice,
    required Decimal targetBtcWeight,
    required Decimal triggerDeviation,
    required Decimal repairRatio,
  }) {
    _validateRatio(targetBtcWeight, 'targetBtcWeight', allowEdges: true);
    _validateRatio(triggerDeviation, 'triggerDeviation', allowEdges: true);
    _validateRatio(repairRatio, 'repairRatio', allowEdges: true);
    final portfolio = portfolios.valueAmounts(
      btcQuantity: btcQuantity,
      usdtQuantity: usdtQuantity,
      btcPrice: btcPrice,
    );
    final current = portfolio.btcWeight;
    final upper = targetBtcWeight + triggerDeviation;
    final lower = targetBtcWeight - triggerDeviation;
    if (current < upper && current > lower ||
        portfolio.totalEquity == Decimal.zero) {
      return RebalanceDecision(
        side: RebalanceSide.none,
        currentBtcWeight: current,
        targetAfterBtcWeight: current,
        quoteAmount: Decimal.zero,
        btcQuantity: Decimal.zero,
        reason: 'WITHIN_BAND',
      );
    }
    final repairedTarget = current + (targetBtcWeight - current) * repairRatio;
    final quote = ((current - repairedTarget).abs() * portfolio.totalEquity);
    final quantity = (quote / btcPrice).toDecimal(
      scaleOnInfinitePrecision: PortfolioManager.weightScale,
    );
    final side = current >= upper ? RebalanceSide.sell : RebalanceSide.buy;
    return RebalanceDecision(
      side: side,
      currentBtcWeight: current,
      targetAfterBtcWeight: repairedTarget,
      quoteAmount: quote,
      btcQuantity: quantity,
      reason: side == RebalanceSide.sell
          ? 'BTC_WEIGHT_UPPER_TRIGGER'
          : 'BTC_WEIGHT_LOWER_TRIGGER',
    );
  }

  void _validateRatio(Decimal value, String name, {required bool allowEdges}) {
    if (value < Decimal.zero || value > Decimal.one) {
      throw ArgumentError.value(value, name, 'must be between 0 and 1');
    }
  }
}
