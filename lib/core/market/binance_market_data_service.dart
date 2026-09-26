import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../domain/models.dart';
import 'market_state.dart';

typedef WebSocketConnector = Future<WebSocketChannel> Function(Uri uri);

class BinanceMarketDataService {
  BinanceMarketDataService({
    http.Client? httpClient,
    WebSocketConnector? webSocketConnector,
    this.restInterval = const Duration(seconds: 60),
    this.reconnectBaseDelay = const Duration(seconds: 1),
  }) : _httpClient = httpClient ?? http.Client(),
       _webSocketConnector = webSocketConnector ?? _defaultConnector;

  static final restTickerUri = Uri.https(
    'api.binance.com',
    '/api/v3/ticker/24hr',
    {'symbol': 'BTCUSDT'},
  );
  static final websocketUri = Uri.parse(
    'wss://stream.binance.com:9443/ws/btcusdt@ticker',
  );

  final http.Client _httpClient;
  final WebSocketConnector _webSocketConnector;
  final Duration restInterval;
  final Duration reconnectBaseDelay;
  final _controller = StreamController<MarketState>.broadcast();
  MarketState _state = MarketState.initial();
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Timer? _restTimer;
  Timer? _reconnectTimer;
  bool _running = false;
  int _reconnectAttempt = 0;

  Stream<MarketState> get states => _controller.stream;
  MarketState get current => _state;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _emit(_state);
    await calibrate();
    if (!_running) return;
    await _connect();
    _restTimer = Timer.periodic(restInterval, (_) => unawaited(calibrate()));
  }

  Future<void> calibrate() async {
    try {
      final response = await _httpClient.get(restTickerUri);
      if (response.statusCode != 200) {
        throw MarketDataException(
          'REST ticker returned HTTP ${response.statusCode}',
        );
      }
      final now = DateTime.now().toUtc();
      _emit(parseRestTicker(_state, response.body, now));
    } catch (_) {
      _emit(_state.copyWith(apiStatus: ConnectionStatus.disconnected));
    }
  }

  Future<void> _connect() async {
    if (!_running) return;
    try {
      final channel = await _webSocketConnector(websocketUri);
      if (!_running) {
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _reconnectAttempt = 0;
      _emit(_state.copyWith(websocketStatus: ConnectionStatus.connected));
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (_) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _handleMessage(Object? message) {
    try {
      _emit(parseWebSocketTicker(_state, message as String));
    } catch (_) {
      // A malformed tick is ignored; the connection remains usable.
    }
  }

  static MarketState parseRestTicker(
    MarketState current,
    String body,
    DateTime calibratedAt,
  ) {
    final data = jsonDecode(body) as Map<String, dynamic>;
    if (data['symbol'] != 'BTCUSDT') {
      throw const FormatException('Unexpected REST ticker symbol');
    }
    return current.copyWith(
      price: Decimal.parse(data['lastPrice'] as String),
      change24h:
          (Decimal.parse(data['priceChangePercent'] as String) /
                  Decimal.fromInt(100))
              .toDecimal(scaleOnInfinitePrecision: 18),
      apiStatus: ConnectionStatus.connected,
      lastRestCalibration: calibratedAt,
      lastEventAt: current.lastEventAt ?? calibratedAt,
    );
  }

  static MarketState parseWebSocketTicker(MarketState current, String message) {
    final data = jsonDecode(message) as Map<String, dynamic>;
    if (data['s'] != 'BTCUSDT') {
      throw const FormatException('Unexpected WebSocket ticker symbol');
    }
    return current.copyWith(
      price: Decimal.parse(data['c'] as String),
      change24h: (Decimal.parse(data['P'] as String) / Decimal.fromInt(100))
          .toDecimal(scaleOnInfinitePrecision: 18),
      websocketStatus: ConnectionStatus.connected,
      lastEventAt: DateTime.fromMillisecondsSinceEpoch(
        data['E'] as int,
        isUtc: true,
      ),
    );
  }

  void _handleDisconnect() {
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    _emit(_state.copyWith(websocketStatus: ConnectionStatus.disconnected));
    if (!_running || _reconnectTimer?.isActive == true) return;
    final seconds = 1 << _reconnectAttempt.clamp(0, 5);
    _reconnectAttempt++;
    _reconnectTimer = Timer(
      reconnectBaseDelay * seconds,
      () => unawaited(_connect()),
    );
  }

  void _emit(MarketState state) {
    _state = state;
    if (!_controller.isClosed) _controller.add(state);
  }

  Future<void> stop() async {
    _running = false;
    _restTimer?.cancel();
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _httpClient.close();
    await _controller.close();
  }

  static Future<WebSocketChannel> _defaultConnector(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;
    return channel;
  }
}

class MarketDataException implements Exception {
  const MarketDataException(this.message);
  final String message;
  @override
  String toString() => 'MarketDataException: $message';
}
