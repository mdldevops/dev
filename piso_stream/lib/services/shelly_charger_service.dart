import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ShellyChargerService {
  ShellyChargerService._();

  static final ShellyChargerService instance = ShellyChargerService._();

  bool _hasRelayState = false;
  bool _lastRelayEnabled = false;

  void resetChargingDecisionCache() {
    _hasRelayState = false;
    _lastRelayEnabled = false;
  }

  Future<bool> syncChargingDecision({
    required int batteryLevel,
    required int startBelowPercent,
    required int stopAtPercent,
    required String onUrl,
    required String offUrl,
    required bool useToggle,
    required String toggleUrl,
    required bool useAuth,
    required String username,
    required String password,
  }) async {
    if (batteryLevel < 0 || batteryLevel > 100) {
      debugPrint('[ShellyChargerService] skipped invalid battery=$batteryLevel');
      return false;
    }

    final normalizedOnUrl = onUrl.trim();
    final normalizedOffUrl = offUrl.trim();
    final normalizedToggleUrl = toggleUrl.trim();
    if (useToggle && normalizedToggleUrl.isEmpty) {
      debugPrint('[ShellyChargerService] skipped missing toggle URL');
      return false;
    }
    if (!useToggle && (normalizedOnUrl.isEmpty || normalizedOffUrl.isEmpty)) {
      debugPrint('[ShellyChargerService] skipped missing ON/OFF URL');
      return false;
    }

    final desiredRelayEnabled = _determineRelayState(
      batteryLevel: batteryLevel,
      startBelowPercent: startBelowPercent,
      stopAtPercent: stopAtPercent,
    );
    if (desiredRelayEnabled == null) {
      debugPrint(
        '[ShellyChargerService] no command battery=$batteryLevel start=$startBelowPercent stop=$stopAtPercent',
      );
      return true;
    }

    final headers = _buildHeaders(
      useAuth: useAuth,
      username: username,
      password: password,
    );

    if (useToggle) {
      final actualRelayEnabled = await _readRelayState(
        _statusUrlFromCommandUrl(normalizedToggleUrl),
        headers,
      );

      if (actualRelayEnabled != null) {
        _hasRelayState = true;
        _lastRelayEnabled = actualRelayEnabled;
        if (actualRelayEnabled == desiredRelayEnabled) {
          debugPrint(
            '[ShellyChargerService] no-op actualRelay=$actualRelayEnabled target=$desiredRelayEnabled',
          );
          return true;
        }
      } else if (_hasRelayState && desiredRelayEnabled == _lastRelayEnabled) {
        debugPrint(
          '[ShellyChargerService] no-op cachedRelay=$_lastRelayEnabled target=$desiredRelayEnabled',
        );
        return true;
      }
    }

    final targetUrl = useToggle
        ? normalizedToggleUrl
        : desiredRelayEnabled
              ? normalizedOnUrl
              : normalizedOffUrl;

    try {
      debugPrint(
        '[ShellyChargerService] sending ${desiredRelayEnabled ? 'ON' : 'OFF'} url=$targetUrl battery=$batteryLevel',
      );
      final response = await http
          .get(Uri.parse(targetUrl), headers: headers)
          .timeout(const Duration(seconds: 8));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _hasRelayState = true;
        _lastRelayEnabled = desiredRelayEnabled;
        debugPrint(
          '[ShellyChargerService] success code=${response.statusCode}',
        );
        return true;
      }
      debugPrint(
        '[ShellyChargerService] failed code=${response.statusCode} body=${response.body}',
      );
      return false;
    } catch (error) {
      debugPrint('[ShellyChargerService] error: $error');
      return false;
    }
  }

  Map<String, String> _buildHeaders({
    required bool useAuth,
    required String username,
    required String password,
  }) {
    final headers = <String, String>{};
    if (useAuth) {
      final auth = base64Encode(
        utf8.encode('${username.trim()}:${password.trim()}'),
      );
      headers['Authorization'] = 'Basic $auth';
    }
    return headers;
  }

  String _statusUrlFromCommandUrl(String commandUrl) {
    final uri = Uri.tryParse(commandUrl);
    if (uri == null) {
      return commandUrl.split('?').first;
    }
    return uri.replace(query: null, fragment: null).toString();
  }

  Future<bool?> _readRelayState(
    String statusUrl,
    Map<String, String> headers,
  ) async {
    try {
      final response = await http
          .get(Uri.parse(statusUrl), headers: headers)
          .timeout(const Duration(seconds: 8));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> && decoded['ison'] is bool) {
        return decoded['ison'] as bool;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool? _determineRelayState({
    required int batteryLevel,
    required int startBelowPercent,
    required int stopAtPercent,
  }) {
    if (batteryLevel <= startBelowPercent) {
      return true;
    }
    if (batteryLevel >= stopAtPercent) {
      return false;
    }
    return null;
  }
}
