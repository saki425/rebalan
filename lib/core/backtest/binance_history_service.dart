import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import 'backtest_engine.dart';

class BinanceHistoryService {
  BinanceHistoryService({
    http.Client? httpClient,
    this.baseUri = 'https://api.binance.com',
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String baseUri;

  Future<List<HistoricalPrice>> dailyCloses({
    required DateTime start,
    required DateTime end,
    String symbol = 'BTCUSDT',
  }) async {
    if (!end.isAfter(start)) {
      throw ArgumentError('End time must be after start time');
    }
    final result = <HistoricalPrice>[];
    var cursor = start.toUtc().millisecondsSinceEpoch;
    final endMs = end.toUtc().millisecondsSinceEpoch;
    while (cursor < endMs) {
      final uri = Uri.parse('$baseUri/api/v3/klines').replace(
        queryParameters: {
          'symbol': symbol,
          'interval': '1d',
          'startTime': '$cursor',
          'endTime': '$endMs',
          'limit': '1000',
        },
      );
      final response = await _http.get(uri);
      if (response.statusCode != 200) {
        throw HistoryServiceException('HTTP ${response.statusCode}');
      }
      final rows = jsonDecode(response.body) as List<dynamic>;
      if (rows.isEmpty) break;
      for (final value in rows) {
        final row = value as List<dynamic>;
        result.add(
          HistoricalPrice(
            time: DateTime.fromMillisecondsSinceEpoch(
              row[0] as int,
              isUtc: true,
            ),
            close: Decimal.parse(row[4] as String),
          ),
        );
      }
      final lastOpen = (rows.last as List<dynamic>)[0] as int;
      final next = lastOpen + const Duration(days: 1).inMilliseconds;
      if (next <= cursor) break;
      cursor = next;
      if (rows.length < 1000) break;
    }
    return result;
  }

  void close() => _http.close();
}

class HistoryServiceException implements Exception {
  const HistoryServiceException(this.message);
  final String message;

  @override
  String toString() => 'HistoryServiceException: $message';
}
