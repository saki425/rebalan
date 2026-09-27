import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/database/database_service.dart';
import 'package:rebalance/core/live/binance_live_client.dart';
import 'package:rebalance/core/live/credential_store.dart';
import 'package:rebalance/core/live/live_reconciliation_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'restart recovery resolves a local unfinished order and its fills',
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
      await database.insert('orders', {
        'client_order_id': 'restart-1',
        'exchange_order_id': null,
        'account_id': strategyId,
        'symbol': 'BTCUSDT',
        'side': 'BUY',
        'order_type': 'MARKET',
        'status': 'PARTIALLY_FILLED',
        'requested_quantity': '0.02',
        'executed_quantity': '0.01',
        'quote_quantity': '600',
        'reason': 'TEST',
        'idempotency_key': 'restart-key',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      final client = BinanceLiveClient(
        credentials: const BinanceCredentials(
          apiKey: 'key',
          secretKey: 'secret',
        ),
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/v3/openOrders')
            return http.Response('[]', 200);
          if (request.url.path == '/api/v3/order') {
            return http.Response(
              '{"orderId":101,"clientOrderId":"restart-1","status":"FILLED","executedQty":"0.02","cummulativeQuoteQty":"1200"}',
              200,
            );
          }
          if (request.url.path == '/api/v3/myTrades') {
            return http.Response(
              '[{"id":501,"price":"60000","qty":"0.01","quoteQty":"600","commission":"0.6","commissionAsset":"USDT","time":1770000000000}]',
              200,
            );
          }
          fail('unexpected ${request.url}');
        }),
      );
      final result = await LiveReconciliationService(
        database: database,
        client: client,
      ).reconcile();
      expect(result.ok, isTrue);
      expect((await database.query('orders')).single['status'], 'FILLED');
      expect(await database.query('trades'), hasLength(1));
      client.close();
      await database.close();
    },
  );

  test('remote/local open order mismatch blocks reconciliation', () async {
    final database = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final client = BinanceLiveClient(
      credentials: const BinanceCredentials(apiKey: 'key', secretKey: 'secret'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v3/openOrders') {
          return http.Response('[{"clientOrderId":"unknown-remote"}]', 200);
        }
        fail('unexpected ${request.url}');
      }),
    );
    final result = await LiveReconciliationService(
      database: database,
      client: client,
    ).reconcile();
    expect(result.ok, isFalse);
    expect(result.reason, 'LOCAL_BINANCE_ORDER_MISMATCH');
    client.close();
    await database.close();
  });
}
