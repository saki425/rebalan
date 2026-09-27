import 'package:sqflite/sqflite.dart';

import 'binance_live_client.dart';

class LiveTransferReconciliationService {
  const LiveTransferReconciliationService({
    required this.database,
    required this.client,
  });

  final Database database;
  final BinanceLiveClient client;

  Future<int> reconcileUnknownTransfers() async {
    final rows = await database.query(
      'transfers',
      where: "status = 'UNKNOWN'",
      orderBy: 'created_at ASC',
    );
    var resolved = 0;
    for (final row in rows) {
      final clientId = row['client_transfer_id'] as String;
      try {
        final history = await client.universalTransferHistory(
          clientTransferId: clientId,
        );
        final match = history.cast<Map<String, dynamic>>().firstWhere(
              (item) =>
                  '${item['clientTranId'] ?? item['clientTransferId'] ?? ''}' ==
                  clientId,
              orElse: () => <String, dynamic>{},
            );
        if (match.isEmpty) continue;
        final success = '${match['status'] ?? 'SUCCESS'}'.toUpperCase();
        final status = success == 'SUCCESS' || success == 'CONFIRMED'
            ? 'SUCCESS'
            : 'FAILED';
        await database.update(
          'transfers',
          {
            'exchange_transfer_id':
                '${match['tranId'] ?? match['txnId'] ?? ''}',
            'status': status,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        resolved++;
        print('[LIVE_TRANSFER_RECON] $clientId -> $status');
      } on BinanceApiException catch (error) {
        print('[LIVE_TRANSFER_RECON] query failed $clientId: $error');
      }
    }
    return resolved;
  }
}
