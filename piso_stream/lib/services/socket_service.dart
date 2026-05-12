import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

class SocketService {
  SocketService._internal({
    required this.url,
    required this.deviceId,
  });

  static SocketService? _instance;

  factory SocketService({
    required String url,
    required String deviceId,
  }) {
    if (_instance == null) {
      _instance = SocketService._internal(url: url, deviceId: deviceId);
    } else {
      _instance!._updateConfig(url: url, deviceId: deviceId);
    }

    return _instance!;
  }

  io.Socket? socket;
  String url;
  String deviceId;

  bool _manualDisconnect = false;
  bool _connecting = false;
  bool isConnected = false;
  Completer<void>? _connectionCompleter;
  Timer? _reconnectTimer;

  final Set<void Function(Map<String, dynamic>)> _eventListeners = {};
  final Set<void Function()> _connectedListeners = {};
  final Set<void Function()> _disconnectedListeners = {};
  final Set<void Function(String)> _errorListeners = {};
  final Set<void Function(String)> _broadcastListeners = {};

  void addEventListener(void Function(Map<String, dynamic>) listener) {
    _eventListeners.add(listener);
  }

  void removeEventListener(void Function(Map<String, dynamic>) listener) {
    _eventListeners.remove(listener);
  }

  void addConnectedListener(void Function() listener) {
    _connectedListeners.add(listener);
  }

  void removeConnectedListener(void Function() listener) {
    _connectedListeners.remove(listener);
  }

  void addDisconnectedListener(void Function() listener) {
    _disconnectedListeners.add(listener);
  }

  void removeDisconnectedListener(void Function() listener) {
    _disconnectedListeners.remove(listener);
  }

  void addErrorListener(void Function(String) listener) {
    _errorListeners.add(listener);
  }

  void removeErrorListener(void Function(String) listener) {
    _errorListeners.remove(listener);
  }

  void addBroadcastListener(void Function(String) listener) {
    _broadcastListeners.add(listener);
  }

  void removeBroadcastListener(void Function(String) listener) {
    _broadcastListeners.remove(listener);
  }

  void _updateConfig({
    required String url,
    required String deviceId,
  }) {
    final didChangeDeviceId = this.deviceId != deviceId;
    this.url = url;
    this.deviceId = deviceId;

    if (didChangeDeviceId && socket?.connected == true) {
      socket!.emit('register', this.deviceId);
    }
  }

  void connect() {
    if (_connecting || socket?.connected == true) {
      return;
    }

    _connecting = true;
    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _connectionCompleter ??= Completer<void>();

    socket?.disconnect();
    socket?.dispose();
    socket = null;

    socket = io.io(
      url,
      io.OptionBuilder()
          .setPath('/socket.io')
          .setTimeout(8000)
          .enableForceNew()
          .setTransports(['websocket', 'polling'])
          .disableAutoConnect()
          .build(),
    );

    socket!.connect();

    socket!.onConnect((_) {
      print("Socket connected");
      isConnected = true;
      _connecting = false;
      _reconnectTimer?.cancel();

      socket!.emit('register', deviceId);

      if (!(_connectionCompleter?.isCompleted ?? true)) {
        _connectionCompleter!.complete();
      }

      for (final listener in List<void Function()>.from(_connectedListeners)) {
        listener();
      }
    });

    socket!.on('event', (data) {
      if (data is Map) {
        final payload = Map<String, dynamic>.from(data);
        for (final listener in List<void Function(Map<String, dynamic>)>.from(
          _eventListeners,
        )) {
          listener(payload);
        }
      }
    });

    socket!.on('broadcast', (data) {
      if (data is! Map) {
        return;
      }

      final payload = Map<String, dynamic>.from(data);
      final message = (payload['message'] ?? '').toString().trim();
      if (message.isEmpty) {
        return;
      }

      for (final listener in List<void Function(String)>.from(
        _broadcastListeners,
      )) {
        listener(message);
      }
    });

    socket!.onDisconnect((_) {
      print("Socket disconnected");
      isConnected = false;
      _connecting = false;
      _connectionCompleter = Completer<void>();

      for (final listener in List<void Function()>.from(
        _disconnectedListeners,
      )) {
        listener();
      }

      _scheduleReconnect();
    });

    socket!.onError((err) {
      print("Socket error: $err");
      isConnected = false;
      _connecting = false;

      for (final listener in List<void Function(String)>.from(_errorListeners)) {
        listener(err.toString());
      }

      _scheduleReconnect();
    });

    socket!.onConnectError((err) {
      print("Socket connect error: $err");
      isConnected = false;
      _connecting = false;

      if (!(_connectionCompleter?.isCompleted ?? true)) {
        _connectionCompleter!.completeError(err);
      }

      for (final listener in List<void Function(String)>.from(_errorListeners)) {
        listener('connect_error: $err');
      }

      _connectionCompleter = Completer<void>();
      _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || _reconnectTimer?.isActive == true) {
      return;
    }

    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_manualDisconnect) {
        connect();
      }
    });
  }

  Future<void> ensureConnected() async {
    if (socket?.connected == true) {
      return;
    }

    _connectionCompleter ??= Completer<void>();
    connect();
    await _connectionCompleter!.future;
  }

  void disconnect() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    socket?.disconnect();
    socket?.dispose();
    socket = null;
    isConnected = false;
    _connecting = false;
    _connectionCompleter = null;
    print("Socket fully disposed");
  }
}
