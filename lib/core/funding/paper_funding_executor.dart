import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import '../portfolio/portfolio_manager.dart';
import 'funding_manager.dart';

enum FundingExecutionState {
  calculating,
  orderSubmitted,
  orderFilled,
  transferring,
  completed,
  failed,
}

class PaperFundingOrder {
  const PaperFundingOrder({
    required this.orderId,
    required this.price,
    required this.btcQuantity,
    required this.quoteAmount,
    required this.feeUsdt,
    required this.status,
  });
  final String orderId;
  final Decimal price;
  final Decimal btcQuantity;
  final Decimal quoteAmount;
  final Decimal feeUsdt;
  final String status;
}

class PaperTransferRecord {
  const PaperTransferRecord({
    required this.transferId,
    required this.asset,
    required this.amount,
    required this.fromBefore,
    required this.fromAfter,
    required this.toBefore,
    required this.toAfter,
    required this.status,
  });
  final String transferId;
  final String asset;
  final Decimal amount;
  final Decimal fromBefore;
  final Decimal fromAfter;
  final Decimal toBefore;
  final Decimal toAfter;
  final String status;
}

class PaperFundingResult {
  const PaperFundingResult({
    required this.idempotencyKey,
    required this.state,
    required this.plan,
    required this.fundingAfter,
    required this.strategyAfter,
    required this.transfers,
    this.order,
  });
  final String idempotencyKey;
  final FundingExecutionState state;
  final FundingPlan plan;
  final AccountBalance fundingAfter;
  final AccountBalance strategyAfter;
  final PaperFundingOrder? order;
  final List<PaperTransferRecord> transfers;
}

class PaperFundingExecutor {
  PaperFundingExecutor({
    required AccountBalance fundingAccount,
    required AccountBalance strategyAccount,
    required this.feeRate,
    required this.slippageRate,
    this.fundingManager = const FundingManager(),
  }) : _funding = fundingAccount,
       _strategy = strategyAccount {
    if (fundingAccount.role != AccountRole.funding ||
        strategyAccount.role != AccountRole.strategy) {
      throw ArgumentError(
        'PaperFundingExecutor requires funding and strategy accounts',
      );
    }
  }

  final Decimal feeRate;
  final Decimal slippageRate;
  final FundingManager fundingManager;
  AccountBalance _funding;
  AccountBalance _strategy;
  int _orderSequence = 0;
  int _transferSequence = 0;
  final Map<String, PaperFundingResult> _completed = {};

  AccountBalance get fundingAccount => _funding;
  AccountBalance get strategyAccount => _strategy;

  PaperFundingResult execute({
    required String idempotencyKey,
    required Decimal depositUsdt,
    required Decimal btcPrice,
    required Decimal targetBtcWeight,
  }) {
    if (idempotencyKey.trim().isEmpty) {
      throw ArgumentError.value(
        idempotencyKey,
        'idempotencyKey',
        'cannot be empty',
      );
    }
    final previous = _completed[idempotencyKey];
    if (previous != null) return previous;
    if (_funding.usdt < depositUsdt) {
      throw const FundingExecutionException(
        'Insufficient Funding Account USDT',
      );
    }

    final plan = fundingManager.calculate(
      strategyAccount: _strategy,
      depositUsdt: depositUsdt,
      btcPrice: btcPrice,
      targetBtcWeight: targetBtcWeight,
    );
    PaperFundingOrder? order;
    var purchasedBtc = Decimal.zero;
    var fee = Decimal.zero;
    if (plan.requiresBtcPurchase) {
      final executionPrice = btcPrice * (Decimal.one + slippageRate);
      purchasedBtc = (plan.buyBtcValue / executionPrice).toDecimal(
        scaleOnInfinitePrecision: PortfolioManager.weightScale,
      );
      fee = plan.buyBtcValue * feeRate;
      if (plan.buyBtcValue + fee > depositUsdt) {
        final affordableQuote = (depositUsdt / (Decimal.one + feeRate))
            .toDecimal(scaleOnInfinitePrecision: PortfolioManager.weightScale);
        purchasedBtc = (affordableQuote / executionPrice).toDecimal(
          scaleOnInfinitePrecision: PortfolioManager.weightScale,
        );
        fee = affordableQuote * feeRate;
        order = PaperFundingOrder(
          orderId: 'paper-funding-order-${++_orderSequence}',
          price: executionPrice,
          btcQuantity: purchasedBtc,
          quoteAmount: affordableQuote,
          feeUsdt: fee,
          status: 'FILLED',
        );
      } else {
        order = PaperFundingOrder(
          orderId: 'paper-funding-order-${++_orderSequence}',
          price: executionPrice,
          btcQuantity: purchasedBtc,
          quoteAmount: plan.buyBtcValue,
          feeUsdt: fee,
          status: 'FILLED',
        );
      }
    }

    final spent = order?.quoteAmount ?? Decimal.zero;
    final transferUsdt = depositUsdt - spent - fee;
    final fundingBtcAfterBuy = _funding.btc + purchasedBtc;
    final fundingUsdtAfterBuy = _funding.usdt - spent - fee;
    final transfers = <PaperTransferRecord>[];
    if (purchasedBtc > Decimal.zero) {
      transfers.add(
        PaperTransferRecord(
          transferId: 'paper-transfer-${++_transferSequence}',
          asset: 'BTC',
          amount: purchasedBtc,
          fromBefore: fundingBtcAfterBuy,
          fromAfter: fundingBtcAfterBuy - purchasedBtc,
          toBefore: _strategy.btc,
          toAfter: _strategy.btc + purchasedBtc,
          status: 'SUCCESS',
        ),
      );
    }
    if (transferUsdt > Decimal.zero) {
      transfers.add(
        PaperTransferRecord(
          transferId: 'paper-transfer-${++_transferSequence}',
          asset: 'USDT',
          amount: transferUsdt,
          fromBefore: fundingUsdtAfterBuy,
          fromAfter: fundingUsdtAfterBuy - transferUsdt,
          toBefore: _strategy.usdt,
          toAfter: _strategy.usdt + transferUsdt,
          status: 'SUCCESS',
        ),
      );
    }
    _funding = AccountBalance(
      role: AccountRole.funding,
      name: _funding.name,
      btc: _funding.btc,
      usdt: fundingUsdtAfterBuy - transferUsdt,
      totalProfitReceived: _funding.totalProfitReceived,
    );
    _strategy = AccountBalance(
      role: AccountRole.strategy,
      name: _strategy.name,
      btc: _strategy.btc + purchasedBtc,
      usdt: _strategy.usdt + transferUsdt,
      totalProfitReceived: _strategy.totalProfitReceived,
    );
    final result = PaperFundingResult(
      idempotencyKey: idempotencyKey,
      state: FundingExecutionState.completed,
      plan: plan,
      fundingAfter: _funding,
      strategyAfter: _strategy,
      order: order,
      transfers: List.unmodifiable(transfers),
    );
    _completed[idempotencyKey] = result;
    return result;
  }
}

class FundingExecutionException implements Exception {
  const FundingExecutionException(this.message);
  final String message;
  @override
  String toString() => 'FundingExecutionException: $message';
}
