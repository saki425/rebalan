import 'dart:convert';

import 'package:http/http.dart' as http;

import '../paper/paper_trading_engine.dart';

/// Notification abstraction. Strategy code depends on this interface so the
/// transport can later be replaced with Telegram, SMTP, or a local notifier.
abstract interface class NotificationService {
  Future<void> tradeFilled(PaperOrder order);
}

class EmailJsNotificationService implements NotificationService {
  EmailJsNotificationService({
    required this.publicKey,
    required this.serviceId,
    required this.templateId,
    this.httpClient,
    this.endpoint = 'https://api.emailjs.com/api/v1.0/email/send',
  });

  final String publicKey;
  final String serviceId;
  final String templateId;
  final http.Client? httpClient;
  final String endpoint;

  bool get isConfigured =>
      publicKey.isNotEmpty && serviceId.isNotEmpty && templateId.isNotEmpty;

  @override
  Future<void> tradeFilled(PaperOrder order) async {
    if (!isConfigured) return;
    final client = httpClient ?? http.Client();
    try {
      final response = await client.post(
        Uri.parse(endpoint),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'service_id': serviceId,
          'template_id': templateId,
          'user_id': publicKey,
          'template_params': {
            'symbol': 'BTCUSDT',
            'side': order.side.name.toUpperCase(),
            'price': order.marketPrice.toString(),
            'execution_price': order.executionPrice.toString(),
            'quantity': order.executedBtc.toString(),
            'amount': order.executedQuote.toString(),
            'fee': order.fee.toString(),
            'order_id': order.clientOrderId,
            'status': order.status.name.toUpperCase(),
            'time': order.createdAt.toUtc().toIso8601String(),
          },
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw EmailNotificationException(
          'EmailJS HTTP ${response.statusCode}: ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }
}

NotificationService? notificationServiceFromEnvironment() {
  const publicKey = String.fromEnvironment('EMAILJS_PUBLIC_KEY');
  const serviceId = String.fromEnvironment('EMAILJS_SERVICE_ID');
  const templateId = String.fromEnvironment('EMAILJS_TEMPLATE_ID');
  if (publicKey.isEmpty || serviceId.isEmpty || templateId.isEmpty) return null;
  return EmailJsNotificationService(
    publicKey: publicKey,
    serviceId: serviceId,
    templateId: templateId,
  );
}

class EmailNotificationException implements Exception {
  const EmailNotificationException(this.message);
  final String message;
  @override
  String toString() => 'EmailNotificationException: $message';
}
