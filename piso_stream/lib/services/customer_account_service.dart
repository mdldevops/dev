import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';
import 'api_service.dart';

class CustomerAccountResult {
  const CustomerAccountResult({
    required this.username,
    required this.role,
    this.accountStatus = 'active',
    required this.savedSessionSeconds,
  });

  final String username;
  final String role;
  final String accountStatus;
  final int savedSessionSeconds;

  bool get isAdmin => role == 'admin';
}

class CustomerAccountService {
  static const String _defaultAdminUsername = 'admin';
  static const String _defaultAdminPassword = 'admin1234';
  static const String _defaultAdminRole = 'admin';

  static Uri _uri(String path) => Uri.parse('${ApiService.baseUrl}$path');

  static Future<CustomerAccountResult> register({
    required String username,
    required String password,
  }) async {
    final response = await http.post(
      _uri('/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'username': username,
        'password': password,
      }),
    );

    return _parseAccountResponse(response);
  }

  static Future<CustomerAccountResult> login({
    required String username,
    required String password,
  }) async {
    await _ensureLocalAdminAccount();

    try {
      final response = await http
          .post(
            _uri('/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'username': username,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 5));

      final result = _parseAccountResponse(response);
      if (result.isAdmin) {
        await _cacheLocalAdminAccount(
          username: result.username,
          password: password,
          role: result.role,
        );
      }

      return result;
    } on SocketException {
      return _loginWithLocalAdminFallback(username: username, password: password);
    } on HttpException {
      return _loginWithLocalAdminFallback(username: username, password: password);
    } on http.ClientException {
      return _loginWithLocalAdminFallback(username: username, password: password);
    } on HandshakeException {
      return _loginWithLocalAdminFallback(username: username, password: password);
    } on TimeoutException {
      return _loginWithLocalAdminFallback(username: username, password: password);
    } on FormatException {
      return _loginWithLocalAdminFallback(username: username, password: password);
    }
  }

  static Future<int> claimSavedSession(String username) async {
    final response = await http.post(
      _uri('/auth/claim-session'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'username': username}),
    );

    final body = _parseJson(response);
    if (response.statusCode >= 400) {
      throw Exception(body['error'] ?? 'Failed to claim saved session.');
    }

    return (body['savedSessionSeconds'] as num?)?.toInt() ?? 0;
  }

  static Future<void> saveSession({
    required String username,
    required int remainingSeconds,
  }) async {
    final response = await http.post(
      _uri('/auth/save-session'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'username': username,
        'remainingSeconds': remainingSeconds,
      }),
    );

    final body = _parseJson(response);
    if (response.statusCode >= 400) {
      throw Exception(body['error'] ?? 'Failed to save session.');
    }
  }

  static Future<String?> getCurrentCustomer() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(AppSettings.currentCustomerKey)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static Future<String?> getCurrentCustomerRole() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(AppSettings.currentCustomerRoleKey)?.trim();
    return value == null || value.isEmpty ? null : value.toLowerCase();
  }

  static Future<void> setCurrentCustomer(
    String username, {
    String role = 'customer',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppSettings.currentCustomerKey,
      username.trim().toLowerCase(),
    );
    await prefs.setString(
      AppSettings.currentCustomerRoleKey,
      role.trim().toLowerCase(),
    );
  }

  static Future<void> clearCurrentCustomer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppSettings.currentCustomerKey);
    await prefs.remove(AppSettings.currentCustomerRoleKey);
    await prefs.remove(AppSettings.customerIdleDeadlineKey);
  }

  static Future<void> startIdleDeadline({
    Duration duration = const Duration(minutes: 1),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      AppSettings.customerIdleDeadlineKey,
      DateTime.now().add(duration).millisecondsSinceEpoch,
    );
  }

  static Future<void> clearIdleDeadline() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppSettings.customerIdleDeadlineKey);
  }

  static Future<DateTime?> getIdleDeadline() async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(AppSettings.customerIdleDeadlineKey);
    if (millis == null) {
      return null;
    }

    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static CustomerAccountResult _parseAccountResponse(http.Response response) {
    final body = _parseJson(response);

    if (response.statusCode >= 400) {
      throw Exception(body['error'] ?? 'Request failed.');
    }

    return CustomerAccountResult(
      username: (body['username'] as String? ?? '').trim().toLowerCase(),
      role: (body['role'] as String? ?? 'customer').trim().toLowerCase(),
      accountStatus:
          (body['accountStatus'] as String? ?? 'active').trim().toLowerCase(),
      savedSessionSeconds: (body['savedSessionSeconds'] as num?)?.toInt() ?? 0,
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

  static Future<void> _ensureLocalAdminAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final existingUsername = prefs.getString(AppSettings.localAdminUsernameKey);
    final existingPassword = prefs.getString(AppSettings.localAdminPasswordKey);
    final existingRole = prefs.getString(AppSettings.localAdminRoleKey);

    if ((existingUsername ?? '').trim().isNotEmpty &&
        (existingPassword ?? '').trim().isNotEmpty &&
        (existingRole ?? '').trim().isNotEmpty) {
      return;
    }

    await _cacheLocalAdminAccount(
      username: _defaultAdminUsername,
      password: _defaultAdminPassword,
      role: _defaultAdminRole,
    );
  }

  static Future<void> _cacheLocalAdminAccount({
    required String username,
    required String password,
    required String role,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppSettings.localAdminUsernameKey,
      username.trim().toLowerCase(),
    );
    await prefs.setString(AppSettings.localAdminPasswordKey, password);
    await prefs.setString(
      AppSettings.localAdminRoleKey,
      role.trim().toLowerCase(),
    );
  }

  static Future<CustomerAccountResult> _loginWithLocalAdminFallback({
    required String username,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final localUsername =
        prefs.getString(AppSettings.localAdminUsernameKey)?.trim().toLowerCase();
    final localPassword = prefs.getString(AppSettings.localAdminPasswordKey);
    final localRole =
        prefs.getString(AppSettings.localAdminRoleKey)?.trim().toLowerCase();
    final requestedUsername = username.trim().toLowerCase();

    if (requestedUsername == localUsername &&
        password == localPassword &&
        localRole == _defaultAdminRole) {
      return CustomerAccountResult(
        username: localUsername ?? _defaultAdminUsername,
        role: localRole ?? _defaultAdminRole,
        savedSessionSeconds: 0,
      );
    }

    throw Exception('Unable to login offline. Connect to the server and try again.');
  }
}
