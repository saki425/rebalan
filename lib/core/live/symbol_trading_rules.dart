import 'package:decimal/decimal.dart';

class SymbolTradingRules {
  const SymbolTradingRules({
    required this.symbol,
    required this.minimumQuantity,
    required this.maximumQuantity,
    required this.stepSize,
    required this.minimumNotional,
  });

  final String symbol;
  final Decimal minimumQuantity;
  final Decimal maximumQuantity;
  final Decimal stepSize;
  final Decimal minimumNotional;

  factory SymbolTradingRules.fromExchangeInfo(
    Map<String, dynamic> exchangeInfo,
    String symbol,
  ) {
    final symbols =
        (exchangeInfo['symbols'] as List<dynamic>).cast<Map<String, dynamic>>();
    final row = symbols.firstWhere(
      (item) => item['symbol'] == symbol,
      orElse: () => throw SymbolRulesException('Unknown symbol: $symbol'),
    );
    final filters =
        (row['filters'] as List<dynamic>).cast<Map<String, dynamic>>();
    Map<String, dynamic>? filter(String type) {
      for (final value in filters) {
        if (value['filterType'] == type) return value;
      }
      return null;
    }

    // Some Binance symbols expose MARKET_LOT_SIZE with minQty/stepSize = 0.
    // That filter cannot be used to normalize a market quantity; fall back to
    // LOT_SIZE in that case.
    final marketLot = filter('MARKET_LOT_SIZE');
    final marketStep = _decimal(marketLot?['stepSize']);
    final lot = marketLot != null && marketStep > Decimal.zero
        ? marketLot
        : filter('LOT_SIZE');
    if (lot == null) {
      throw SymbolRulesException('$symbol has no quantity filter');
    }
    final notional = filter('NOTIONAL') ?? filter('MIN_NOTIONAL');
    return SymbolTradingRules(
      symbol: symbol,
      minimumQuantity: _decimal(lot['minQty']),
      maximumQuantity: _decimal(lot['maxQty']),
      stepSize: _decimal(lot['stepSize']),
      minimumNotional:
          notional == null ? Decimal.zero : _decimal(notional['minNotional']),
    );
  }

  Decimal normalizeQuantity(Decimal requested) {
    if (requested <= Decimal.zero || stepSize <= Decimal.zero) {
      return Decimal.zero;
    }
    final steps = (requested / stepSize).floor();
    return Decimal.parse(steps.toString()) * stepSize;
  }

  Decimal validateAndNormalize({
    required Decimal requestedQuantity,
    required Decimal referencePrice,
  }) {
    final quantity = normalizeQuantity(requestedQuantity);
    if (quantity < minimumQuantity) {
      throw SymbolRulesException(
        'Quantity $quantity is below $minimumQuantity for $symbol',
      );
    }
    if (maximumQuantity > Decimal.zero && quantity > maximumQuantity) {
      throw SymbolRulesException(
        'Quantity $quantity exceeds $maximumQuantity for $symbol',
      );
    }
    final notional = quantity * referencePrice;
    if (notional < minimumNotional) {
      throw SymbolRulesException(
        'Notional $notional is below $minimumNotional for $symbol',
      );
    }
    return quantity;
  }

  static Decimal _decimal(Object? value) =>
      Decimal.parse(value?.toString() ?? '0');
}

class SymbolRulesException implements Exception {
  const SymbolRulesException(this.message);
  final String message;

  @override
  String toString() => 'SymbolRulesException: $message';
}
