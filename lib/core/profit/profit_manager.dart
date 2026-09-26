import 'package:decimal/decimal.dart';

import '../performance/high_water_mark_manager.dart';
import '../portfolio/portfolio_manager.dart';
import '../strategy/rebalance_engine.dart';

enum ProfitDecisionReason {
  approved,
  disabled,
  notFilledSell,
  noNewProfit,
  noAvailableUsdt,
  weightProtection,
}

class ProfitWithdrawalRequest {
  const ProfitWithdrawalRequest({
    required this.side,
    required this.orderFilled,
    required this.strategyBtc,
    required this.strategyUsdt,
    required this.btcPrice,
    required this.availableProfitUsdt,
    required this.safeTransferLimit,
    required this.withdrawalRatio,
    required this.maxBtcWeightAfterTransfer,
    required this.enabled,
  });
  final RebalanceSide side;
  final bool orderFilled;
  final Decimal strategyBtc;
  final Decimal strategyUsdt;
  final Decimal btcPrice;
  final Decimal availableProfitUsdt;
  final Decimal safeTransferLimit;
  final Decimal withdrawalRatio;
  final Decimal maxBtcWeightAfterTransfer;
  final bool enabled;
}

class ProfitWithdrawalDecision {
  const ProfitWithdrawalDecision({
    required this.reason,
    required this.currentEquity,
    required this.highWaterMark,
    required this.newProfit,
    required this.requestedAmount,
    required this.weightSafeLimit,
    required this.transferAmount,
    required this.btcWeightBefore,
    required this.btcWeightAfter,
  });
  final ProfitDecisionReason reason;
  final Decimal currentEquity;
  final Decimal highWaterMark;
  final Decimal newProfit;
  final Decimal requestedAmount;
  final Decimal weightSafeLimit;
  final Decimal transferAmount;
  final Decimal btcWeightBefore;
  final Decimal btcWeightAfter;
  bool get shouldTransfer =>
      reason == ProfitDecisionReason.approved && transferAmount > Decimal.zero;
}

class ProfitManager {
  const ProfitManager({this.portfolios = const PortfolioManager()});
  final PortfolioManager portfolios;

  ProfitWithdrawalDecision evaluate(
    ProfitWithdrawalRequest request,
    HighWaterMarkManager highWaterMark,
  ) {
    _validate(request);
    final portfolio = portfolios.valueAmounts(
      btcQuantity: request.strategyBtc,
      usdtQuantity: request.strategyUsdt,
      btcPrice: request.btcPrice,
    );
    final assessment = highWaterMark.assess(portfolio.totalEquity);
    ProfitWithdrawalDecision denied(ProfitDecisionReason reason) =>
        ProfitWithdrawalDecision(
          reason: reason,
          currentEquity: portfolio.totalEquity,
          highWaterMark: assessment.highWaterMark,
          newProfit: assessment.newProfit,
          requestedAmount: Decimal.zero,
          weightSafeLimit: Decimal.zero,
          transferAmount: Decimal.zero,
          btcWeightBefore: portfolio.btcWeight,
          btcWeightAfter: portfolio.btcWeight,
        );

    if (!request.enabled) return denied(ProfitDecisionReason.disabled);
    if (request.side != RebalanceSide.sell || !request.orderFilled) {
      return denied(ProfitDecisionReason.notFilledSell);
    }
    if (!assessment.hasNewProfit) {
      return denied(ProfitDecisionReason.noNewProfit);
    }
    if (request.availableProfitUsdt <= Decimal.zero ||
        request.strategyUsdt <= Decimal.zero) {
      return denied(ProfitDecisionReason.noAvailableUsdt);
    }

    final requested = assessment.newProfit * request.withdrawalRatio;
    final btcValue = portfolio.btcValue;
    final minimumEquityAfter = (btcValue / request.maxBtcWeightAfterTransfer)
        .toDecimal(
          scaleOnInfinitePrecision: PortfolioManager.weightScale,
          toBigInt: (value) => value.ceil(),
        );
    final weightLimitRaw = portfolio.totalEquity - minimumEquityAfter;
    final weightLimit = weightLimitRaw > Decimal.zero
        ? weightLimitRaw
        : Decimal.zero;
    final transfer = _minimum([
      requested,
      request.availableProfitUsdt,
      request.safeTransferLimit,
      request.strategyUsdt,
      weightLimit,
    ]);
    if (transfer <= Decimal.zero) {
      return denied(ProfitDecisionReason.weightProtection);
    }
    final after = portfolios.valueAmounts(
      btcQuantity: request.strategyBtc,
      usdtQuantity: request.strategyUsdt - transfer,
      btcPrice: request.btcPrice,
    );
    return ProfitWithdrawalDecision(
      reason: ProfitDecisionReason.approved,
      currentEquity: portfolio.totalEquity,
      highWaterMark: assessment.highWaterMark,
      newProfit: assessment.newProfit,
      requestedAmount: requested,
      weightSafeLimit: weightLimit,
      transferAmount: transfer,
      btcWeightBefore: portfolio.btcWeight,
      btcWeightAfter: after.btcWeight,
    );
  }

  Decimal _minimum(List<Decimal> values) =>
      values.reduce((current, value) => value < current ? value : current);

  void _validate(ProfitWithdrawalRequest request) {
    for (final entry in {
      'withdrawalRatio': request.withdrawalRatio,
      'maxBtcWeightAfterTransfer': request.maxBtcWeightAfterTransfer,
    }.entries) {
      if (entry.value <= Decimal.zero || entry.value > Decimal.one) {
        throw ArgumentError.value(
          entry.value,
          entry.key,
          'must be greater than 0 and no more than 1',
        );
      }
    }
    if (request.availableProfitUsdt < Decimal.zero ||
        request.safeTransferLimit < Decimal.zero) {
      throw ArgumentError('Transfer limits cannot be negative');
    }
  }
}
