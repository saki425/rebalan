import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/accounts/account_read_client.dart';
import 'package:rebalance/core/domain/models.dart';

void main() {
  test('reads exactly three balances from secure backend proxy', () async {
    final client = AccountReadClient(
      baseUri: Uri.parse('https://backend.example'),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/accounts/balances');
        return http.Response(
          '{"accounts":['
          '{"role":"FUNDING","btc":"0.1","usdt":"100"},'
          '{"role":"STRATEGY","btc":"1.2","usdt":"50000"},'
          '{"role":"PROFIT","btc":"0","usdt":"1234.56","totalProfitReceived":"1500"}'
          ']}',
          200,
        );
      }),
    );
    final balances = await client.fetchBalances();
    expect(balances, hasLength(3));
    expect(balances.first.role, AccountRole.funding);
    expect(balances[1].btc, Decimal.parse('1.2'));
    expect(balances.last.totalProfitReceived, Decimal.parse('1500'));
    client.close();
  });

  test('rejects incomplete account response', () async {
    final client = AccountReadClient(
      baseUri: Uri.parse('https://backend.example'),
      httpClient: MockClient(
        (_) async => http.Response(
          '{"accounts":[{"role":"FUNDING","btc":"0","usdt":"1"}]}',
          200,
        ),
      ),
    );
    await expectLater(
      client.fetchBalances(),
      throwsA(isA<AccountReadException>()),
    );
    client.close();
  });
}
