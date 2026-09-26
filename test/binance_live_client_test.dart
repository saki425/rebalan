import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/live/binance_live_client.dart';
import 'package:rebalance/core/live/binance_signer.dart';
import 'package:rebalance/core/live/credential_store.dart';

void main() {
  test('HMAC signature matches Binance official example', () {
    const payload =
        'symbol=LTCBTC&side=BUY&type=LIMIT&timeInForce=GTC&quantity=1&price=0.1&recvWindow=5000&timestamp=1499827319559';
    const secret =
        'NhqPtmdSJYdKjVHjA7PZj4Mge3R5YNiP1e3UZjInClVN65XAbvqqM6A7H5fATj0j';
    expect(
      const BinanceSigner().sign(payload, secret),
      'c8db56825ae71d6d79447849e617115f4a920fa2acdcab2b053c4b2838bd6b71',
    );
  });

  test(
    '-1007 unknown execution queries client order id and never reposts',
    () async {
      var postCount = 0;
      var queryCount = 0;
      final client = MockClient((request) async {
        expect(request.headers['x-mbx-apikey'], 'test-key');
        expect(request.url.queryParameters['signature'], isNotEmpty);
        if (request.method == 'POST') {
          postCount++;
          return http.Response(
            '{"code":-1007,"msg":"Timeout waiting for response from backend server."}',
            504,
          );
        }
        queryCount++;
        expect(
          request.url.queryParameters['origClientOrderId'],
          'rebalance-123',
        );
        return http.Response(
          '{"symbol":"BTCUSDT","orderId":42,"clientOrderId":"rebalance-123","status":"FILLED","executedQty":"0.01","cummulativeQuoteQty":"600.00"}',
          200,
        );
      });
      final api = BinanceLiveClient(
        credentials: const BinanceCredentials(
          apiKey: 'test-key',
          secretKey: 'test-secret',
        ),
        httpClient: client,
        clock: () =>
            DateTime.fromMillisecondsSinceEpoch(1770000000000, isUtc: true),
      );
      final order = await api.placeMarketOrder(
        symbol: 'BTCUSDT',
        side: 'BUY',
        quantity: Decimal.parse('0.01'),
        clientOrderId: 'rebalance-123',
      );
      expect(order.status, 'FILLED');
      expect(postCount, 1);
      expect(queryCount, 1);
      api.close();
    },
  );

  test(
    'failed confirmation leaves order status unknown instead of retrying',
    () async {
      var calls = 0;
      final api = BinanceLiveClient(
        credentials: const BinanceCredentials(
          apiKey: 'key',
          secretKey: 'secret',
        ),
        httpClient: MockClient((request) async {
          calls++;
          if (request.method == 'POST') {
            return http.Response('{"code":-1007,"msg":"timeout"}', 504);
          }
          return http.Response(
            '{"code":-2013,"msg":"Order does not exist."}',
            400,
          );
        }),
      );
      await expectLater(
        api.placeMarketOrder(
          symbol: 'BTCUSDT',
          side: 'SELL',
          quantity: Decimal.parse('0.01'),
          clientOrderId: 'unknown-1',
        ),
        throwsA(isA<OrderStatusUnknownException>()),
      );
      expect(calls, 2);
      api.close();
    },
  );

  test('universal transfer includes caller idempotency id', () async {
    final api = BinanceLiveClient(
      credentials: const BinanceCredentials(apiKey: 'key', secretKey: 'secret'),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/sapi/v1/sub-account/universalTransfer');
        expect(
          request.url.queryParameters['clientTranId'],
          'profit-transfer-123',
        );
        expect(request.url.queryParameters['asset'], 'USDT');
        return http.Response('{"tranId":123456}', 200);
      }),
    );
    expect(
      await api.universalTransfer(
        fromEmail: 'strategy@example.com',
        toEmail: 'profit@example.com',
        fromAccountType: 'SPOT',
        toAccountType: 'SPOT',
        asset: 'USDT',
        amount: Decimal.parse('100'),
        clientTransferId: 'profit-transfer-123',
      ),
      '123456',
    );
    api.close();
  });
}
