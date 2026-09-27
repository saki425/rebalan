import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/core/live/live_trading_gate.dart';

void main() {
  test('parses Binance API permission flags conservatively', () {
    final permissions = ApiPermissionSnapshot.fromBinance({
      'ipRestrict': true,
      'enableWithdrawals': false,
      'enableSpotAndMarginTrading': true,
      'enableInternalTransfer': true,
    });
    expect(permissions.ipRestricted, isTrue);
    expect(permissions.withdrawalsEnabled, isFalse);
    expect(permissions.spotTradingEnabled, isTrue);
    expect(permissions.internalTransferEnabled, isTrue);

    final missing = ApiPermissionSnapshot.fromBinance(const {});
    expect(missing.ipRestricted, isFalse);
    expect(missing.spotTradingEnabled, isFalse);
  });

  test('accepts Binance Universal Transfer permission variant', () {
    final permissions = ApiPermissionSnapshot.fromBinance({
      'ipRestrict': true,
      'enableWithdrawals': false,
      'enableSpotAndMarginTrading': true,
      'permitsUniversalTransfer': true,
    });
    expect(permissions.internalTransferEnabled, isTrue);
  });

  const safePermissions = ApiPermissionSnapshot(
    ipRestricted: true,
    withdrawalsEnabled: false,
    spotTradingEnabled: true,
    internalTransferEnabled: true,
  );

  test('LIVE remains disabled unless every safety requirement passes', () {
    const gate = LiveTradingGate();
    final result = gate.evaluate(
      const LiveGateRequest(
        liveEnabled: false,
        confirmation: '',
        allCredentialsPresent: false,
        paperTradeCount: 0,
        paperErrorFreeHours: 0,
        permissions: ApiPermissionSnapshot(
          ipRestricted: false,
          withdrawalsEnabled: true,
          spotTradingEnabled: false,
          internalTransferEnabled: false,
        ),
      ),
    );
    expect(result.allowed, isFalse);
    expect(result.failures, containsAll(LiveGateFailure.values));
  });

  test(
    'explicit confirmation, paper evidence and restricted key unlock LIVE',
    () {
      const gate = LiveTradingGate();
      final result = gate.evaluate(
        const LiveGateRequest(
          liveEnabled: true,
          confirmation: LiveTradingGate.confirmationPhrase,
          allCredentialsPresent: true,
          paperTradeCount: 20,
          paperErrorFreeHours: 24,
          permissions: safePermissions,
        ),
      );
      expect(result.allowed, isTrue);
      expect(result.failures, isEmpty);
    },
  );
}
