import 'dart:convert';
import 'package:http/http.dart' as http;

class DeviceStatusResult {
  const DeviceStatusResult({required this.isLocked, required this.message});

  final bool isLocked;
  final String message;
}

class ApiService {
  static final Uri _serverUri = Uri.parse("https://portal.pisostream.online");

  static String get baseUrl => _serverUri.origin;

  static String get socketUrl => _serverUri.origin;

  static Future<Map<String, dynamic>?> startSession(
    String deviceId, {
    String? deviceName,
  }) async {
    final url = Uri.parse("$baseUrl/start-session");

    try {
      final res = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"deviceId": deviceId, "deviceName": deviceName}),
      );

      if (res.statusCode == 200) {
        return jsonDecode(res.body);
      }
    } catch (e) {
      print("Start session error: $e");
    }

    return null;
  }

  static Future<Map<String, dynamic>?> startSessionWithRetry(
    String deviceId,
    String? deviceName,
  ) async {
    for (int i = 0; i < 5; i++) {
      print("Start session attempt ${i + 1}");

      final result = await startSession(deviceId, deviceName: deviceName);

      if (result != null) return result;

      await Future.delayed(const Duration(seconds: 2));
    }

    return null;
  }

  static Future<bool> endSession(String deviceId, {String? deviceName}) async {
    final url = Uri.parse("$baseUrl/confirm-session");

    try {
      final res = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"deviceId": deviceId, "deviceName": deviceName}),
      );

      return res.statusCode == 200;
    } catch (e) {
      print("End session error: $e");
      return false;
    }
  }

  static Future<void> updateDeviceState({
    required String deviceId,
    required String status,
    required int remainingSeconds,
    required bool isSessionActive,
    String? username,
    String? role,
    int? batteryLevel,
    int? chargerRelayPin,
  }) async {
    final url = Uri.parse("$baseUrl/device-state");

    try {
      await http
          .post(
            url,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "deviceId": deviceId,
              "status": status,
              "remainingSeconds": remainingSeconds,
              "username": username,
              "role": role,
              "isSessionActive": isSessionActive,
              "batteryLevel": batteryLevel,
              "chargerRelayPin": chargerRelayPin,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      print("Update device state error: $e");
    }
  }

  static Future<bool> releaseSession(
    String deviceId, {
    String? deviceName,
  }) async {
    final url = Uri.parse("$baseUrl/release-session");

    try {
      final res = await http
          .post(
            url,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"deviceId": deviceId, "deviceName": deviceName}),
          )
          .timeout(const Duration(seconds: 5));

      return res.statusCode == 200;
    } catch (e) {
      print("Release session error: $e");
      return false;
    }
  }

  static Future<DeviceStatusResult?> getDeviceStatus(String deviceId) async {
    final url = Uri.parse("$baseUrl/devices/$deviceId/status");

    try {
      final res = await http.get(url).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        return null;
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return DeviceStatusResult(
        isLocked: body['isLocked'] == true,
        message: (body['message'] as String? ?? '').trim(),
      );
    } catch (e) {
      print("Get device status error: $e");
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getSessionState(String deviceId) async {
    final url = Uri.parse("$baseUrl/sessions/$deviceId/state");

    try {
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        return null;
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      print("Get session state failed: $e");
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getChargingConfig() async {
    final url = Uri.parse("$baseUrl/settings/charging-config");

    try {
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        return null;
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      print("Get charging config failed: $e");
      return null;
    }
  }

  static Future<bool> updateChargingConfig({
    required int startBelowPercent,
    required int stopAtPercent,
  }) async {
    final url = Uri.parse("$baseUrl/settings/charging-config");

    try {
      final response = await http
          .post(
            url,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "settings": {
                "startBelowPercent": startBelowPercent,
                "stopAtPercent": stopAtPercent,
              },
            }),
          )
          .timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      print("Update charging config failed: $e");
      return false;
    }
  }
}
