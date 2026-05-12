import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_service.dart';

class AdminPinService {
  static const String defaultOfflinePin = '123456';

  static Uri _uri(String path) => Uri.parse('${ApiService.baseUrl}$path');

  static Future<bool> verifyPin(String pin) async {
    try {
      final response = await http
          .post(
            _uri('/admin/verify-pin'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{'pin': pin}),
          )
          .timeout(const Duration(seconds: 5));

      final body = _parseJson(response);
      if (response.statusCode >= 400) {
        throw Exception(body['error'] ?? 'Failed to verify PIN.');
      }

      return body['valid'] == true;
    } on SocketException {
      return pin == defaultOfflinePin;
    } on HttpException {
      return pin == defaultOfflinePin;
    } on http.ClientException {
      return pin == defaultOfflinePin;
    } on HandshakeException {
      return pin == defaultOfflinePin;
    } on FormatException {
      return pin == defaultOfflinePin;
    } on TimeoutException {
      return pin == defaultOfflinePin;
    }
  }

  static Future<void> updatePin({
    required String currentPin,
    required String newPin,
  }) async {
    final response = await http.post(
      _uri('/admin/update-pin'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'currentPin': currentPin,
        'newPin': newPin,
      }),
    );

    final body = _parseJson(response);
    if (response.statusCode >= 400) {
      throw Exception(body['error'] ?? 'Failed to update PIN.');
    }
  }

  static Map<String, dynamic> _parseJson(http.Response response) {
    if (response.body.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    return <String, dynamic>{};
  }
}
