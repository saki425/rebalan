import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/domain/models.dart';
import 'package:rebalance/core/market/binance_market_data_service.dart';
import 'package:rebalance/core/market/market_state.dart';

void main() {
  test('REST calibration parses Decimal price and percent', () async {
    final client = MockClient((request) async {
      expect(request.url, BinanceMarketDataService.restTickerUri);
      return http.Response(
        '{"symbol":"BTCUSDT","lastPrice":"61234.12000000","priceChangePercent":"2.500"}',
        200,
      );
    });
    final service = BinanceMarketDataService(httpClient: client);
    await service.calibrate();
    expect(service.current.price, Decimal.parse('61234.12000000'));
    expect(service.current.change24h, Decimal.parse('0.025'));
    expect(service.current.apiStatus, ConnectionStatus.connected);
    expect(service.current.lastRestCalibration, isNotNull);
    await service.stop();
  });

  test('REST error marks API disconnected without changing price', () async {
    final service = BinanceMarketDataService(
      httpClient: MockClient((_) async => http.Response('rate limited', 429)),
    );
    await service.calibrate();
    expect(service.current.price, Decimal.zero);
    expect(service.current.apiStatus, ConnectionStatus.disconnected);
    await service.stop();
  });

  test('WebSocket ticker parser updates event time and remains precise', () {
    final state = BinanceMarketDataService.parseWebSocketTicker(
      MarketState.initial(),
      '{"e":"24hrTicker","E":1770000000123,"s":"BTCUSDT","c":"60001.12345678","P":"-1.250"}',
    );
    expect(state.price, Decimal.parse('60001.12345678'));
    expect(state.change24h, Decimal.parse('-0.0125'));
    expect(state.websocketStatus, ConnectionStatus.connected);
    expect(state.lastEventAt?.millisecondsSinceEpoch, 1770000000123);
  });

  test('stale market data is detected', () {
    final state = MarketState.initial().copyWith(
      lastEventAt: DateTime.utc(2026, 1, 1, 0, 0, 0),
    );
    expect(state.isStale(DateTime.utc(2026, 1, 1, 0, 0, 16)), isTrue);
    expect(state.isStale(DateTime.utc(2026, 1, 1, 0, 0, 10)), isFalse);
  });
}
