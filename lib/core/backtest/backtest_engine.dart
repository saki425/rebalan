import 'dart:math' as math;

import 'package:decimal/decimal.dart';

import '../portfolio/portfolio_manager.dart';
import '../strategy/rebalance_engine.dart';

class HistoricalPrice {
  const HistoricalPrice({required this.time, required this.close});
  final DateTime time;
  final Decimal close;
}

class BacktestConfig {
  const BacktestConfig({
    required this.targetBtcWeight,
    required this.triggerDeviation,
    required this.repairRatio,
    required this.feeRate,
    required this.slippageRate,
    required this.cooldown,
  });
  final Decimal targetBtcWeight;
  final Decimal triggerDeviation;
  final Decimal repairRatio;
  final Decimal feeRate;
  final Decimal slippageRate;
  final Duration cooldown;
}

class BacktestTrade {
  const BacktestTrade({
    required this.time,
    required this.side,
    required this.marketPrice,
    required this.executionPrice,
    required this.btcQuantity,
    required this.quoteAmount,
    required this.fee,
    required this.weightBefore,
    required this.weightAfter,
  });
  final DateTime time;
  final RebalanceSide side;
  final Decimal marketPrice;
  final Decimal executionPrice;
  final Decimal btcQuantity;
  final Decimal quoteAmount;
  final Decimal fee;
  final Decimal weightBefore;
  final Decimal weightAfter;
}

class BacktestPoint {
  const BacktestPoint({
    required this.time,
    required this.equity,
    required this.btcWeight,
  });
  final DateTime time;
  final Decimal equity;
  final Decimal btcWeight;
}

class BacktestResult {
  const BacktestResult({
    required this.initialEquity,
    required this.finalEquity,
    required this.totalReturn,
    required this.cagr,
    required this.maximumDrawdown,
    required this.totalFees,
    required this.trades,
    required this.curve,
    required this.annualReturns,
    required this.monthlyReturns,
  });
  final Decimal initialEquity;
  final Decimal finalEquity;
  final Decimal totalReturn;
  final Decimal cagr;
  final Decimal maximumDrawdown;
  final Decimal totalFees;
  final List<BacktestTrade> trades;
  final List<BacktestPoint> curve;
  final Map<String, Decimal> annualReturns;
  final Map<String, Decimal> monthlyReturns;
  int get tradeCount => trades.length;
}

class BacktestEngine {
  const BacktestEngine({
    this.rebalanceEngine = const RebalanceEngine(),
    this.portfolios = const PortfolioManager(),
  });
  final RebalanceEngine rebalanceEngine;
  final PortfolioManager portfolios;

  BacktestResult run({
    required List<HistoricalPrice> prices,
    required Decimal initialBtc,
    required Decimal initialUsdt,
    required BacktestConfig config,
  }) {
    if (prices.isEmpty) {
      throw ArgumentError.value(prices, 'prices', 'cannot be empty');
    }
    final ordered = [...prices]..sort((a, b) => a.time.compareTo(b.time));
    var btc = initialBtc;
    var usdt = initialUsdt;
    var fees = Decimal.zero;
    DateTime? lastTradeAt;
    final trades = <BacktestTrade>[];
    final curve = <BacktestPoint>[];
    final initial = portfolios
        .valueAmounts(
          btcQuantity: btc,
          usdtQuantity: usdt,
          btcPrice: ordered.first.close,
        )
        .totalEquity;

    for (final price in ordered) {
      final before = portfolios.valueAmounts(
        btcQuantity: btc,
        usdtQuantity: usdt,
        btcPrice: price.close,
      );
      final cooldownComplete =
          lastTradeAt == null ||
          price.time.difference(lastTradeAt) >= config.cooldown;
      final decision = rebalanceEngine.evaluate(
        btcQuantity: btc,
        usdtQuantity: usdt,
        btcPrice: price.close,
        targetBtcWeight: config.targetBtcWeight,
        triggerDeviation: config.triggerDeviation,
        repairRatio: config.repairRatio,
      );
      if (decision.shouldTrade && cooldownComplete) {
        final multiplier = decision.side == RebalanceSide.buy
            ? Decimal.one + config.slippageRate
            : Decimal.one - config.slippageRate;
        final executionPrice = price.close * multiplier;
        Decimal quantity;
        Decimal quote;
        if (decision.side == RebalanceSide.buy) {
          final affordableQuote = (usdt / (Decimal.one + config.feeRate))
              .toDecimal(
                scaleOnInfinitePrecision: PortfolioManager.weightScale,
              );
          quote = _min(decision.quoteAmount, affordableQuote);
          quantity = (quote / executionPrice).toDecimal(
            scaleOnInfinitePrecision: PortfolioManager.weightScale,
          );
          final fee = quote * config.feeRate;
          btc += quantity;
          usdt -= quote + fee;
          fees += fee;
          lastTradeAt = price.time;
          final after = portfolios.valueAmounts(
            btcQuantity: btc,
            usdtQuantity: usdt,
            btcPrice: price.close,
          );
          trades.add(
            BacktestTrade(
              time: price.time,
              side: decision.side,
              marketPrice: price.close,
              executionPrice: executionPrice,
              btcQuantity: quantity,
              quoteAmount: quote,
              fee: fee,
              weightBefore: before.btcWeight,
              weightAfter: after.btcWeight,
            ),
          );
        } else {
          quantity = _min(decision.btcQuantity, btc);
          quote = quantity * executionPrice;
          final fee = quote * config.feeRate;
          btc -= quantity;
          usdt += quote - fee;
          fees += fee;
          lastTradeAt = price.time;
          final after = portfolios.valueAmounts(
            btcQuantity: btc,
            usdtQuantity: usdt,
            btcPrice: price.close,
          );
          trades.add(
            BacktestTrade(
              time: price.time,
              side: decision.side,
              marketPrice: price.close,
              executionPrice: executionPrice,
              btcQuantity: quantity,
              quoteAmount: quote,
              fee: fee,
              weightBefore: before.btcWeight,
              weightAfter: after.btcWeight,
            ),
          );
        }
      }
      final value = portfolios.valueAmounts(
        btcQuantity: btc,
        usdtQuantity: usdt,
        btcPrice: price.close,
      );
      curve.add(
        BacktestPoint(
          time: price.time,
          equity: value.totalEquity,
          btcWeight: value.btcWeight,
        ),
      );
    }
    final finalEquity = curve.last.equity;
    final totalReturn = _ratio(finalEquity - initial, initial);
    return BacktestResult(
      initialEquity: initial,
      finalEquity: finalEquity,
      totalReturn: totalReturn,
      cagr: _cagr(initial, finalEquity, ordered.first.time, ordered.last.time),
      maximumDrawdown: _maximumDrawdown(curve),
      totalFees: fees,
      trades: List.unmodifiable(trades),
      curve: List.unmodifiable(curve),
      annualReturns: _periodReturns(curve, annual: true),
      monthlyReturns: _periodReturns(curve, annual: false),
    );
  }

  Decimal _maximumDrawdown(List<BacktestPoint> curve) {
    var peak = curve.first.equity;
    var maximum = Decimal.zero;
    for (final point in curve) {
      if (point.equity > peak) peak = point.equity;
      final drawdown = _ratio(peak - point.equity, peak);
      if (drawdown > maximum) maximum = drawdown;
    }
    return maximum;
  }

  Map<String, Decimal> _periodReturns(
    List<BacktestPoint> curve, {
    required bool annual,
  }) {
    final groups = <String, List<BacktestPoint>>{};
    for (final point in curve) {
      final key = annual
          ? '${point.time.year}'
          : '${point.time.year}-${point.time.month.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => []).add(point);
    }
    return {
      for (final entry in groups.entries)
        entry.key: _ratio(
          entry.value.last.equity - entry.value.first.equity,
          entry.value.first.equity,
        ),
    };
  }

  Decimal _cagr(
    Decimal initial,
    Decimal finalEquity,
    DateTime start,
    DateTime end,
  ) {
    final years = end.difference(start).inSeconds / (365.25 * 24 * 3600);
    if (years < (1 / 365.25) || initial == Decimal.zero) return Decimal.zero;
    final value =
        math.pow(finalEquity.toDouble() / initial.toDouble(), 1 / years) - 1;
    if (!value.isFinite) return Decimal.zero;
    return Decimal.parse(value.toStringAsFixed(18));
  }

  Decimal _ratio(Decimal numerator, Decimal denominator) =>
      denominator == Decimal.zero
      ? Decimal.zero
      : (numerator / denominator).toDecimal(
          scaleOnInfinitePrecision: PortfolioManager.weightScale,
        );
  Decimal _min(Decimal a, Decimal b) => a < b ? a : b;
}
