import 'package:decimal/decimal.dart';

enum CashFlowType {
  externalDeposit,
  externalWithdrawal,
  internalTransferIn,
  internalTransferOut,
  profitWithdrawal,
}

class CashFlow {
  const CashFlow({
    required this.type,
    required this.amount,
    required this.occurredAt,
    required this.referenceId,
  });
  final CashFlowType type;
  final Decimal amount;
  final DateTime occurredAt;
  final String referenceId;
}

class PerformanceSnapshot {
  const PerformanceSnapshot({
    required this.currentEquity,
    required this.initialCapital,
    required this.externalDeposits,
    required this.externalWithdrawals,
    required this.internalTransfersIn,
    required this.internalTransfersOut,
    required this.profitWithdrawn,
    required this.netCapitalFlows,
    required this.tradingPnl,
    required this.totalFees,
    required this.grossTradingPnl,
  });
  final Decimal currentEquity;
  final Decimal initialCapital;
  final Decimal externalDeposits;
  final Decimal externalWithdrawals;
  final Decimal internalTransfersIn;
  final Decimal internalTransfersOut;
  final Decimal profitWithdrawn;
  final Decimal netCapitalFlows;
  final Decimal tradingPnl;
  final Decimal totalFees;
  final Decimal grossTradingPnl;
}

class PerformanceManager {
  PerformanceManager({required this.initialCapital});
  final Decimal initialCapital;
  final List<CashFlow> _flows = [];
  Decimal _fees = Decimal.zero;
  final Set<String> _references = {};

  List<CashFlow> get flows => List.unmodifiable(_flows);
  Decimal get totalFees => _fees;

  void recordFlow(CashFlow flow) {
    if (flow.amount < Decimal.zero) {
      throw ArgumentError.value(flow.amount, 'amount', 'cannot be negative');
    }
    if (!_references.add(flow.referenceId)) return;
    _flows.add(flow);
  }

  void recordFee(Decimal fee, {required String referenceId}) {
    if (fee < Decimal.zero) {
      throw ArgumentError.value(fee, 'fee', 'cannot be negative');
    }
    final key = 'fee:$referenceId';
    if (!_references.add(key)) return;
    _fees += fee;
  }

  PerformanceSnapshot calculate(Decimal currentEquity) {
    if (currentEquity < Decimal.zero) {
      throw ArgumentError.value(currentEquity, 'currentEquity');
    }
    Decimal sum(CashFlowType type) => _flows
        .where((flow) => flow.type == type)
        .fold(Decimal.zero, (total, flow) => total + flow.amount);
    final externalDeposits = sum(CashFlowType.externalDeposit);
    final externalWithdrawals = sum(CashFlowType.externalWithdrawal);
    final internalIn = sum(CashFlowType.internalTransferIn);
    final regularInternalOut = sum(CashFlowType.internalTransferOut);
    final profitWithdrawn = sum(CashFlowType.profitWithdrawal);
    final allOut = regularInternalOut + profitWithdrawn;
    final netFlows =
        externalDeposits + internalIn - externalWithdrawals - allOut;
    final tradingPnl = currentEquity - initialCapital - netFlows;
    return PerformanceSnapshot(
      currentEquity: currentEquity,
      initialCapital: initialCapital,
      externalDeposits: externalDeposits,
      externalWithdrawals: externalWithdrawals,
      internalTransfersIn: internalIn,
      internalTransfersOut: allOut,
      profitWithdrawn: profitWithdrawn,
      netCapitalFlows: netFlows,
      tradingPnl: tradingPnl,
      totalFees: _fees,
      grossTradingPnl: tradingPnl + _fees,
    );
  }
}
