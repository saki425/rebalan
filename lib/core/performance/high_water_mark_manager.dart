import 'package:decimal/decimal.dart';

class HighWaterMarkAssessment {
  const HighWaterMarkAssessment({
    required this.currentEquity,
    required this.highWaterMark,
    required this.newProfit,
  });
  final Decimal currentEquity;
  final Decimal highWaterMark;
  final Decimal newProfit;
  bool get hasNewProfit => newProfit > Decimal.zero;
}

class HighWaterMarkRecord {
  const HighWaterMarkRecord({
    required this.value,
    required this.reason,
    required this.effectiveAt,
  });
  final Decimal value;
  final String reason;
  final DateTime effectiveAt;
}

class HighWaterMarkManager {
  HighWaterMarkManager({required Decimal initialHighWaterMark})
    : _value = initialHighWaterMark {
    if (initialHighWaterMark < Decimal.zero) {
      throw ArgumentError.value(initialHighWaterMark, 'initialHighWaterMark');
    }
  }

  Decimal _value;
  final List<HighWaterMarkRecord> _history = [];
  Decimal get value => _value;
  List<HighWaterMarkRecord> get history => List.unmodifiable(_history);

  HighWaterMarkAssessment assess(Decimal currentAdjustedEquity) {
    if (currentAdjustedEquity < Decimal.zero) {
      throw ArgumentError.value(currentAdjustedEquity, 'currentAdjustedEquity');
    }
    final difference = currentAdjustedEquity - _value;
    return HighWaterMarkAssessment(
      currentEquity: currentAdjustedEquity,
      highWaterMark: _value,
      newProfit: difference > Decimal.zero ? difference : Decimal.zero,
    );
  }

  void applyCapitalFlow({
    required Decimal signedAmount,
    required String reason,
    required DateTime at,
  }) {
    final next = _value + signedAmount;
    if (next < Decimal.zero) {
      throw StateError('Capital flow would make High Water Mark negative');
    }
    _set(next, reason, at);
  }

  void crystallize({
    required Decimal equityBeforeWithdrawal,
    required Decimal profitWithdrawal,
    required DateTime at,
  }) {
    if (profitWithdrawal < Decimal.zero ||
        profitWithdrawal > equityBeforeWithdrawal) {
      throw ArgumentError.value(profitWithdrawal, 'profitWithdrawal');
    }
    _set(equityBeforeWithdrawal - profitWithdrawal, 'PROFIT_CRYSTALLIZED', at);
  }

  void commitObservedHigh(Decimal currentEquity, DateTime at) {
    if (currentEquity > _value) _set(currentEquity, 'NEW_HIGH_COMMITTED', at);
  }

  void _set(Decimal value, String reason, DateTime at) {
    _value = value;
    _history.add(
      HighWaterMarkRecord(value: value, reason: reason, effectiveAt: at),
    );
  }
}
