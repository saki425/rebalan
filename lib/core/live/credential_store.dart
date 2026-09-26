import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  const SecureCredentialStore({this._storage = const FlutterSecureStorage()});
  final FlutterSecureStorage _storage;

  @override
  Future<void> save(AccountRole role, BinanceCredentials credentials) async {
    if (!credentials.isValid) {
      throw ArgumentError('API key and secret are required');
    }
    await _storage.write(key: _key(role, 'api_key'), value: credentials.apiKey);
    await _storage.write(
      key: _key(role, 'secret_key'),
      value: credentials.secretKey,
    );
    await _storage.write(
      key: _key(role, 'account_email'),
      value: credentials.accountEmail,
    );
  }

  @override
  Future<BinanceCredentials?> read(AccountRole role) async {
    final apiKey = await _storage.read(key: _key(role, 'api_key'));
    final secret = await _storage.read(key: _key(role, 'secret_key'));
    final email = await _storage.read(key: _key(role, 'account_email'));
    if (apiKey == null || secret == null) return null;
    return BinanceCredentials(
      apiKey: apiKey,
      secretKey: secret,
      accountEmail: email ?? '',
    );
  }

  @override
  Future<void> delete(AccountRole role) async {
    await _storage.delete(key: _key(role, 'api_key'));
    await _storage.delete(key: _key(role, 'secret_key'));
    await _storage.delete(key: _key(role, 'account_email'));
  }

  String _key(AccountRole role, String field) =>
      'rebalance.binance.${role.name}.$field';
}
