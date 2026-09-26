import 'package:decimal/decimal.dart';

import '../domain/models.dart';

class PortfolioValuation {
  const PortfolioValuation({
    required this.btcQuantity,
    required this.btcPrice,
    required this.btcValue,
    required this.usdtQuantity,
    required this.totalEquity,
    required this.btcWeight,
    required this.usdtWeight,
  });
  final Decimal btcQuantity;
  final Decimal btcPrice;
  final Decimal btcValue;
  final Decimal usdtQuantity;
  final Decimal totalEquity;
  final Decimal btcWeight;
  final Decimal usdtWeight;
}

class PortfolioManager {
  const PortfolioManager();
  static const weightScale = 18;

  PortfolioValuation valueAccount(AccountBalance account, Decimal btcPrice) =>
      valueAmounts(
        btcQuantity: account.btc,
        usdtQuantity: account.usdt,
        btcPrice: btcPrice,
      );

  PortfolioValuation valueAccounts(
    Iterable<AccountBalance> accounts,
    Decimal btcPrice,
  ) {
    var btc = Decimal.zero;
    var usdt = Decimal.zero;
    for (final account in accounts) {
      _validateBalance(account.btc, 'BTC');
      _validateBalance(account.usdt, 'USDT');
      btc += account.btc;
      usdt += account.usdt;
    }
    return valueAmounts(
      btcQuantity: btc,
      usdtQuantity: usdt,
      btcPrice: btcPrice,
    );
  }

  PortfolioValuation valueAmounts({
    required Decimal btcQuantity,
    required Decimal usdtQuantity,
    required Decimal btcPrice,
  }) {
    if (btcPrice <= Decimal.zero) {
      throw const PortfolioCalculationException(
        'BTC price must be greater than zero',
      );
    }
    _validateBalance(btcQuantity, 'BTC');
    _validateBalance(usdtQuantity, 'USDT');
    final btcValue = btcQuantity * btcPrice;
    final equity = btcValue + usdtQuantity;
    final btcWeight = equity == Decimal.zero
        ? Decimal.zero
        : (btcValue / equity).toDecimal(scaleOnInfinitePrecision: weightScale);
    return PortfolioValuation(
      btcQuantity: btcQuantity,
      btcPrice: btcPrice,
      btcValue: btcValue,
      usdtQuantity: usdtQuantity,
      totalEquity: equity,
      btcWeight: btcWeight,
      usdtWeight: equity == Decimal.zero
          ? Decimal.zero
          : Decimal.one - btcWeight,
    );
  }

  void _validateBalance(Decimal balance, String asset) {
    if (balance < Decimal.zero) {
      throw PortfolioCalculationException('$asset balance cannot be negative');
    }
  }
}

class PortfolioCalculationException implements Exception {
  const PortfolioCalculationException(this.message);
  final String message;
  @override
  String toString() => 'PortfolioCalculationException: $message';
}
