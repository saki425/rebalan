import 'dart:convert';

import 'package:crypto/crypto.dart';

class BinanceSigner {
  const BinanceSigner();

  String sign(String payload, String secretKey) => Hmac(
    sha256,
    utf8.encode(secretKey),
  ).convert(utf8.encode(payload)).toString();

  String encodeParameters(Map<String, String> parameters) => parameters.entries
      .map(
        (entry) =>
            '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
      )
      .join('&');
}
