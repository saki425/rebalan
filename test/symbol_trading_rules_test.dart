import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/live/symbol_trading_rules.dart';

void main() {
  final exchangeInfo = <String, dynamic>{
    'symbols': [
      {
        'symbol': 'BTCUSDT',
        'filters': [
          {
            'filterType': 'LOT_SIZE',
            'minQty': '0.00001000',
            'maxQty': '9000.00000000',
            'stepSize': '0.00001000',
          },
          {
            'filterType': 'MARKET_LOT_SIZE',
            'minQty': '0.00010000',
            'maxQty': '100.00000000',
            'stepSize': '0.00010000',
          },
          {'filterType': 'NOTIONAL', 'minNotional': '5.00000000'},
        ],
      },
    ],
  };

  test('market quantity is rounded down using Decimal step size', () {
    final rules = SymbolTradingRules.fromExchangeInfo(exchangeInfo, 'BTCUSDT');
    expect(
      rules.normalizeQuantity(Decimal.parse('0.01234567')),
      Decimal.parse('0.01230000'),
    );
  });

  test('rejects quantity below minimum notional after rounding', () {
    final rules = SymbolTradingRules.fromExchangeInfo(exchangeInfo, 'BTCUSDT');
    expect(
      () => rules.validateAndNormalize(
        requestedQuantity: Decimal.parse('0.0001'),
        referencePrice: Decimal.parse('40000'),
      ),
      throwsA(isA<SymbolRulesException>()),
    );
  });

  test('returns safe normalized quantity when all filters pass', () {
    final rules = SymbolTradingRules.fromExchangeInfo(exchangeInfo, 'BTCUSDT');
    expect(
      rules.validateAndNormalize(
        requestedQuantity: Decimal.parse('0.00019999'),
        referencePrice: Decimal.parse('60000'),
      ),
      Decimal.parse('0.00010000'),
    );
  });
}
