import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';

class DeviceIdentityService {
  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final token = await _getOrCreateDeviceToken(prefs);
    final deviceName = prefs.getString(AppSettings.deviceNameKey)?.trim() ?? '';
    final deviceId = _composeDeviceId(deviceName, token);

    await prefs.setString(AppSettings.kioskDeviceIdKey, deviceId);
    return deviceId;
  }

  static Future<String> _getOrCreateDeviceToken(SharedPreferences prefs) async {
    final savedToken = prefs.getString(AppSettings.kioskDeviceTokenKey)?.trim();
    if (savedToken != null && savedToken.isNotEmpty) {
      return savedToken;
    }

    final existingId = prefs.getString(AppSettings.kioskDeviceIdKey)?.trim();
    final migratedToken = _extractToken(existingId);
    if (migratedToken != null && migratedToken.isNotEmpty) {
      await prefs.setString(AppSettings.kioskDeviceTokenKey, migratedToken);
      return migratedToken;
    }

    final newToken = _generateDeviceToken();
    await prefs.setString(AppSettings.kioskDeviceTokenKey, newToken);
    return newToken;
  }

  static String _generateDeviceToken() {
    final random = Random.secure();
    final timestamp = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final randomPart = List.generate(
      8,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return '$timestamp$randomPart';
  }

  static String _composeDeviceId(String deviceName, String token) {
    final normalizedName = _normalizeDeviceName(deviceName);
    if (normalizedName.isEmpty) {
      return 'device_$token';
    }

    return '${normalizedName}__$token';
  }

  static String _normalizeDeviceName(String value) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');

    return normalized;
  }

  static String? _extractToken(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return null;
    }

    final doubleUnderscoreIndex = deviceId.lastIndexOf('__');
    if (doubleUnderscoreIndex != -1 &&
        doubleUnderscoreIndex + 2 < deviceId.length) {
      return deviceId.substring(doubleUnderscoreIndex + 2);
    }

    const legacyPrefix = 'device_';
    if (deviceId.startsWith(legacyPrefix) &&
        deviceId.length > legacyPrefix.length) {
      return deviceId.substring(legacyPrefix.length);
    }

    return null;
  }
}
