import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import '../app_settings.dart';

class AdminPinService {
  static const String defaultOfflinePin = '123456';

  static Uri _uri(String path) => Uri.parse('${ApiService.baseUrl}$path');

  static Future<bool> verifyPin(String pin) async {
    if (await _isStandaloneMode()) {
      return _verifyLocalPin(pin);
    }

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
      return _verifyLocalPin(pin);
    } on HttpException {
      return _verifyLocalPin(pin);
    } on http.ClientException {
      return _verifyLocalPin(pin);
    } on HandshakeException {
      return _verifyLocalPin(pin);
    } on FormatException {
      return _verifyLocalPin(pin);
    } on TimeoutException {
      return _verifyLocalPin(pin);
    }
  }

  static Future<void> updatePin({
    required String currentPin,
    required String newPin,
    bool useLocalOnly = false,
  }) async {
    if (useLocalOnly || await _isStandaloneMode()) {
      await _updateLocalPin(currentPin: currentPin, newPin: newPin);
      return;
    }

    try {
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

      await _saveLocalPin(newPin);
    } on SocketException {
      await _updateLocalPin(currentPin: currentPin, newPin: newPin);
    } on HttpException {
      await _updateLocalPin(currentPin: currentPin, newPin: newPin);
    } on http.ClientException {
      await _updateLocalPin(currentPin: currentPin, newPin: newPin);
    } on HandshakeException {
      await _updateLocalPin(currentPin: currentPin, newPin: newPin);
    } on TimeoutException {
      await _updateLocalPin(currentPin: currentPin, newPin: newPin);
    }
  }

  static Future<void> _updateLocalPin({
    required String currentPin,
    required String newPin,
  }) async {
    if (!await _verifyLocalPin(currentPin)) {
      throw Exception('Current PIN is incorrect.');
    }

    await _saveLocalPin(newPin);
  }

  static Future<bool> _verifyLocalPin(String pin) async {
    return pin == await _localPin();
  }

  static Future<String> _localPin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPin = prefs.getString(AppSettings.localAdminPinKey)?.trim();
    return savedPin == null || savedPin.isEmpty ? defaultOfflinePin : savedPin;
  }

  static Future<void> _saveLocalPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppSettings.localAdminPinKey, pin);
  }

  static Future<bool> _isStandaloneMode() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings.isStandaloneModeValue(
      prefs.getString(AppSettings.setupModeKey),
    );
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
