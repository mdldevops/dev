import 'dart:async';

import 'package:piso_stream/services/api_service.dart';
import 'package:piso_stream/services/socket_service.dart';

class KioskController {
  final String deviceId;
  final String deviceName;
  final bool sessionAlreadyStarted;

  late SocketService socket;

  int total = 0;
  int minutes = 0;

  bool initialized = false;
  bool isActive = false;
  bool isConnected = false;
  Timer? _sessionStatePoller;

  Function(int total, int minutes)? onUpdate;
  Function()? onSessionStarted;
  Function()? onConnected;
  Function()? onDisconnected;
  Function(String)? onError;

  late final void Function(Map<String, dynamic>) _handleEvent;
  late final void Function() _handleConnected;
  late final void Function() _handleDisconnect;
  late final void Function(String) _handleSocketError;

  KioskController({
    required this.deviceId,
    required this.deviceName,
    this.sessionAlreadyStarted = false,
  });

  void _applySessionState(Map<String, dynamic> data) {
    final status = (data['status'] ?? '').toString();

    if (status == 'started') {
      final nextTotal = (data['total'] as num?)?.toInt() ?? total;
      final nextMinutes = (data['time'] as num?)?.toInt() ?? minutes;
      final addedMinutes = nextMinutes >= minutes
          ? nextMinutes - minutes
          : nextMinutes;
      final wasActive = isActive;

      isActive = true;
      total = nextTotal;
      minutes = nextMinutes;

      if (!wasActive && onSessionStarted != null) {
        onSessionStarted!();
      }

      if (onUpdate != null && addedMinutes > 0) {
        onUpdate!(total, addedMinutes);
      }

      return;
    }

    isActive = false;
  }

  Future<void> _syncSessionState() async {
    final result = await ApiService.getSessionState(deviceId);
    if (result == null) {
      return;
    }

    _applySessionState(result);
  }

  void _startSessionStatePolling() {
    _sessionStatePoller?.cancel();
    // Poll more frequently (every 500ms) to catch coin insertions quickly
    _sessionStatePoller = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      _syncSessionState();
    });
  }

  Future<void> initialize() async {
    print("Initializing kiosk...");

    socket = SocketService(url: ApiService.socketUrl, deviceId: deviceId);

    _handleEvent = (data) {
      final event = data['event'];

      switch (event) {
        case 'coin_inserted':
          if (data['deviceId'] == deviceId) {
            final nextTotal = (data['total'] as num?)?.toInt() ?? total;
            final nextMinutes = (data['time'] as num?)?.toInt() ?? minutes;
            final addedMinutes = nextMinutes >= minutes
                ? nextMinutes - minutes
                : nextMinutes;

            total = nextTotal;
            minutes = nextMinutes;

            print(
              "Coin inserted: total=$total, minutes=$minutes, added=$addedMinutes",
            );

            if (onUpdate != null && addedMinutes > 0) {
              onUpdate!(total, addedMinutes);
            }
          }
          break;

        case 'session_started':
          if (data['deviceId'] == deviceId) {
            isActive = true;

            print("Your session started.");

            if (onSessionStarted != null) {
              onSessionStarted!();
            }
          }
          break;
      }
    };

    _handleDisconnect = () {
      isConnected = false;
      print("Socket disconnected");
      if (onDisconnected != null) {
        onDisconnected!();
      }
    };

    _handleConnected = () {
      isConnected = true;
      print("Socket connected callback");
      if (onConnected != null) {
        onConnected!();
      }
    };

    _handleSocketError = (error) {
      isConnected = false;
      print("Socket error: $error");
      if (onError != null) {
        onError!(error);
      }
    };

    socket.addEventListener(_handleEvent);
    socket.addConnectedListener(_handleConnected);
    socket.addDisconnectedListener(_handleDisconnect);
    socket.addErrorListener(_handleSocketError);

    var socketReady = false;
    try {
      await socket.ensureConnected().timeout(const Duration(seconds: 10));
      isConnected = true;
      socketReady = true;
    } catch (error) {
      print("Socket connection timed out: $error");
      isConnected = false;
      if (onError != null) {
        onError!(
          'Socket connection timed out. The session request will continue while the app keeps reconnecting.',
        );
      }
    }

    if (sessionAlreadyStarted) {
      isActive = true;
      print("Session already reserved before opening the page");

      if (onSessionStarted != null) {
        onSessionStarted!();
      }

      if (!socketReady && onError != null) {
        onError!(
          'Session started, but live coin updates are waiting for the socket to reconnect.',
        );
      }
    } else {
      final result = await ApiService.startSessionWithRetry(deviceId, deviceName);

      if (result == null) {
        print("Failed to start session");
        return;
      }

      final status = (result['status'] ?? '').toString();
      if (status == 'started') {
        isActive = true;
        print("Session started immediately");

        if (onSessionStarted != null) {
          onSessionStarted!();
        }

        if (!socketReady && onError != null) {
          onError!(
            'Session started, but live coin updates are waiting for the socket to reconnect.',
          );
        }
      } else {
        isActive = false;
        final message =
            (result['message'] ?? 'Unable to start coin session.').toString();
        print(message);
        if (onError != null) {
          onError!(message);
        }
      }
    }

    initialized = true;
    _startSessionStatePolling();
    unawaited(_syncSessionState());
  }

  Future<void> endSession() async {
    if (isActive) {
      await ApiService.endSession(deviceId, deviceName: deviceName);
    }

    _sessionStatePoller?.cancel();
    socket.removeEventListener(_handleEvent);
    socket.removeConnectedListener(_handleConnected);
    socket.removeDisconnectedListener(_handleDisconnect);
    socket.removeErrorListener(_handleSocketError);
    initialized = false;
  }

  void dispose() {
    _sessionStatePoller?.cancel();
    socket.removeEventListener(_handleEvent);
    socket.removeConnectedListener(_handleConnected);
    socket.removeDisconnectedListener(_handleDisconnect);
    socket.removeErrorListener(_handleSocketError);
  }
}
