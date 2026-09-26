import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import '../market/market_state.dart';
import '../portfolio/portfolio_manager.dart';
import '../strategy/rebalance_engine.dart';

enum SimulatedOrderStatus { submitted, partiallyFilled, filled, rejected }

enum PaperEngineState {
  idle,
  calculating,
  orderSubmitted,
  partiallyFilled,
  filled,
  cooldown,
  paused,
  error,
}

class PaperTradingConfig {
  const PaperTradingConfig({
    required this.targetBtcWeight,
    required this.triggerDeviation,
    required this.repairRatio,
    required this.feeRate,
    required this.slippageRate,
    required this.minimumOrderUsdt,
    required this.cooldown,
    this.maximumPriceAge = const Duration(seconds: 15),
  });
  final Decimal targetBtcWeight;
  final Decimal triggerDeviation;
  final Decimal repairRatio;
  final Decimal feeRate;
  final Decimal slippageRate;
  final Decimal minimumOrderUsdt;
  final Duration cooldown;
  final Duration maximumPriceAge;
}

class PaperOrder {
  const PaperOrder({
    required this.clientOrderId,
    required this.idempotencyKey,
    required this.side,
    required this.marketPrice,
    required this.executionPrice,
    required this.requestedQuote,
    required this.requestedBtc,
    required this.executedQuote,
    required this.executedBtc,
    required this.fee,
    required this.status,
    required this.createdAt,
  });
  final String clientOrderId;
  final String idempotencyKey;
  final RebalanceSide side;
  final Decimal marketPrice;
  final Decimal executionPrice;
  final Decimal requestedQuote;
  final Decimal requestedBtc;
  final Decimal executedQuote;
  final Decimal executedBtc;
  final Decimal fee;
  final SimulatedOrderStatus status;
  final DateTime createdAt;

  bool get isOpen =>
      status == SimulatedOrderStatus.submitted ||
      status == SimulatedOrderStatus.partiallyFilled;
  PaperOrder copyWith({
    Decimal? executedQuote,
    Decimal? executedBtc,
    Decimal? fee,
    SimulatedOrderStatus? status,
  }) => PaperOrder(
    clientOrderId: clientOrderId,
    idempotencyKey: idempotencyKey,
    side: side,
    marketPrice: marketPrice,
    executionPrice: executionPrice,
    requestedQuote: requestedQuote,
    requestedBtc: requestedBtc,
    executedQuote: executedQuote ?? this.executedQuote,
    executedBtc: executedBtc ?? this.executedBtc,
    fee: fee ?? this.fee,
    status: status ?? this.status,
    createdAt: createdAt,
  );
}

class PaperBroker {
  PaperBroker({
    required Decimal initialBtc,
    required Decimal initialUsdt,
    required this.feeRate,
    required this.slippageRate,
  }) : _btc = initialBtc,
       _usdt = initialUsdt;
  final Decimal feeRate;
  final Decimal slippageRate;
  Decimal _btc;
  Decimal _usdt;
  int _sequence = 0;
  PaperOrder? _activeOrder;

  Decimal get btc => _btc;
  Decimal get usdt => _usdt;
  PaperOrder? get activeOrder => _activeOrder;

  void withdrawUsdt(Decimal amount) {
    if (amount <= Decimal.zero || amount > _usdt) {
      throw ArgumentError.value(amount, 'amount');
    }
    _usdt -= amount;
  }

  PaperOrder submit(
    RebalanceDecision decision,
    Decimal marketPrice,
    DateTime now, {
    Decimal? fillRatio,
  }) {
    final effectiveFillRatio = fillRatio ?? Decimal.one;
    if (_activeOrder?.isOpen == true) {
      throw StateError('An unfinished paper order already exists');
    }
    if (effectiveFillRatio < Decimal.zero || effectiveFillRatio > Decimal.one) {
      throw ArgumentError.value(effectiveFillRatio, 'fillRatio');
    }
    final executionPrice =
        marketPrice *
        (decision.side == RebalanceSide.buy
            ? Decimal.one + slippageRate
            : Decimal.one - slippageRate);
    final sequence = ++_sequence;
    final order = PaperOrder(
      clientOrderId: 'paper-$sequence',
      idempotencyKey: 'paper-${now.microsecondsSinceEpoch}-$sequence',
      side: decision.side,
      marketPrice: marketPrice,
      executionPrice: executionPrice,
      requestedQuote: decision.quoteAmount,
      requestedBtc: decision.btcQuantity,
      executedQuote: Decimal.zero,
      executedBtc: Decimal.zero,
      fee: Decimal.zero,
      status: SimulatedOrderStatus.submitted,
      createdAt: now,
    );
    _activeOrder = order;
    return _fillToRatio(order, effectiveFillRatio);
  }

  PaperOrder completeActiveOrder() {
    final order = _activeOrder;
    if (order == null || !order.isOpen) {
      throw StateError('No unfinished paper order');
    }
    return _fillToRatio(order, Decimal.one);
  }

  PaperOrder _fillToRatio(PaperOrder order, Decimal targetRatio) {
    final targetQuote = order.requestedQuote * targetRatio;
    final quoteDelta = targetQuote - order.executedQuote;
    if (quoteDelta <= Decimal.zero) return order;
    Decimal btcDelta;
    Decimal actualQuote;
    if (order.side == RebalanceSide.buy) {
      final affordable = (_usdt / (Decimal.one + feeRate)).toDecimal(
        scaleOnInfinitePrecision: PortfolioManager.weightScale,
      );
      actualQuote = _min(quoteDelta, affordable);
      btcDelta = (actualQuote / order.executionPrice).toDecimal(
        scaleOnInfinitePrecision: PortfolioManager.weightScale,
      );
      final feeDelta = actualQuote * feeRate;
      _btc += btcDelta;
      _usdt -= actualQuote + feeDelta;
    } else {
      final desiredBtc = (quoteDelta / order.marketPrice).toDecimal(
        scaleOnInfinitePrecision: PortfolioManager.weightScale,
      );
      btcDelta = _min(desiredBtc, _btc);
      actualQuote = btcDelta * order.executionPrice;
      final feeDelta = actualQuote * feeRate;
      _btc -= btcDelta;
      _usdt += actualQuote - feeDelta;
    }
    final cumulativeQuote = order.executedQuote + actualQuote;
    final cumulativeBtc = order.executedBtc + btcDelta;
    final cumulativeFee = order.fee + actualQuote * feeRate;
    final filled =
        targetRatio == Decimal.one &&
        (actualQuote == quoteDelta || order.side == RebalanceSide.sell);
    final updated = order.copyWith(
      executedQuote: cumulativeQuote,
      executedBtc: cumulativeBtc,
      fee: cumulativeFee,
      status: filled
          ? SimulatedOrderStatus.filled
          : SimulatedOrderStatus.partiallyFilled,
    );
    _activeOrder = updated;
    return updated;
  }

  Decimal _min(Decimal a, Decimal b) => a < b ? a : b;
}

class PaperEvaluation {
  const PaperEvaluation({
    required this.state,
    required this.reason,
    this.decision,
    this.order,
  });
  final PaperEngineState state;
  final String reason;
  final RebalanceDecision? decision;
  final PaperOrder? order;
}

class PaperTradingEngine {
  PaperTradingEngine({
    required this.broker,
    required this.config,
    this.rebalanceEngine = const RebalanceEngine(),
  });
  final PaperBroker broker;
  final PaperTradingConfig config;
  final RebalanceEngine rebalanceEngine;
  DateTime? _lastFilledAt;

  PaperEvaluation evaluate(
    MarketState market,
    DateTime now, {
    Decimal? fillRatio,
  }) {
    if (market.websocketStatus != ConnectionStatus.connected) {
      return const PaperEvaluation(
        state: PaperEngineState.paused,
        reason: 'WEBSOCKET_DISCONNECTED',
      );
    }
    if (market.isStale(now, maximumAge: config.maximumPriceAge)) {
      return const PaperEvaluation(
        state: PaperEngineState.paused,
        reason: 'STALE_MARKET_PRICE',
      );
    }
    final existing = broker.activeOrder;
    if (existing?.isOpen == true) {
      return PaperEvaluation(
        state: existing!.status == SimulatedOrderStatus.partiallyFilled
            ? PaperEngineState.partiallyFilled
            : PaperEngineState.orderSubmitted,
        reason: 'UNFINISHED_ORDER',
        order: existing,
      );
    }
    if (_lastFilledAt != null &&
        now.difference(_lastFilledAt!) < config.cooldown) {
      return const PaperEvaluation(
        state: PaperEngineState.cooldown,
        reason: 'COOLDOWN_ACTIVE',
      );
    }
    final decision = rebalanceEngine.evaluate(
      btcQuantity: broker.btc,
      usdtQuantity: broker.usdt,
      btcPrice: market.price,
      targetBtcWeight: config.targetBtcWeight,
      triggerDeviation: config.triggerDeviation,
      repairRatio: config.repairRatio,
    );
    if (!decision.shouldTrade) {
      return PaperEvaluation(
        state: PaperEngineState.idle,
        reason: decision.reason,
        decision: decision,
      );
    }
    if (decision.quoteAmount < config.minimumOrderUsdt) {
      return PaperEvaluation(
        state: PaperEngineState.idle,
        reason: 'BELOW_MINIMUM_ORDER',
        decision: decision,
      );
    }
    final order = broker.submit(
      decision,
      market.price,
      now,
      fillRatio: fillRatio,
    );
    if (order.status == SimulatedOrderStatus.filled) {
      _lastFilledAt = now;
    }
    return PaperEvaluation(
      state: order.status == SimulatedOrderStatus.filled
          ? PaperEngineState.filled
          : PaperEngineState.partiallyFilled,
      reason: 'PAPER_ORDER_${order.status.name.toUpperCase()}',
      decision: decision,
      order: order,
    );
  }

  PaperEvaluation completeOrder(DateTime now) {
    final order = broker.completeActiveOrder();
    if (order.status == SimulatedOrderStatus.filled) {
      _lastFilledAt = now;
    }
    return PaperEvaluation(
      state: order.status == SimulatedOrderStatus.filled
          ? PaperEngineState.filled
          : PaperEngineState.partiallyFilled,
      reason: 'PAPER_ORDER_${order.status.name.toUpperCase()}',
      order: order,
    );
  }
}
