import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';
import 'controller_endpoint.dart';

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

class _HttpControllerResponse {
  const _HttpControllerResponse({required this.statusCode, required this.data});

  final int statusCode;
  final Map<String, dynamic>? data;
}

enum ControllerCommunicationMode { socket, http }

class StandaloneMqttService {
  StandaloneMqttService._();

  static final StandaloneMqttService instance = StandaloneMqttService._();

  static const int _httpControllerPort = 80;
  static const Duration _controllerTimeout = Duration(seconds: 10);
  static const Duration _httpTimeout = _controllerTimeout;
  static const Duration _httpEventPollInterval = Duration(milliseconds: 350);
  static const MethodChannel _platformChannel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );

  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<MqttCoinEvent> _coinEventsController =
      StreamController<MqttCoinEvent>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<MqttCoinEvent> get coinEvents => _coinEventsController.stream;

  WebSocket? _socket;
  String? _connectedHost;
  String? _resolvedHost;
  int? _connectedPort;
  ControllerTransport? _connectedTransport;
  Map<String, dynamic>? _latestControllerStatus;
  Future<bool>? _connectionFuture;
  String? _connectionFutureHost;
  int _connectionGeneration = 0;
  bool _httpConnected = false;
  Timer? _httpEventPollTimer;
  String? _httpPollingLauncherDeviceId;
  final Set<String> _processedHttpEventIds = <String>{};

  bool get isConnected =>
      _socket?.readyState == WebSocket.open || _httpConnected;
  String? get connectedHost => _connectedHost;
  String? get resolvedHost => _resolvedHost;
  int? get connectedPort => _connectedPort;
  ControllerTransport? get connectedTransport => _connectedTransport;
  Map<String, dynamic>? get latestControllerStatus => _latestControllerStatus;

  Future<bool> connectBySavedHost() async {
    final config = await ControllerEndpointConfig.load();
    final endpoint = config.activeEndpoint;
    if (endpoint.host.trim().isEmpty) {
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'No saved coin controller address.',
      });
      return false;
    }
    return connectByEndpoint(endpoint);
  }

  Future<bool> connectByHost(String host) async {
    final config = await ControllerEndpointConfig.load();
    final endpoint = config.activeEndpoint;

    return connectByEndpoint(
      ControllerEndpoint(
        transport: endpoint.transport,
        host: host,
        port: endpoint.port,
      ),
    );
  }

  Future<bool> connectByEndpoint(ControllerEndpoint endpoint) async {
    print(
      '[CONTROLLER] Mode=${endpoint.label} Host=${endpoint.host} Port=${endpoint.port}',
    );

    if (endpoint.transport == ControllerTransport.http) {
      return _connectHttpByHost(endpoint.host, port: endpoint.port);
    }

    return _connectSocketByHost(endpoint.host, port: endpoint.port);
  }

  Future<bool> _connectSocketByHost(
    String host, {
    required int port,
  }) async {
    _httpConnected = false;
    _stopHttpEventPolling();
    print('[CoinWS] connect requested host=$host port=$port');
    final normalizedHost = _normalizeControllerHost(host);
    print('[CoinWS] normalized host=$normalizedHost');
    if (normalizedHost.isEmpty) {
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'Enter the coin controller IP first.',
      });
      return false;
    }

    if (_socket?.readyState == WebSocket.open &&
        _connectedHost == normalizedHost &&
        _connectedPort == port &&
        _connectedTransport == ControllerTransport.socket) {
      print('[CoinWS] reusing existing connection host=$normalizedHost port=$port');
      return true;
    }

    final activeConnectionFuture = _connectionFuture;
    if (activeConnectionFuture != null) {
      if (_connectionFutureHost == '$normalizedHost:$port') {
        print(
          '[CoinWS] reusing existing connection attempt host=$normalizedHost',
        );
        return activeConnectionFuture;
      }
      print(
        '[CoinWS] different host requested while connecting; closing old connection chain',
      );
      await disconnect();
    }

    if (_socket?.readyState == WebSocket.open &&
        (_connectedHost != normalizedHost || _connectedPort != port)) {
      print('[CoinWS] closing old socket for host=$_connectedHost port=$_connectedPort');
      await disconnect();
    }

    final generation = ++_connectionGeneration;
    final connectionFuture = _connectByHostLocked(
      normalizedHost,
      generation,
      port: port,
    );
    _connectionFuture = connectionFuture;
    _connectionFutureHost = '$normalizedHost:$port';

    try {
      return await connectionFuture;
    } finally {
      if (identical(_connectionFuture, connectionFuture)) {
        _connectionFuture = null;
        _connectionFutureHost = null;
      }
    }
  }

  Future<MqttCoinOpenResult> openSession({
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    if (await _isHttpMode()) {
      return _openHttpSession(
        launcherDeviceId: launcherDeviceId,
        launcherDeviceName: launcherDeviceName,
      );
    }

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
        'session_busy',
        'error',
      },
    );

    if (response == null) {
      return const MqttCoinOpenResult(
        allowed: false,
        message: 'Coin controller did not respond.',
      );
    }

    final type = (response['type'] ?? '').toString();
    final allowed = (response['allowed'] as bool?) ?? false;
    final ownerLauncherId = (response['activeLauncherDeviceId'] ?? '')
        .toString();

    if (type == 'open_session_ack' &&
        allowed &&
        ownerLauncherId == launcherDeviceId) {
      return MqttCoinOpenResult(
        allowed: true,
        message: (response['message'] ?? 'Coin controller is ready.')
            .toString(),
      );
    }

    return MqttCoinOpenResult(
      allowed: false,
      message:
          (response['message'] ?? 'Another machine is using the coin acceptor.')
              .toString(),
    );
  }

  Future<void> closeSession({
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    if (await _isHttpMode()) {
      await _closeHttpSession(
        launcherDeviceId: launcherDeviceId,
        launcherDeviceName: launcherDeviceName,
      );
      return;
    }

    if (!isConnected) {
      final connected = await connectBySavedHost();
      if (!connected) {
        return;
      }
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
    if (await _isHttpMode()) {
      await _acknowledgeHttpCoinCredit(
        launcherDeviceId: launcherDeviceId,
        launcherDeviceName: launcherDeviceName,
        eventId: eventId,
      );
      return;
    }

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
    if (await _isHttpMode()) {
      return _sendHttpHeartbeat(
        launcherDeviceId: launcherDeviceId,
        launcherDeviceName: launcherDeviceName,
      );
    }

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
    print('[CoinWS] disconnect requested');
    _connectionGeneration++;
    _connectionFuture = null;
    _connectionFutureHost = null;
    final socket = _socket;
    _socket = null;
    _connectedHost = null;
    _resolvedHost = null;
    _connectedPort = null;
    _connectedTransport = null;
    _latestControllerStatus = null;
    _httpConnected = false;
    _stopHttpEventPolling();

    if (socket != null) {
      try {
        print('[CoinWS] closing old socket');
        await socket.close().timeout(const Duration(seconds: 2));
      } catch (error) {
        print('[CoinWS] socket close ignored: $error');
      }
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
            activeLauncherDeviceId: (decoded['activeLauncherDeviceId'] ?? '')
                .toString(),
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
    if (socket == null || socket.readyState != WebSocket.open) {
      _socket = null;
      _connectedHost = null;
      _resolvedHost = null;
      _connectedPort = null;
      _connectedTransport = null;
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
      } else if (type == 'disconnected' && !completer.isCompleted) {
        completer.complete(null);
      }
    });

    try {
      await _sendCommand(payload);
      final result = await completer.future.timeout(
        _controllerTimeout,
        onTimeout: () => null,
      );
      return result;
    } catch (error) {
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'Failed to send coin controller command: $error',
      });
      return null;
    } finally {
      await subscription.cancel();
    }
  }

  void _handleDisconnected(WebSocket socket, [Object? error]) {
    if (!identical(_socket, socket)) {
      print('[CoinWS] stale socket disconnect ignored');
      return;
    }
    if (error != null) {
      print('[CoinWS] WebSocket error: $error');
    }
    print('[CoinWS] WebSocket disconnected');
    _socket = null;
    _connectedHost = null;
    _resolvedHost = null;
    _connectedPort = null;
    _connectedTransport = null;
    _latestControllerStatus = null;
    _messageController.add(<String, dynamic>{
      'type': 'disconnected',
      'message': 'Coin controller disconnected.',
    });
  }

  Future<ControllerCommunicationMode> _loadCommunicationMode() async {
    final prefs = await SharedPreferences.getInstance();
    final value =
        prefs.getString(AppSettings.controllerCommunicationModeKey) ??
        AppSettings.controllerCommunicationModeSocket;
    return value == AppSettings.controllerCommunicationModeHttp
        ? ControllerCommunicationMode.http
        : ControllerCommunicationMode.socket;
  }

  Future<bool> _isHttpMode() async {
    return await _loadCommunicationMode() == ControllerCommunicationMode.http;
  }

  Future<bool> _connectHttpByHost(
    String host, {
    required int port,
  }) async {
    print('[CoinHTTP] connect requested host=$host port=$port');
    final normalizedHost = _normalizeControllerHost(host);
    if (normalizedHost.isEmpty) {
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'Enter the coin controller address first.',
      });
      return false;
    }

    await _closeSocketOnly();
    _connectionGeneration++;
    _connectionFuture = null;
    _connectionFutureHost = null;

    try {
      final connectionHost = await _resolveConnectionHost(
        normalizedHost,
        serviceType: '_http._tcp.',
      );

      final response = await http
          .get(_httpUri(connectionHost, '/api/status', port: port))
          .timeout(_httpTimeout);

      final decoded = _decodeHttpResponse(response);

      if (response.statusCode != 200 || decoded == null) {
        _httpConnected = false;
        _connectedHost = null;
        _resolvedHost = null;
        _connectedPort = null;
        _connectedTransport = null;
        _messageController.add(<String, dynamic>{
          'type': 'error',
          'message': _httpErrorMessage(response.statusCode, decoded),
        });

        return false;
      }

      _httpConnected = true;
      _connectedHost = normalizedHost;
      _resolvedHost = connectionHost;
      _connectedPort = port;
      _connectedTransport = ControllerTransport.http;
      _latestControllerStatus = decoded;
      _messageController.add(<String, dynamic>{
        ...decoded,
        'message': connectionHost == normalizedHost
            ? 'Connected to coin controller at $normalizedHost via HTTP.'
            : 'Connected to coin controller at '
                  '$normalizedHost ($connectionHost) via HTTP.',
      });
      return true;
    } catch (error) {
      _httpConnected = false;
      _connectedHost = null;
      _resolvedHost = null;
      _connectedPort = null;
      _connectedTransport = null;
      _latestControllerStatus = null;
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'Unable to connect to PisoCoin controller: $error',
      });
      return false;
    }
  }

  Future<MqttCoinOpenResult> _openHttpSession({
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    if (!_httpConnected) {
      final connected = await connectBySavedHost();
      if (!connected) {
        return const MqttCoinOpenResult(
          allowed: false,
          message: 'Unable to connect to PisoCoin controller.',
        );
      }
    }

    final response = await _postHttpJson('/api/session/open', <String, dynamic>{
      'launcher_device_id': launcherDeviceId,
      'launcher_device_name': launcherDeviceName,
    });

    final data = response.data;
    if (data == null) {
      return MqttCoinOpenResult(
        allowed: false,
        message: _httpErrorMessage(response.statusCode, null),
      );
    }

    _latestControllerStatus = data;
    _messageController.add(data);

    if (response.statusCode == 409) {
      return MqttCoinOpenResult(
        allowed: false,
        message:
            (data['message'] ??
                    'Controller is currently being used by another machine.')
                .toString(),
      );
    }

    final type = (data['type'] ?? '').toString();
    final allowed = (data['allowed'] as bool?) ?? false;
    final ownerLauncherId = (data['activeLauncherDeviceId'] ?? '').toString();
    if (response.statusCode == 200 &&
        type == 'open_session_ack' &&
        allowed &&
        ownerLauncherId == launcherDeviceId) {
      _startHttpEventPolling(launcherDeviceId: launcherDeviceId);
      return MqttCoinOpenResult(
        allowed: true,
        message: (data['message'] ?? 'Coin controller is ready.').toString(),
      );
    }

    return MqttCoinOpenResult(
      allowed: false,
      message: (data['message'] ?? _httpErrorMessage(response.statusCode, data))
          .toString(),
    );
  }

  Future<void> _closeHttpSession({
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    _stopHttpEventPolling();
    if (!_httpConnected) {
      final connected = await connectBySavedHost();
      if (!connected) {
        return;
      }
    }
    await _postHttpJson('/api/session/close', <String, dynamic>{
      'launcher_device_id': launcherDeviceId,
      'launcher_device_name': launcherDeviceName,
    });
  }

  Future<Map<String, dynamic>?> _sendHttpHeartbeat({
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    if (!_httpConnected) {
      final connected = await connectBySavedHost();
      if (!connected) {
        return null;
      }
    }
    final response =
        await _postHttpJson('/api/session/heartbeat', <String, dynamic>{
          'launcher_device_id': launcherDeviceId,
          'launcher_device_name': launcherDeviceName,
        });
    if (response.data != null) {
      _latestControllerStatus = response.data;
      _messageController.add(response.data!);
    }
    return response.statusCode == 200 ? response.data : null;
  }

  Future<void> _acknowledgeHttpCoinCredit({
    required String launcherDeviceId,
    required String launcherDeviceName,
    required String eventId,
  }) async {
    if (!_httpConnected || eventId.trim().isEmpty) {
      return;
    }
    await _postHttpJson('/api/coin/ack', <String, dynamic>{
      'launcher_device_id': launcherDeviceId,
      'launcher_device_name': launcherDeviceName,
      'event_id': eventId,
    });
  }

  void _startHttpEventPolling({required String launcherDeviceId}) {
    if (_httpPollingLauncherDeviceId == launcherDeviceId &&
        _httpEventPollTimer?.isActive == true) {
      return;
    }
    _stopHttpEventPolling(clearProcessedEvents: false);
    _httpPollingLauncherDeviceId = launcherDeviceId;
    unawaited(_pollHttpEventsOnce());
    _httpEventPollTimer = Timer.periodic(
      _httpEventPollInterval,
      (_) => unawaited(_pollHttpEventsOnce()),
    );
  }

  void _stopHttpEventPolling({bool clearProcessedEvents = true}) {
    _httpEventPollTimer?.cancel();
    _httpEventPollTimer = null;
    _httpPollingLauncherDeviceId = null;
    if (clearProcessedEvents) {
      _processedHttpEventIds.clear();
    }
  }

  Future<void> _pollHttpEventsOnce() async {
    final launcherDeviceId = _httpPollingLauncherDeviceId;
    if (!_httpConnected ||
        launcherDeviceId == null ||
        launcherDeviceId.isEmpty) {
      return;
    }
    final host = _resolvedHost ?? _connectedHost;
    if (host == null || host.isEmpty) {
      return;
    }

    try {
      final response = await http
          .get(
            _httpUri(
              host,
              '/api/events',
              port: _connectedPort,
              queryParameters: <String, String>{
                'launcher_device_id': launcherDeviceId,
              },
            ),
          )
          .timeout(_httpTimeout);
      final data = _decodeHttpResponse(response);
      if (data == null) {
        return;
      }
      final type = (data['type'] ?? '').toString();
      if (type == 'no_event') {
        return;
      }
      if (type != 'coin_inserted') {
        _messageController.add(data);
        return;
      }

      final eventId = (data['eventId'] ?? '').toString();
      if (eventId.isEmpty || !_processedHttpEventIds.add(eventId)) {
        return;
      }

      final event = MqttCoinEvent(
        eventId: eventId,
        amount: (data['amount'] as num?)?.toInt() ?? 0,
        controllerId: (data['controllerId'] ?? '').toString(),
        activeLauncherDeviceId: (data['activeLauncherDeviceId'] ?? '')
            .toString(),
        activeLauncherDeviceName: (data['activeLauncherDeviceName'] ?? '')
            .toString(),
        timestamp: (data['timestamp'] as num?)?.toInt() ?? 0,
      );
      _coinEventsController.add(event);
    } catch (error) {
      _httpConnected = false;
      _messageController.add(<String, dynamic>{
        'type': 'error',
        'message': 'Unable to connect to PisoCoin controller: $error',
      });
    }
  }

  Future<_HttpControllerResponse> _postHttpJson(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final host = _resolvedHost ?? _connectedHost;
    if (host == null || host.isEmpty) {
      return const _HttpControllerResponse(
        statusCode: 0,
        data: <String, dynamic>{
          'type': 'error',
          'message': 'Unable to connect to PisoCoin controller.',
        },
      );
    }
    try {
      final response = await http
          .post(
            _httpUri(host, path, port: _connectedPort),
            headers: const <String, String>{
              HttpHeaders.contentTypeHeader: 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(_httpTimeout);
      final data = _decodeHttpResponse(response);
      if (data != null &&
          response.statusCode >= 200 &&
          response.statusCode < 500) {
        return _HttpControllerResponse(
          statusCode: response.statusCode,
          data: data,
        );
      }
      return _HttpControllerResponse(
        statusCode: response.statusCode,
        data:
            data ??
            <String, dynamic>{
              'type': 'error',
              'message': _httpErrorMessage(response.statusCode, null),
            },
      );
    } catch (error) {
      _httpConnected = false;
      return _HttpControllerResponse(
        statusCode: 0,
        data: <String, dynamic>{
          'type': 'error',
          'message': 'Unable to connect to PisoCoin controller: $error',
        },
      );
    }
  }

  Uri _httpUri(
    String host,
    String path, {
    int? port,
    Map<String, String>? queryParameters,
  }) {
    return Uri(
      scheme: 'http',
      host: host,
      port: port ?? _connectedPort ?? _httpControllerPort,
      path: path,
      queryParameters: queryParameters,
    );
  }

  Map<String, dynamic>? _decodeHttpResponse(http.Response response) {
    if (response.body.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  String _httpErrorMessage(int statusCode, Map<String, dynamic>? data) {
    final message = data?['message']?.toString();
    if (message != null && message.isNotEmpty) {
      return message;
    }
    switch (statusCode) {
      case 0:
        return 'Unable to connect to PisoCoin controller.';
      case 403:
        return 'Controller session is not owned by this device.';
      case 404:
        return 'PisoCoin API endpoint not found.';
      case 409:
        return 'Controller is currently being used by another machine.';
      default:
        return 'Unable to connect to PisoCoin controller.';
    }
  }

  Future<void> _closeSocketOnly() async {
    final socket = _socket;
    _socket = null;
    if (_connectedTransport == ControllerTransport.socket) {
      _connectedHost = null;
      _resolvedHost = null;
      _connectedPort = null;
      _connectedTransport = null;
    }
    if (socket != null) {
      try {
        await socket.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  Future<bool> _connectByHostLocked(
    String normalizedHost,
    int generation, {
    required int port,
  }) async {
    try {
      final connectionHost = await _resolveConnectionHost(normalizedHost);
      if (generation != _connectionGeneration) {
        print('[CoinWS] stale connection ignored after mDNS resolve');
        return false;
      }

      final url = 'ws://$connectionHost:$port';
      print('[CoinWS] connecting $url');
      final socket = await WebSocket.connect(url).timeout(_controllerTimeout);

      if (generation != _connectionGeneration) {
        print('[CoinWS] stale connection ignored after socket connected');
        try {
          await socket.close().timeout(const Duration(seconds: 2));
        } catch (_) {}
        return false;
      }

      _socket = socket;
      _connectedHost = normalizedHost;
      _resolvedHost = connectionHost;
      _connectedPort = port;
      _connectedTransport = ControllerTransport.socket;
      _latestControllerStatus = null;

      socket.listen(
        _handleIncomingMessage,
        onDone: () => _handleDisconnected(socket),
        onError: (error) => _handleDisconnected(socket, error),
        cancelOnError: true,
      );

      print('[CoinWS] WebSocket connected');
      _messageController.add(<String, dynamic>{
        'type': 'connected',
        'message': connectionHost == normalizedHost
            ? 'Connected to coin controller at $normalizedHost via WebSocket.'
            : 'Connected to coin controller at '
                  '$normalizedHost ($connectionHost) via WebSocket.',
      });
      return true;
    } catch (error) {
      if (generation == _connectionGeneration) {
        _socket = null;
        _connectedHost = null;
        _resolvedHost = null;
        _connectedPort = null;
        _connectedTransport = null;
        _latestControllerStatus = null;
        print('[CoinWS] connection failed host=$normalizedHost error=$error');
        _messageController.add(<String, dynamic>{
          'type': 'error',
          'message':
              'Coin controller connection failed for $normalizedHost: $error',
        });
      } else {
        print('[CoinWS] stale connection failure ignored: $error');
      }
      return false;
    }
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

  Future<String> _resolveConnectionHost(
    String normalizedHost, {
    String serviceType = '_ws._tcp.',
  }) async {
    if (_isIpv4Address(normalizedHost)) {
      return normalizedHost;
    }

    if (Platform.isAndroid && normalizedHost.toLowerCase().endsWith('.local')) {
      print('[CoinCtrl] resolving mDNS host=$normalizedHost type=$serviceType');
      final resolved = await _platformChannel
          .invokeMethod<String>('resolveMdnsHost', <String, dynamic>{
            'hostname': normalizedHost,
            'serviceType': serviceType,
          })
          .timeout(const Duration(seconds: 6));

      final resolvedHost = resolved?.trim();
      if (resolvedHost == null || resolvedHost.isEmpty) {
        throw StateError('Unable to resolve $normalizedHost to a LAN IP.');
      }
      print('[CoinCtrl] mDNS resolved $normalizedHost to $resolvedHost');
      return resolvedHost;
    }

    return normalizedHost;
  }

  bool _isIpv4Address(String host) {
    final parts = host.split('.');
    if (parts.length != 4) {
      return false;
    }
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) {
        return false;
      }
    }
    return true;
  }
}
