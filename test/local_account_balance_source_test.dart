import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/accounts/local_account_balance_source.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/live/binance_live_client.dart';
import 'package:rebalance/core/live/credential_store.dart';

void main() {
  test(
    'reads free and locked BTC/USDT directly for all three accounts',
    () async {
      final store = _MemoryCredentials();
      for (final role in AccountRole.values) {
        await store.save(
          role,
          BinanceCredentials(apiKey: role.name, secretKey: 'secret'),
        );
      }
      final source = LocalAccountBalanceSource(
        credentials: store,
        clientFactory: (credentials) => BinanceLiveClient(
          credentials: credentials,
          httpClient: MockClient((request) async {
            if (request.url.path == '/api/v3/time') {
              return http.Response('{"serverTime":1700000000000}', 200);
            }
            expect(request.headers['x-mbx-apikey'], credentials.apiKey);
            return http.Response(
              '{"balances":[{"asset":"BTC","free":"1.2","locked":"0.3"},{"asset":"USDT","free":"40","locked":"2"}]}',
              200,
            );
          }),
          clock: () =>
              DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
        ),
      );
      final balances = await source.fetchBalances();
      expect(balances.length, 3);
      expect(balances.every((item) => item.btc.toString() == '1.5'), isTrue);
      expect(balances.every((item) => item.usdt.toString() == '42'), isTrue);
    },
  );

  test('missing any role blocks partial dashboard balance', () async {
    final source = LocalAccountBalanceSource(credentials: _MemoryCredentials());
    await expectLater(
      source.fetchBalances(),
      throwsA(isA<MissingAccountCredentials>()),
    );
  });
}

class _MemoryCredentials implements CredentialStore {
  final values = <AccountRole, BinanceCredentials>{};

  @override
  Future<void> delete(AccountRole role) async => values.remove(role);

  @override
  Future<BinanceCredentials?> read(AccountRole role) async => values[role];

  @override
  Future<void> save(AccountRole role, BinanceCredentials credentials) async =>
      values[role] = credentials;
}
