enum LiveGateFailure {
  liveDisabled,
  confirmationMissing,
  credentialsMissing,
  paperValidationIncomplete,
  ipRestrictionRequired,
  withdrawalPermissionEnabled,
  tradingPermissionMissing,
  internalTransferPermissionMissing,
}

class ApiPermissionSnapshot {
  const ApiPermissionSnapshot({
    required this.ipRestricted,
    required this.withdrawalsEnabled,
    required this.spotTradingEnabled,
    required this.internalTransferEnabled,
  });
  final bool ipRestricted;
  final bool withdrawalsEnabled;
  final bool spotTradingEnabled;
  final bool internalTransferEnabled;

  factory ApiPermissionSnapshot.fromBinance(Map<String, dynamic> json) {
    // Binance has returned both names across API/account variants. The web
    // console's "Universal Transfer" permission is exposed as
    // `permitsUniversalTransfer`, while some keys expose
    // `enableInternalTransfer`. Either one is sufficient for an internal
    // sub-account transfer; withdrawals remain independently blocked.
    final internalTransfer =
        json['enableInternalTransfer'] == true ||
        json['permitsUniversalTransfer'] == true;
    return ApiPermissionSnapshot(
      ipRestricted: json['ipRestrict'] == true,
      withdrawalsEnabled: json['enableWithdrawals'] == true,
      spotTradingEnabled: json['enableSpotAndMarginTrading'] == true,
      internalTransferEnabled: internalTransfer,
    );
  }
}

class LiveGateRequest {
  const LiveGateRequest({
    required this.liveEnabled,
    required this.confirmation,
    required this.allCredentialsPresent,
    required this.paperTradeCount,
    required this.paperErrorFreeHours,
    required this.permissions,
  });
  final bool liveEnabled;
  final String confirmation;
  final bool allCredentialsPresent;
  final int paperTradeCount;
  final int paperErrorFreeHours;
  final ApiPermissionSnapshot permissions;
}

class LiveGateResult {
  const LiveGateResult({required this.allowed, required this.failures});
  final bool allowed;
  final List<LiveGateFailure> failures;
}

class LiveTradingGate {
  const LiveTradingGate({
    this.minimumPaperTrades = 20,
    this.minimumErrorFreeHours = 24,
  });
  static const confirmationPhrase = 'ENABLE LIVE TRADING';
  final int minimumPaperTrades;
  final int minimumErrorFreeHours;

  LiveGateResult evaluate(LiveGateRequest request) {
    final failures = <LiveGateFailure>[];
    if (!request.liveEnabled) {
      failures.add(LiveGateFailure.liveDisabled);
    }
    if (request.confirmation != confirmationPhrase) {
      failures.add(LiveGateFailure.confirmationMissing);
    }
    if (!request.allCredentialsPresent) {
      failures.add(LiveGateFailure.credentialsMissing);
    }
    if (request.paperTradeCount < minimumPaperTrades ||
        request.paperErrorFreeHours < minimumErrorFreeHours) {
      failures.add(LiveGateFailure.paperValidationIncomplete);
    }
    if (!request.permissions.ipRestricted) {
      failures.add(LiveGateFailure.ipRestrictionRequired);
    }
    if (request.permissions.withdrawalsEnabled) {
      failures.add(LiveGateFailure.withdrawalPermissionEnabled);
    }
    if (!request.permissions.spotTradingEnabled) {
      failures.add(LiveGateFailure.tradingPermissionMissing);
    }
    if (!request.permissions.internalTransferEnabled) {
      failures.add(LiveGateFailure.internalTransferPermissionMissing);
    }
    return LiveGateResult(
      allowed: failures.isEmpty,
      failures: List.unmodifiable(failures),
    );
  }
}
