import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/backtest/binance_history_service.dart';

void main() {
  test('parses Binance daily close prices without float conversion', () async {
    final service = BinanceHistoryService(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/v3/klines');
        expect(request.url.queryParameters['symbol'], 'BTCUSDT');
        expect(request.url.queryParameters['interval'], '1d');
        return http.Response(
          '[[1704067200000,"42000","43000","41000","42500.12345678","1",1704153599999,"1",1,"1","1","0"]]',
          200,
        );
      }),
    );
    final prices = await service.dailyCloses(
      start: DateTime.utc(2024),
      end: DateTime.utc(2024, 1, 3),
    );
    expect(prices.single.close.toString(), '42500.12345678');
    expect(prices.single.time, DateTime.utc(2024));
    service.close();
  });

  test('rejects inverted history range before making a request', () async {
    final service = BinanceHistoryService(
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    await expectLater(
      service.dailyCloses(
        start: DateTime.utc(2024, 2),
        end: DateTime.utc(2024, 1),
      ),
      throwsArgumentError,
    );
    service.close();
  });
}
