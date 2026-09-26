import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/database/database_service.dart';
import 'package:rebalance/core/live/binance_live_client.dart';
import 'package:rebalance/core/live/credential_store.dart';
import 'package:rebalance/core/live/live_execution_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'persists normalized order and rejects duplicate idempotency key',
    () async {
      final database = await DatabaseService.open(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      final strategyId =
          (await database.query(
                'accounts',
                columns: ['id'],
                where: 'role = ?',
                whereArgs: ['STRATEGY'],
              )).single['id']
              as int;
      var postCount = 0;
      final client = BinanceLiveClient(
        credentials: const BinanceCredentials(
          apiKey: 'key',
          secretKey: 'secret',
        ),
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/v3/exchangeInfo') {
            return http.Response(_exchangeInfo, 200);
          }
          postCount++;
          expect(request.url.queryParameters['quantity'], '0.0123');
          return http.Response(
            '{"orderId":7,"clientOrderId":"live-1","status":"FILLED","executedQty":"0.0123","cummulativeQuoteQty":"738"}',
            200,
          );
        }),
      );
      final service = LiveExecutionService(database: database, client: client);
      final response = await service.marketOrder(
        accountId: strategyId,
        side: 'SELL',
        requestedQuantity: Decimal.parse('0.012345'),
        referencePrice: Decimal.parse('60000'),
        clientOrderId: 'live-1',
        idempotencyKey: 'rebalance-1',
        reason: 'UPPER_TRIGGER',
      );
      expect(response.status, 'FILLED');
      final row = (await database.query('orders')).single;
      expect(row['requested_quantity'], '0.0123');
      expect(row['status'], 'FILLED');
      await expectLater(
        service.marketOrder(
          accountId: strategyId,
          side: 'SELL',
          requestedQuantity: Decimal.parse('0.012345'),
          referencePrice: Decimal.parse('60000'),
          clientOrderId: 'live-2',
          idempotencyKey: 'rebalance-1',
          reason: 'UPPER_TRIGGER',
        ),
        throwsA(isA<DuplicateLiveExecutionException>()),
      );
      expect(postCount, 1);
      client.close();
      await database.close();
    },
  );
}

const _exchangeInfo =
    '{"symbols":[{"symbol":"BTCUSDT","filters":[{"filterType":"MARKET_LOT_SIZE","minQty":"0.0001","maxQty":"100","stepSize":"0.0001"},{"filterType":"MIN_NOTIONAL","minNotional":"5"}]}]}';
