import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';

class BinanceCredentials {
  const BinanceCredentials({
    required this.apiKey,
    required this.secretKey,
    this.accountEmail = '',
  });
  final String apiKey;
  final String secretKey;
  final String accountEmail;
  bool get isValid => apiKey.trim().isNotEmpty && secretKey.trim().isNotEmpty;
}

abstract interface class CredentialStore {
  Future<void> save(AccountRole role, BinanceCredentials credentials);
  Future<BinanceCredentials?> read(AccountRole role);
  Future<void> delete(AccountRole role);
}

class SecureCredentialStore implements CredentialStore {
  const SecureCredentialStore();

  @override
  Future<void> save(AccountRole role, BinanceCredentials credentials) async {
    if (!credentials.isValid) {
      throw ArgumentError('API key and secret are required');
    }
    final storage = await SharedPreferences.getInstance();
    await storage.setString(_key(role, 'api_key'), credentials.apiKey);
    await storage.setString(_key(role, 'secret_key'), credentials.secretKey);
    await storage.setString(_key(role, 'account_email'), credentials.accountEmail);
  }

  @override
  Future<BinanceCredentials?> read(AccountRole role) async {
    final storage = await SharedPreferences.getInstance();
    final apiKey = storage.getString(_key(role, 'api_key'));
    final secret = storage.getString(_key(role, 'secret_key'));
    final email = storage.getString(_key(role, 'account_email'));
    if (apiKey == null || secret == null) return null;
    return BinanceCredentials(
      apiKey: apiKey,
      secretKey: secret,
      accountEmail: email ?? '',
    );
  }

  @override
  Future<void> delete(AccountRole role) async {
    final storage = await SharedPreferences.getInstance();
    await storage.remove(_key(role, 'api_key'));
    await storage.remove(_key(role, 'secret_key'));
    await storage.remove(_key(role, 'account_email'));
  }

  String _key(AccountRole role, String field) =>
      'rebalance.binance.${role.name}.$field';
}
