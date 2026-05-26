import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';

class MqttCoinEvent {
  const MqttCoinEvent({
    required this.eventId,
    required this.amount,
    required this.controllerId,
    required this.activeLauncherDeviceId,
    required this.activeLauncherDeviceName,
    required this.timestamp,
  });

  final String eventId;
  final int amount;
  final String controllerId;
  final String activeLauncherDeviceId;
  final String activeLauncherDeviceName;
  final int timestamp;
}

class MqttCoinOpenResult {
  const MqttCoinOpenResult({required this.allowed, required this.message});

  final bool allowed;
  final String message;
}

class StandaloneMqttService {
  StandaloneMqttService._();

  static final StandaloneMqttService instance = StandaloneMqttService._();

  static const int _controllerPort = 81;

  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<MqttCoinEvent> _coinEventsController =
      StreamController<MqttCoinEvent>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<MqttCoinEvent> get coinEvents => _coinEventsController.stream;

  WebSocket? _socket;
  String? _connectedHost;
  Map<String, dynamic>? _latestControllerStatus;

  bool get isConnected => _socket != null;
  String? get connectedHost => _connectedHost;
  Map<String, dynamic>? get latestControllerStatus => _latestControllerStatus;

  Future<bool> connectBySavedHost() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(AppSettings.standaloneControllerIpKey)?.trim();
    if (host == null || host.isEmpty) {
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'No saved coin controller IP.',
      });
      return false;
    }
    return connectByHost(host);
  }

  Future<bool> connectByHost(String host) async {
    final normalizedHost = _normalizeControllerHost(host);
    if (normalizedHost.isEmpty) {
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'Enter the coin controller IP first.',
      });
      return false;
    }

    if (isConnected && _connectedHost == normalizedHost) {
      return true;
    }

    await disconnect();

    try {
      final socket = await WebSocket.connect(
        'ws://$normalizedHost:$_controllerPort',
      ).timeout(const Duration(seconds: 4));

      _socket = socket;
      _connectedHost = normalizedHost;
      _latestControllerStatus = null;

      socket.listen(
        _handleIncomingMessage,
        onDone: _handleDisconnected,
        onError: (_) => _handleDisconnected(),
        cancelOnError: true,
      );

      _messageController.add(<String, dynamic>{
        'type': 'connected',
        'message':
            'Connected to coin controller at $normalizedHost via WebSocket.',
      });
      return true;
    } catch (error) {
      _socket = null;
      _connectedHost = null;
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'Coin controller connection failed: $error',
      });
      return false;
    }
  }

  Future<MqttCoinOpenResult> openSession({
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    if (!isConnected) {
      final connected = await connectBySavedHost();
      if (!connected) {
        return const MqttCoinOpenResult(
          allowed: false,
          message: 'Unable to connect to coin controller.',
        );
      }
    }

    _latestControllerStatus = null;

    final response = await _sendCommandAndWait(
      <String, dynamic>{
        'type': 'open_session',
        'launcher_device_id': launcherDeviceId,
        'launcher_device_name': launcherDeviceName,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      acceptedTypes: const <String>{
        'open_session_ack',
        'acceptor_open',
        'session_busy',
      },
    );

    final effectiveResponse = response ?? _latestControllerStatus;
    if (effectiveResponse == null) {
      return const MqttCoinOpenResult(
        allowed: false,
        message: 'Coin controller did not respond.',
      );
    }

    final type = (effectiveResponse['type'] ?? '').toString();
    final ownerLauncherId = (effectiveResponse['activeLauncherDeviceId'] ?? '')
        .toString();
    final acceptorOpen =
        (effectiveResponse['acceptorOpen'] as bool?) ?? false;
    final acceptorOpenPending =
        (effectiveResponse['acceptorOpenPending'] as bool?) ?? false;

    if (ownerLauncherId == launcherDeviceId &&
        (type == 'open_session_ack' ||
            type == 'acceptor_open' ||
            (acceptorOpen || acceptorOpenPending))) {
      return MqttCoinOpenResult(
        allowed: true,
        message: (effectiveResponse['message'] ?? 'Coin controller is ready.')
            .toString(),
      );
    }

    return MqttCoinOpenResult(
      allowed: false,
      message: (effectiveResponse['message'] ??
              'Another machine is using the coin acceptor.')
          .toString(),
    );
  }

  Future<void> closeSession({
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    if (!isConnected) {
      return;
    }

    await _sendCommand(<String, dynamic>{
      'type': 'close_session',
      'launcher_device_id': launcherDeviceId,
      'launcher_device_name': launcherDeviceName,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> acknowledgeCoinCredit({
    required String launcherDeviceId,
    required String launcherDeviceName,
    required String eventId,
  }) async {
    if (!isConnected || eventId.trim().isEmpty) {
      return;
    }

    await _sendCommand(<String, dynamic>{
      'type': 'coin_credit_ack',
      'launcher_device_id': launcherDeviceId,
      'launcher_device_name': launcherDeviceName,
      'event_id': eventId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<Map<String, dynamic>?> ping({
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    if (!isConnected) {
      final connected = await connectBySavedHost();
      if (!connected) {
        return null;
      }
    }

    return _sendCommandAndWait(
      <String, dynamic>{
        'type': 'status_request',
        'launcher_device_id': launcherDeviceId,
        'launcher_device_name': launcherDeviceName,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      acceptedTypes: const <String>{'controller_status'},
    );
  }

  Future<void> disconnect() async {
    final socket = _socket;
    _socket = null;
    _connectedHost = null;
    _latestControllerStatus = null;

    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  void _handleIncomingMessage(dynamic rawMessage) {
    try {
      final decoded = jsonDecode(rawMessage.toString());
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final type = (decoded['type'] ?? '').toString();
      if (type == 'controller_status' ||
          type == 'open_session_ack' ||
          type == 'close_session_ack' ||
          type == 'session_busy' ||
          type == 'acceptor_open' ||
          type == 'coin_credit_ack') {
        _latestControllerStatus = Map<String, dynamic>.from(decoded);
      }

      _messageController.add(decoded);

      if (type == 'coin_inserted') {
        _coinEventsController.add(
          MqttCoinEvent(
            eventId: (decoded['eventId'] ?? '').toString(),
            amount: (decoded['amount'] as num?)?.toInt() ?? 0,
            controllerId: (decoded['controllerId'] ?? '').toString(),
            activeLauncherDeviceId:
                (decoded['activeLauncherDeviceId'] ?? '').toString(),
            activeLauncherDeviceName:
                (decoded['activeLauncherDeviceName'] ?? '').toString(),
            timestamp: (decoded['timestamp'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _sendCommand(Map<String, dynamic> payload) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('Coin controller is not connected.');
    }
    socket.add(jsonEncode(payload));
  }

  Future<Map<String, dynamic>?> _sendCommandAndWait(
    Map<String, dynamic> payload, {
    required Set<String> acceptedTypes,
  }) async {
    final completer = Completer<Map<String, dynamic>?>();
    late StreamSubscription<Map<String, dynamic>> subscription;
    subscription = messages.listen((message) {
      final type = (message['type'] ?? '').toString();
      if (acceptedTypes.contains(type) && !completer.isCompleted) {
        completer.complete(message);
      }
    });

    try {
      await _sendCommand(payload);
      final result = await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => null,
      );
      await subscription.cancel();
      return result;
    } catch (error) {
      await subscription.cancel();
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'Failed to send coin controller command: $error',
      });
      return null;
    }
  }

  void _handleDisconnected() {
    _socket = null;
    _connectedHost = null;
    _latestControllerStatus = null;
    _messageController.add(<String, dynamic>{
      'type': 'disconnected',
      'message': 'Coin controller disconnected.',
    });
  }

  String _normalizeControllerHost(String rawHost) {
    final trimmed = rawHost.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    final hasScheme = trimmed.contains('://');
    final uri = Uri.tryParse(hasScheme ? trimmed : 'ws://$trimmed');
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host.trim();
    }

    var normalized = trimmed;
    if (normalized.startsWith('ws://')) {
      normalized = normalized.substring('ws://'.length);
    } else if (normalized.startsWith('wss://')) {
      normalized = normalized.substring('wss://'.length);
    }

    final slashIndex = normalized.indexOf('/');
    if (slashIndex >= 0) {
      normalized = normalized.substring(0, slashIndex);
    }

    final colonIndex = normalized.indexOf(':');
    if (colonIndex >= 0) {
      normalized = normalized.substring(0, colonIndex);
    }

    return normalized.trim();
  }
}
