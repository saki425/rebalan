import 'dart:math' as math;

import 'package:decimal/decimal.dart';

import '../portfolio/portfolio_manager.dart';
import '../strategy/rebalance_engine.dart';
import 'backtest_engine.dart';

class HistoricalCandle {
  const HistoricalCandle({
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });

  final DateTime openTime;
  final Decimal open;
  final Decimal high;
  final Decimal low;
  final Decimal close;
}

enum IntrabarStatus { resolved, ambiguousIntrabar }

abstract interface class IntrabarResolver {
  List<HistoricalCandle>? resolve(HistoricalCandle candle);
}

class OhlcBacktestTrade {
  const OhlcBacktestTrade({
    required this.timestamp,
    required this.price,
    required this.executionPrice,
    required this.side,
    required this.btcWeightBefore,
    required this.btcWeightAfter,
    required this.btcAmount,
    required this.usdtAmount,
    required this.fee,
    required this.slippage,
    required this.equity,
  });

  final DateTime timestamp;
  final Decimal price;
  final Decimal executionPrice;
  final RebalanceSide side;
  final Decimal btcWeightBefore;
  final Decimal btcWeightAfter;
  final Decimal btcAmount;
  final Decimal usdtAmount;
  final Decimal fee;
  final Decimal slippage;
  final Decimal equity;
}

class OhlcBacktestResult {
  const OhlcBacktestResult({
    required this.initialEquity,
    required this.finalEquity,
    required this.totalReturn,
    required this.cagr,
    required this.maximumDrawdown,
    required this.totalFees,
    required this.totalSlippage,
    required this.grossRebalancingProfit,
    required this.netRebalancingProfit,
    required this.finalBtc,
    required this.finalUsdt,
    required this.trades,
    required this.curve,
    required this.annualReturns,
    required this.ambiguousCandles,
  });

  final Decimal initialEquity;
  final Decimal finalEquity;
  final Decimal totalReturn;
  final Decimal cagr;
  final Decimal maximumDrawdown;
  final Decimal totalFees;
  final Decimal totalSlippage;
  final Decimal grossRebalancingProfit;
  final Decimal netRebalancingProfit;
  final Decimal finalBtc;
  final Decimal finalUsdt;
  final List<OhlcBacktestTrade> trades;
  final List<BacktestPoint> curve;
  final Map<String, Decimal> annualReturns;
  final List<HistoricalCandle> ambiguousCandles;

  int get tradeCount => trades.length;
  int get buyCount =>
      trades.where((trade) => trade.side == RebalanceSide.buy).length;
  int get sellCount => tradeCount - buyCount;
}

class OhlcBacktestEngine {
  const OhlcBacktestEngine({
    this.rebalanceEngine = const RebalanceEngine(),
    this.portfolios = const PortfolioManager(),
  });

  final RebalanceEngine rebalanceEngine;
  final PortfolioManager portfolios;

  OhlcBacktestResult run({
    required List<HistoricalCandle> candles,
    required Decimal initialCapital,
    required BacktestConfig config,
    IntrabarResolver? resolver,
  }) {
    if (candles.isEmpty) throw ArgumentError('candles cannot be empty');
    final ordered = [...candles]
      ..sort((a, b) => a.openTime.compareTo(b.openTime));
    final half = initialCapital * Decimal.parse('0.5');
    final initialBtc = (half / ordered.first.open).toDecimal(
      scaleOnInfinitePrecision: PortfolioManager.weightScale,
    );
    var state = _PortfolioState(btc: initialBtc, usdt: half);
    final trades = <OhlcBacktestTrade>[];
    final curve = <BacktestPoint>[];
    final ambiguous = <HistoricalCandle>[];

    for (final candle in ordered) {
      final highFirst = _walk(
        state.copy(),
        [candle.open, candle.high, candle.low, candle.close],
        candle.openTime,
        config,
      );
      final lowFirst = _walk(
        state.copy(),
        [candle.open, candle.low, candle.high, candle.close],
        candle.openTime,
        config,
      );
      _WalkResult selected;
      if (_equivalent(highFirst, lowFirst)) {
        selected = highFirst;
      } else {
        final children = resolver?.resolve(candle);
        if (children == null || children.isEmpty) {
          ambiguous.add(candle);
          // Conservative deterministic fallback: choose the path producing
          // lower closing equity, never the more favorable unknown ordering.
          selected =
              _equity(highFirst.state, candle.close) <=
                  _equity(lowFirst.state, candle.close)
              ? highFirst
              : lowFirst;
        } else {
          selected = _walkChildren(
            state.copy(),
            children,
            config,
            ambiguous,
            resolver!,
          );
        }
      }
      state = selected.state;
      trades.addAll(selected.trades);
      curve.add(
        BacktestPoint(
          time: candle.openTime,
          equity: _equity(state, candle.close),
          btcWeight: portfolios
              .valueAmounts(
                btcQuantity: state.btc,
                usdtQuantity: state.usdt,
                btcPrice: candle.close,
              )
              .btcWeight,
        ),
      );
    }

    final finalPrice = ordered.last.close;
    final finalEquity = _equity(state, finalPrice);
    final passiveEquity = initialBtc * finalPrice + half;
    final totalFees = trades.fold(
      Decimal.zero,
      (sum, trade) => sum + trade.fee,
    );
    final totalSlippage = trades.fold(
      Decimal.zero,
      (sum, trade) => sum + trade.slippage,
    );
    final netRebalancingProfit = finalEquity - passiveEquity;
    return OhlcBacktestResult(
      initialEquity: initialCapital,
      finalEquity: finalEquity,
      totalReturn: _ratio(finalEquity - initialCapital, initialCapital),
      cagr: _cagr(
        initialCapital,
        finalEquity,
        ordered.first.openTime,
        ordered.last.openTime,
      ),
      maximumDrawdown: _maximumDrawdown(curve),
      totalFees: totalFees,
      totalSlippage: totalSlippage,
      grossRebalancingProfit: netRebalancingProfit + totalFees + totalSlippage,
      netRebalancingProfit: netRebalancingProfit,
      finalBtc: state.btc,
      finalUsdt: state.usdt,
      trades: List.unmodifiable(trades),
      curve: List.unmodifiable(curve),
      annualReturns: _annualReturns(curve),
      ambiguousCandles: List.unmodifiable(ambiguous),
    );
  }

  _WalkResult _walkChildren(
    _PortfolioState initial,
    List<HistoricalCandle> children,
    BacktestConfig config,
    List<HistoricalCandle> unresolved,
    IntrabarResolver resolver,
  ) {
    var state = initial;
    final trades = <OhlcBacktestTrade>[];
    for (final child in children) {
      final highFirst = _walk(
        state.copy(),
        [child.open, child.high, child.low, child.close],
        child.openTime,
        config,
      );
      final lowFirst = _walk(
        state.copy(),
        [child.open, child.low, child.high, child.close],
        child.openTime,
        config,
      );
      late final _WalkResult selected;
      if (_equivalent(highFirst, lowFirst)) {
        selected = highFirst;
      } else {
        final grandchildren = resolver.resolve(child);
        if (grandchildren == null || grandchildren.isEmpty) {
          unresolved.add(child);
          selected =
              _equity(highFirst.state, child.close) <=
                  _equity(lowFirst.state, child.close)
              ? highFirst
              : lowFirst;
        } else {
          selected = _walkChildren(
            state.copy(),
            grandchildren,
            config,
            unresolved,
            resolver,
          );
        }
      }
      state = selected.state;
      trades.addAll(selected.trades);
    }
    return _WalkResult(state, trades);
  }

  _WalkResult _walk(
    _PortfolioState state,
    List<Decimal> path,
    DateTime timestamp,
    BacktestConfig config,
  ) {
    final trades = <OhlcBacktestTrade>[];
    for (var index = 0; index < path.length - 1; index++) {
      final from = path[index];
      final to = path[index + 1];
      final trigger = _nextTrigger(state, from, to, config);
      if (trigger != null) {
        final trade = _execute(
          state,
          trigger.$1,
          trigger.$2,
          timestamp,
          config,
        );
        trades.add(trade);
      }
    }
    return _WalkResult(state, trades);
  }

  (RebalanceSide, Decimal)? _nextTrigger(
    _PortfolioState state,
    Decimal from,
    Decimal to,
    BacktestConfig config,
  ) {
    if (state.btc <= Decimal.zero || state.usdt <= Decimal.zero) return null;
    final upper = config.targetBtcWeight + config.triggerDeviation;
    final lower = config.targetBtcWeight - config.triggerDeviation;
    final fromWeight = portfolios
        .valueAmounts(
          btcQuantity: state.btc,
          usdtQuantity: state.usdt,
          btcPrice: from,
        )
        .btcWeight;
    if (to > from) {
      if (fromWeight >= upper) return (RebalanceSide.sell, from);
      final price =
          _priceForWeight(state, upper) *
          (Decimal.one + Decimal.parse('0.000000000000001'));
      return price > from && price <= to ? (RebalanceSide.sell, price) : null;
    }
    if (to < from) {
      if (fromWeight <= lower) return (RebalanceSide.buy, from);
      final price =
          _priceForWeight(state, lower) *
          (Decimal.one - Decimal.parse('0.000000000000001'));
      return price < from && price >= to ? (RebalanceSide.buy, price) : null;
    }
    return null;
  }

  Decimal _priceForWeight(_PortfolioState state, Decimal weight) =>
      ((weight * state.usdt) / (state.btc * (Decimal.one - weight))).toDecimal(
        scaleOnInfinitePrecision: PortfolioManager.weightScale,
      );

  OhlcBacktestTrade _execute(
    _PortfolioState state,
    RebalanceSide side,
    Decimal marketPrice,
    DateTime timestamp,
    BacktestConfig config,
  ) {
    final before = portfolios.valueAmounts(
      btcQuantity: state.btc,
      usdtQuantity: state.usdt,
      btcPrice: marketPrice,
    );
    final decision = rebalanceEngine.evaluate(
      btcQuantity: state.btc,
      usdtQuantity: state.usdt,
      btcPrice: marketPrice,
      targetBtcWeight: config.targetBtcWeight,
      triggerDeviation: config.triggerDeviation,
      repairRatio: config.repairRatio,
    );
    if (!decision.shouldTrade || decision.side != side) {
      throw StateError('Shared RebalanceEngine rejected crossed trigger');
    }
    final executionPrice =
        marketPrice *
        (side == RebalanceSide.buy
            ? Decimal.one + config.slippageRate
            : Decimal.one - config.slippageRate);
    Decimal quantity;
    Decimal quote;
    if (side == RebalanceSide.buy) {
      final affordable = (state.usdt / (Decimal.one + config.feeRate))
          .toDecimal(scaleOnInfinitePrecision: PortfolioManager.weightScale);
      quote = decision.quoteAmount < affordable
          ? decision.quoteAmount
          : affordable;
      quantity = (quote / executionPrice).toDecimal(
        scaleOnInfinitePrecision: PortfolioManager.weightScale,
      );
      final fee = quote * config.feeRate;
      state.btc += quantity;
      state.usdt -= quote + fee;
    } else {
      quantity = decision.btcQuantity < state.btc
          ? decision.btcQuantity
          : state.btc;
      quote = quantity * executionPrice;
      final fee = quote * config.feeRate;
      state.btc -= quantity;
      state.usdt += quote - fee;
    }
    // Keep the rational denominator bounded over tens of thousands of bars.
    // Amounts remain Decimal; this is only a fixed 18-place exchange ledger
    // precision boundary, matching PortfolioManager's existing scale.
    state.btc = Decimal.parse(state.btc.toStringAsFixed(18));
    state.usdt = Decimal.parse(state.usdt.toStringAsFixed(18));
    final fee = quote * config.feeRate;
    final slippage = quantity * (executionPrice - marketPrice).abs();
    final after = portfolios.valueAmounts(
      btcQuantity: state.btc,
      usdtQuantity: state.usdt,
      btcPrice: marketPrice,
    );
    return OhlcBacktestTrade(
      timestamp: timestamp,
      price: marketPrice,
      executionPrice: executionPrice,
      side: side,
      btcWeightBefore: before.btcWeight,
      btcWeightAfter: after.btcWeight,
      btcAmount: quantity,
      usdtAmount: quote,
      fee: fee,
      slippage: slippage,
      equity: after.totalEquity,
    );
  }

  bool _equivalent(_WalkResult a, _WalkResult b) {
    if (a.trades.length != b.trades.length) return false;
    for (var index = 0; index < a.trades.length; index++) {
      if (a.trades[index].side != b.trades[index].side) return false;
    }
    return (a.state.btc - b.state.btc).abs() < Decimal.parse('0.00000001') &&
        (a.state.usdt - b.state.usdt).abs() < Decimal.parse('0.01');
  }

  Decimal _equity(_PortfolioState state, Decimal price) =>
      state.btc * price + state.usdt;

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

  Map<String, Decimal> _annualReturns(List<BacktestPoint> curve) {
    final groups = <String, List<BacktestPoint>>{};
    for (final point in curve) {
      groups.putIfAbsent('${point.time.year}', () => []).add(point);
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
    final years = end.difference(start).inSeconds / (365.25 * 86400);
    if (years <= 0) return Decimal.zero;
    final value =
        math.pow(finalEquity.toDouble() / initial.toDouble(), 1 / years) - 1;
    return Decimal.parse(value.toStringAsFixed(18));
  }

  Decimal _ratio(Decimal numerator, Decimal denominator) =>
      denominator == Decimal.zero
      ? Decimal.zero
      : (numerator / denominator).toDecimal(
          scaleOnInfinitePrecision: PortfolioManager.weightScale,
        );
}

class _PortfolioState {
  _PortfolioState({required this.btc, required this.usdt});
  Decimal btc;
  Decimal usdt;
  _PortfolioState copy() => _PortfolioState(btc: btc, usdt: usdt);
}

class _WalkResult {
  const _WalkResult(this.state, this.trades);
  final _PortfolioState state;
  final List<OhlcBacktestTrade> trades;
}
