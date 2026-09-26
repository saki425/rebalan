import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rebalance/core/notifications/notification_service.dart';
import 'package:rebalance/core/paper/paper_trading_engine.dart';
import 'package:rebalance/core/strategy/rebalance_engine.dart';
import 'package:decimal/decimal.dart';

void main() {
  test('EmailJS sends a filled order template payload', () async {
    late Map<String, dynamic> request;
    final client = MockClient((call) async {
      request = jsonDecode(call.body) as Map<String, dynamic>;
      return http.Response('OK', 200);
    });
    final service = EmailJsNotificationService(
      publicKey: 'public',
      serviceId: 'service',
      templateId: 'template',
      httpClient: client,
    );
    final order = PaperOrder(
      clientOrderId: 'paper-1',
      idempotencyKey: 'idempotency-1',
      side: RebalanceSide.sell,
      marketPrice: Decimal.parse('60000'),
      executionPrice: Decimal.parse('59988'),
      requestedQuote: Decimal.parse('600'),
      requestedBtc: Decimal.parse('0.01'),
      executedQuote: Decimal.parse('600'),
      executedBtc: Decimal.parse('0.01'),
      fee: Decimal.parse('0.6'),
      status: SimulatedOrderStatus.filled,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await service.tradeFilled(order);
    expect(request['service_id'], 'service');
    expect((request['template_params'] as Map)['side'], 'SELL');
    expect((request['template_params'] as Map)['order_id'], 'paper-1');
  });
}
