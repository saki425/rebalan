import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import 'binance_signer.dart';
import 'credential_store.dart';

class LiveOrderResponse {
  const LiveOrderResponse({
    required this.orderId,
    required this.clientOrderId,
    required this.status,
    required this.executedQuantity,
    required this.cumulativeQuoteQuantity,
  });
  final String orderId;
  final String clientOrderId;
  final String status;
  final Decimal executedQuantity;
  final Decimal cumulativeQuoteQuantity;
  bool get isTerminal => const {
        'FILLED',
        'CANCELED',
        'REJECTED',
        'EXPIRED',
        'EXPIRED_IN_MATCH',
      }.contains(status);

  factory LiveOrderResponse.fromJson(Map<String, dynamic> json) =>
      LiveOrderResponse(
        orderId: '${json['orderId']}',
        clientOrderId: json['clientOrderId'] as String,
        status: json['status'] as String,
        executedQuantity: Decimal.parse(json['executedQty'] as String),
        cumulativeQuoteQuantity: Decimal.parse(
          json['cummulativeQuoteQty'] as String? ??
              json['cumulativeQuoteQty'] as String? ??
              '0',
        ),
      );
}

class BinanceLiveClient {
  BinanceLiveClient({
    required this.credentials,
    http.Client? httpClient,
    this.baseUri = const String.fromEnvironment(
      'BINANCE_BASE_URL',
      defaultValue: 'https://api.binance.com',
    ),
    this.recvWindow = 5000,
    DateTime Function()? clock,
    this.signer = const BinanceSigner(),
  })  : _http = httpClient ?? http.Client(),
        _clock = clock ?? DateTime.now;

  final BinanceCredentials credentials;
  final http.Client _http;
  final String baseUri;
  final int recvWindow;
  final DateTime Function() _clock;
  final BinanceSigner signer;
  int _serverOffsetMs = 0;

  Future<void> synchronizeTime() async {
    final response = await _http.get(Uri.parse('$baseUri/api/v3/time'));
    _ensureSuccess(response);
    final serverTime = (jsonDecode(response.body)
        as Map<String, dynamic>)['serverTime'] as int;
    _serverOffsetMs = serverTime - _clock().toUtc().millisecondsSinceEpoch;
  }

  Future<Map<String, dynamic>> exchangeInfo({String symbol = 'BTCUSDT'}) async {
    final uri = Uri.parse(
      '$baseUri/api/v3/exchangeInfo',
    ).replace(queryParameters: {'symbol': symbol});
    final response = await _http.get(uri);
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> account() =>
      _signed('GET', '/api/v3/account', const {});

  Future<Map<String, dynamic>> apiRestrictions() =>
      _signed('GET', '/sapi/v1/account/apiRestrictions', const {});

  Future<List<Map<String, dynamic>>> openOrders({
    String symbol = 'BTCUSDT',
  }) async {
    final rows = await _signedList('GET', '/api/v3/openOrders', {
      'symbol': symbol,
    });
    return rows.cast<Map<String, dynamic>>();
  }

  Future<LiveOrderResponse> placeMarketOrder({
    required String symbol,
    required String side,
    required Decimal quantity,
    required String clientOrderId,
  }) async {
    final parameters = {
      'symbol': symbol,
      'side': side,
      'type': 'MARKET',
      'quantity': quantity.toString(),
      'newClientOrderId': clientOrderId,
      'newOrderRespType': 'FULL',
    };
    try {
      final json = await _signed('POST', '/api/v3/order', parameters);
      return LiveOrderResponse.fromJson(json);
    } on BinanceApiException catch (error) {
      if (error.code != -1007) rethrow;
      return queryOrder(symbol: symbol, clientOrderId: clientOrderId);
    } on http.ClientException {
      return queryOrder(symbol: symbol, clientOrderId: clientOrderId);
    }
  }

  Future<LiveOrderResponse> queryOrder({
    required String symbol,
    required String clientOrderId,
  }) async {
    try {
      final json = await _signed('GET', '/api/v3/order', {
        'symbol': symbol,
        'origClientOrderId': clientOrderId,
      });
      return LiveOrderResponse.fromJson(json);
    } catch (error) {
      throw OrderStatusUnknownException(clientOrderId, error);
    }
  }

  Future<LiveOrderResponse> queryOrderById({
    required String symbol,
    required String orderId,
  }) async {
    try {
      final json = await _signed('GET', '/api/v3/order', {
        'symbol': symbol,
        'orderId': orderId,
      });
      return LiveOrderResponse.fromJson(json);
    } catch (error) {
      throw OrderStatusUnknownException(orderId, error);
    }
  }

  /// Returns the fills for an order. Reconciliation uses this endpoint after
  /// reconnect so local trade/fee records can be repaired from Binance.
  Future<List<Map<String, dynamic>>> myTrades({
    String symbol = 'BTCUSDT',
    required String orderId,
  }) async {
    final rows = await _signedList('GET', '/api/v3/myTrades', {
      'symbol': symbol,
      'orderId': orderId,
      'limit': '1000',
    });
    return rows.cast<Map<String, dynamic>>();
  }

  Future<String> universalTransfer({
    String? fromEmail,
    String? toEmail,
    required String fromAccountType,
    required String toAccountType,
    required String asset,
    required Decimal amount,
    required String clientTransferId,
  }) async {
    final parameters = <String, String>{
      if (fromEmail != null) 'fromEmail': fromEmail,
      if (toEmail != null) 'toEmail': toEmail,
      'fromAccountType': fromAccountType,
      'toAccountType': toAccountType,
      'asset': asset,
      'amount': amount.toString(),
      'clientTranId': clientTransferId,
    };
    final json = await _signed(
      'POST',
      '/sapi/v1/sub-account/universalTransfer',
      parameters,
    );
    return '${json['tranId']}';
  }

  Future<String> transferToSibling({
    required String toEmail,
    required String asset,
    required Decimal amount,
  }) async {
    final json = await _signed(
      'POST',
      '/sapi/v1/sub-account/transfer/subToSub',
      {'toEmail': toEmail, 'asset': asset, 'amount': amount.toString()},
    );
    return '${json['txnId'] ?? json['tranId']}';
  }

  Future<List<dynamic>> _signedList(
    String method,
    String path,
    Map<String, String> input,
  ) async {
    final response = await _sendSigned(method, path, input);
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> _signed(
    String method,
    String path,
    Map<String, String> input,
  ) async {
    final response = await _sendSigned(method, path, input);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<http.Response> _sendSigned(
    String method,
    String path,
    Map<String, String> input,
  ) async {
    if (!credentials.isValid) {
      throw const BinanceApiException(null, 'Missing credentials');
    }
    final parameters = <String, String>{
      ...input,
      'recvWindow': '$recvWindow',
      'timestamp':
          '${_clock().toUtc().millisecondsSinceEpoch + _serverOffsetMs}',
    };
    final payload = signer.encodeParameters(parameters);
    final signature = signer.sign(payload, credentials.secretKey);
    final uri = Uri.parse('$baseUri$path?$payload&signature=$signature');
    final headers = {'X-MBX-APIKEY': credentials.apiKey};
    final response = switch (method) {
      'GET' => await _http.get(uri, headers: headers),
      'POST' => await _http.post(uri, headers: headers),
      _ => throw ArgumentError.value(method, 'method'),
    };
    _ensureSuccess(response);
    return response;
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    int? code;
    String message = 'HTTP ${response.statusCode}';
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      code = json['code'] as int?;
      message = json['msg'] as String? ?? message;
    } catch (_) {}
    throw BinanceApiException(code, message);
  }

  void close() => _http.close();
}

class BinanceApiException implements Exception {
  const BinanceApiException(this.code, this.message);
  final int? code;
  final String message;
  @override
  String toString() => 'BinanceApiException(code: $code, message: $message)';
}

class OrderStatusUnknownException implements Exception {
  const OrderStatusUnknownException(this.clientOrderId, this.cause);
  final String clientOrderId;
  final Object cause;
  @override
  String toString() =>
      'OrderStatusUnknownException(clientOrderId: $clientOrderId)';
}
