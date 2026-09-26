import 'package:decimal/decimal.dart';

import '../domain/models.dart';

class MarketState {
  MarketState({
    required this.price,
    required this.change24h,
    required this.websocketStatus,
    required this.apiStatus,
    required this.lastEventAt,
    required this.lastRestCalibration,
  });

  factory MarketState.initial() => MarketState(
    price: Decimal.zero,
    change24h: Decimal.zero,
    websocketStatus: ConnectionStatus.unknown,
    apiStatus: ConnectionStatus.unknown,
    lastEventAt: null,
    lastRestCalibration: null,
  );

  final Decimal price;
  final Decimal change24h;
  final ConnectionStatus websocketStatus;
  final ConnectionStatus apiStatus;
  final DateTime? lastEventAt;
  final DateTime? lastRestCalibration;

  bool isStale(
    DateTime now, {
    Duration maximumAge = const Duration(seconds: 15),
  }) => lastEventAt == null || now.difference(lastEventAt!) > maximumAge;

  MarketState copyWith({
    Decimal? price,
    Decimal? change24h,
    ConnectionStatus? websocketStatus,
    ConnectionStatus? apiStatus,
    DateTime? lastEventAt,
    DateTime? lastRestCalibration,
  }) => MarketState(
    price: price ?? this.price,
    change24h: change24h ?? this.change24h,
    websocketStatus: websocketStatus ?? this.websocketStatus,
    apiStatus: apiStatus ?? this.apiStatus,
    lastEventAt: lastEventAt ?? this.lastEventAt,
    lastRestCalibration: lastRestCalibration ?? this.lastRestCalibration,
  );
}
