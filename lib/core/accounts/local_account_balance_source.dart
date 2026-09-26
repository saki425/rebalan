import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import '../live/binance_live_client.dart';
import '../live/credential_store.dart';
import 'account_read_client.dart';

typedef LiveClientFactory =
    BinanceLiveClient Function(BinanceCredentials credentials);

class LocalAccountBalanceSource implements AccountBalanceSource {
  LocalAccountBalanceSource({
    required this.credentials,
    LiveClientFactory? clientFactory,
  }) : _clientFactory =
           clientFactory ?? ((value) => BinanceLiveClient(credentials: value));
  final CredentialStore credentials;
  final LiveClientFactory _clientFactory;

  @override
  Future<List<AccountBalance>> fetchBalances() async {
    final results = <AccountBalance>[];
    for (final role in AccountRole.values) {
      final keys = await credentials.read(role);
      if (keys == null || !keys.isValid) throw MissingAccountCredentials(role);
      final client = _clientFactory(keys);
      try {
        await client.synchronizeTime();
        final data = await client.account();
        final rows = (data['balances'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        Decimal balance(String asset) {
          final matches = rows.where((row) => row['asset'] == asset);
          if (matches.isEmpty) return Decimal.zero;
          final row = matches.first;
          return Decimal.parse(row['free'] as String) +
              Decimal.parse(row['locked'] as String);
        }

        results.add(
          AccountBalance(
            role: role,
            name: _name(role),
            btc: balance('BTC'),
            usdt: balance('USDT'),
          ),
        );
      } finally {
        client.close();
      }
    }
    return results;
  }

  String _name(AccountRole role) => switch (role) {
    AccountRole.funding => 'Funding Account',
    AccountRole.strategy => 'Strategy Account',
    AccountRole.profit => 'Profit Account',
  };
}

class MissingAccountCredentials implements Exception {
  const MissingAccountCredentials(this.role);
  final AccountRole role;
  @override
  String toString() => 'MissingAccountCredentials(${role.name})';
}
