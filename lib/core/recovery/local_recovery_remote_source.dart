import '../accounts/local_account_balance_source.dart';
import '../domain/models.dart';
import '../live/binance_live_client.dart';
import '../live/credential_store.dart';
import '../market/binance_market_data_service.dart';
import 'recovery_coordinator.dart';

class LocalRecoveryRemoteSource implements RecoveryRemoteSource {
  const LocalRecoveryRemoteSource({
    required this.credentials,
    required this.balances,
    required this.marketData,
    this.clientFactory,
  });

  final CredentialStore credentials;
  final LocalAccountBalanceSource balances;
  final BinanceMarketDataService marketData;
  final LiveClientFactory? clientFactory;

  @override
  Future<RemoteRecoverySnapshot> fetchFullState() async {
    final accounts = await balances.fetchBalances();
    final strategyCredentials = await credentials.read(AccountRole.strategy);
    if (strategyCredentials == null || !strategyCredentials.isValid) {
      throw const MissingAccountCredentials(AccountRole.strategy);
    }
    final client =
        clientFactory?.call(strategyCredentials) ??
        BinanceLiveClient(credentials: strategyCredentials);
    try {
      await client.synchronizeTime();
      final orders = await client.openOrders();
      final market = marketData.current;
      return RemoteRecoverySnapshot(
        accounts: accounts,
        openClientOrderIds: orders
            .map((row) => row['clientOrderId'] as String)
            .toSet(),
        apiStatus: market.apiStatus,
        websocketStatus: market.websocketStatus,
        priceUpdatedAt:
            market.lastEventAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    } finally {
      client.close();
    }
  }
}
