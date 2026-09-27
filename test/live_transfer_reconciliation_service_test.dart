import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/database/database_service.dart';
import 'package:rebalance/core/live/binance_live_client.dart';
import 'package:rebalance/core/live/credential_store.dart';
import 'package:rebalance/core/live/live_transfer_reconciliation_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('UNKNOWN transfer is resolved from Binance without reposting', () async {
    final database = await DatabaseService.open(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final ids = await database.query('accounts', columns: ['id', 'role']);
    final accountIds = {
      for (final row in ids) row['role'] as String: row['id'] as int,
    };
    await database.insert('transfers', {
      'client_transfer_id': 'transfer-timeout-1',
      'from_account_id': accountIds['STRATEGY'],
      'to_account_id': accountIds['PROFIT'],
      'asset': 'USDT',
      'amount': '25',
      'transfer_type': 'PROFIT_WITHDRAWAL',
      'status': 'UNKNOWN',
      'idempotency_key': 'transfer-timeout-1',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    var getCount = 0;
    final client = BinanceLiveClient(
      credentials: const BinanceCredentials(apiKey: 'key', secretKey: 'secret'),
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          getCount++;
          expect(
            request.url.queryParameters['clientTranId'],
            'transfer-timeout-1',
          );
          return http.Response(
            '[{"clientTranId":"transfer-timeout-1","tranId":"777","status":"SUCCESS"}]',
            200,
          );
        }
        fail('must never repost transfer');
      }),
    );
    final resolved = await LiveTransferReconciliationService(
      database: database,
      client: client,
    ).reconcileUnknownTransfers();
    expect(resolved, 1);
    final row = (await database.query('transfers')).single;
    expect(row['status'], 'SUCCESS');
    expect(row['exchange_transfer_id'], '777');
    expect(getCount, 1);
    client.close();
    await database.close();
  });
}
