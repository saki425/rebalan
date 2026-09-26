import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import '../performance/high_water_mark_manager.dart';
import '../performance/performance_manager.dart';
import 'profit_manager.dart';

class PaperProfitTransfer {
  const PaperProfitTransfer({
    required this.transferId,
    required this.idempotencyKey,
    required this.amount,
    required this.strategyBefore,
    required this.strategyAfter,
    required this.profitBefore,
    required this.profitAfter,
    required this.decision,
    required this.status,
  });
  final String transferId;
  final String idempotencyKey;
  final Decimal amount;
  final Decimal strategyBefore;
  final Decimal strategyAfter;
  final Decimal profitBefore;
  final Decimal profitAfter;
  final ProfitWithdrawalDecision decision;
  final String status;
}

class PaperProfitExecutor {
  PaperProfitExecutor({
    required AccountBalance strategyAccount,
    required AccountBalance profitAccount,
    required this.highWaterMark,
    required this.performance,
    this.profitManager = const ProfitManager(),
  }) : _strategy = strategyAccount,
       _profit = profitAccount {
    if (strategyAccount.role != AccountRole.strategy ||
        profitAccount.role != AccountRole.profit) {
      throw ArgumentError('Strategy and profit account roles are required');
    }
  }

  final ProfitManager profitManager;
  final HighWaterMarkManager highWaterMark;
  final PerformanceManager performance;
  AccountBalance _strategy;
  AccountBalance _profit;
  int _sequence = 0;
  final Map<String, PaperProfitTransfer?> _results = {};

  AccountBalance get strategyAccount => _strategy;
  AccountBalance get profitAccount => _profit;

  PaperProfitTransfer? execute({
    required String idempotencyKey,
    required ProfitWithdrawalRequest request,
    required DateTime at,
  }) {
    if (_results.containsKey(idempotencyKey)) return _results[idempotencyKey];
    if (request.strategyBtc != _strategy.btc ||
        request.strategyUsdt != _strategy.usdt) {
      throw const ProfitExecutionException(
        'Request balances do not match executor balances',
      );
    }
    final decision = profitManager.evaluate(request, highWaterMark);
    if (!decision.shouldTransfer) {
      _results[idempotencyKey] = null;
      return null;
    }
    final amount = decision.transferAmount;
    final strategyBefore = _strategy.usdt;
    final profitBefore = _profit.usdt;
    _strategy = AccountBalance(
      role: AccountRole.strategy,
      name: _strategy.name,
      btc: _strategy.btc,
      usdt: _strategy.usdt - amount,
      totalProfitReceived: _strategy.totalProfitReceived,
    );
    _profit = AccountBalance(
      role: AccountRole.profit,
      name: _profit.name,
      btc: _profit.btc,
      usdt: _profit.usdt + amount,
      totalProfitReceived: _profit.totalProfitReceived + amount,
    );
    final transfer = PaperProfitTransfer(
      transferId: 'paper-profit-${++_sequence}',
      idempotencyKey: idempotencyKey,
      amount: amount,
      strategyBefore: strategyBefore,
      strategyAfter: _strategy.usdt,
      profitBefore: profitBefore,
      profitAfter: _profit.usdt,
      decision: decision,
      status: 'SUCCESS',
    );
    performance.recordFlow(
      CashFlow(
        type: CashFlowType.profitWithdrawal,
        amount: amount,
        occurredAt: at,
        referenceId: transfer.transferId,
      ),
    );
    highWaterMark.crystallize(
      equityBeforeWithdrawal: decision.currentEquity,
      profitWithdrawal: amount,
      at: at,
    );
    _results[idempotencyKey] = transfer;
    return transfer;
  }
}

class ProfitExecutionException implements Exception {
  const ProfitExecutionException(this.message);
  final String message;
  @override
  String toString() => 'ProfitExecutionException: $message';
}
