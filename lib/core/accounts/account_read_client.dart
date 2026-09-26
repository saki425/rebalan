import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import '../domain/models.dart';

abstract interface class AccountBalanceSource {
  Future<List<AccountBalance>> fetchBalances();
}

/// Optional HTTP proxy implementation retained for compatibility.
class AccountReadClient implements AccountBalanceSource {
  AccountReadClient({required this.baseUri, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final Uri baseUri;
  final http.Client _httpClient;

  @override
  Future<List<AccountBalance>> fetchBalances() async {
    final response = await _httpClient.get(
      baseUri.resolve('/v1/accounts/balances'),
    );
    if (response.statusCode != 200) {
      throw AccountReadException(
        'Balance proxy returned HTTP ${response.statusCode}',
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final rows = payload['accounts'] as List<dynamic>;
    final balances = rows
        .map((item) {
          final row = item as Map<String, dynamic>;
          final role = _parseRole(row['role'] as String);
          return AccountBalance(
            role: role,
            name: row['name'] as String? ?? _defaultName(role),
            btc: Decimal.parse(row['btc'] as String),
            usdt: Decimal.parse(row['usdt'] as String),
            totalProfitReceived: Decimal.parse(
              row['totalProfitReceived'] as String? ?? '0',
            ),
          );
        })
        .toList(growable: false);
    if (balances.map((item) => item.role).toSet().length != 3) {
      throw const AccountReadException(
        'Balance proxy must return all three unique accounts',
      );
    }
    return balances;
  }

  static AccountRole _parseRole(String value) => switch (value.toUpperCase()) {
    'FUNDING' => AccountRole.funding,
    'STRATEGY' => AccountRole.strategy,
    'PROFIT' => AccountRole.profit,
    _ => throw AccountReadException('Unknown account role: $value'),
  };

  static String _defaultName(AccountRole role) => switch (role) {
    AccountRole.funding => 'Funding Account',
    AccountRole.strategy => 'Strategy Account',
    AccountRole.profit => 'Profit Account',
  };

  void close() => _httpClient.close();
}

class AccountReadException implements Exception {
  const AccountReadException(this.message);
  final String message;
  @override
  String toString() => 'AccountReadException: $message';
}
