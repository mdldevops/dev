import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';
import 'package:piso_stream/services/standalone_mqtt_service.dart';
import 'package:piso_stream/services/local_db_service.dart';
import 'package:piso_stream/services/api_service.dart';
import 'package:piso_stream/services/socket_service.dart';

class KioskController {
  final String deviceId;
  final String deviceName;
  final bool sessionAlreadyStarted;

  late SocketService socket;
  StreamSubscription<MqttCoinEvent>? _standaloneCoinSubscription;

  int total = 0;
  int minutes = 0;

  bool initialized = false;
  bool isActive = false;
  bool isConnected = false;
  bool _isStandaloneMode = false;
  bool _backgroundServicesEnabled = true;
  Timer? _sessionStatePoller;
  Timer? _standaloneHeartbeatTimer;
  bool _isSyncingSessionState = false;
  String? _lastStandaloneCoinEventId;

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
      final addedMinutes = nextMinutes > minutes ? nextMinutes - minutes : 0;
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
    if (_isSyncingSessionState) {
      return;
    }

    _isSyncingSessionState = true;
    final result = await ApiService.getSessionState(deviceId);
    _isSyncingSessionState = false;

    if (result == null) {
      return;
    }

    _applySessionState(result);
  }

  void _startSessionStatePolling() {
    _sessionStatePoller?.cancel();
    if (!_backgroundServicesEnabled) {
      return;
    }
    // Poll more frequently (every 500ms) to catch coin insertions quickly
    _sessionStatePoller = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      _syncSessionState();
    });
  }

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final setupMode = prefs.getString(AppSettings.setupModeKey);
    _isStandaloneMode = AppSettings.isStandaloneModeValue(setupMode);
    _backgroundServicesEnabled =
        prefs.getBool(AppSettings.backgroundServicesEnabledKey) ?? true;

    if (_isStandaloneMode) {
      await _initializeStandalone();
      return;
    }

    print("Initializing kiosk...");

    socket = SocketService(url: ApiService.socketUrl, deviceId: deviceId);

    _handleEvent = (data) {
      final event = data['event'];

      switch (event) {
        case 'coin_inserted':
          if (data['deviceId'] == deviceId) {
            final nextTotal = (data['total'] as num?)?.toInt() ?? total;
            final nextMinutes = (data['time'] as num?)?.toInt() ?? minutes;
            final addedMinutes = nextMinutes > minutes
                ? nextMinutes - minutes
                : 0;

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

  Future<void> _initializeStandalone() async {
    print("Initializing standalone direct-controller kiosk...");

    final controller = StandaloneMqttService.instance;
    _standaloneCoinSubscription?.cancel();
    _standaloneCoinSubscription = controller.coinEvents.listen((event) async {
      if (event.activeLauncherDeviceId != deviceId) {
        return;
      }

      if (_lastStandaloneCoinEventId == event.eventId) {
        await controller.acknowledgeCoinCredit(
          launcherDeviceId: deviceId,
          launcherDeviceName: deviceName,
          eventId: event.eventId,
        );
        return;
      }
      _lastStandaloneCoinEventId = event.eventId;

      final addedMinutes = await LocalDbService.instance.convertAmountToMinutes(
        event.amount,
      );
      total += event.amount;
      minutes += addedMinutes;

      await LocalDbService.instance.recordStandaloneSale(
        amount: event.amount,
        minutesAdded: addedMinutes,
      );

      if (onUpdate != null && addedMinutes > 0) {
        onUpdate!(total, addedMinutes);
      }

      await controller.acknowledgeCoinCredit(
        launcherDeviceId: deviceId,
        launcherDeviceName: deviceName,
        eventId: event.eventId,
      );
    });

    final connected = await controller.connectBySavedHost();
    if (!connected) {
      isConnected = false;
      initialized = false;
      if (onError != null) {
        onError!(
          'Unable to connect to the standalone coin controller.',
        );
      }
      return;
    }

    if (sessionAlreadyStarted) {
      isConnected = controller.isConnected;
      isActive = true;
      initialized = true;
      _startStandaloneHeartbeat();

      if (onConnected != null && isConnected) {
        onConnected!();
      }
      if (onSessionStarted != null) {
        onSessionStarted!();
      }
      return;
    }

    final openResult = await controller.openSession(
      launcherDeviceId: deviceId,
      launcherDeviceName: deviceName,
    );

    if (!openResult.allowed) {
      isConnected = true;
      initialized = false;
      isActive = false;
      if (onError != null) {
        onError!(openResult.message);
      }
      return;
    }

    isConnected = controller.isConnected;
    isActive = true;
    initialized = true;
    _startStandaloneHeartbeat();

    if (onConnected != null && isConnected) {
      onConnected!();
    }
    if (onSessionStarted != null) {
      onSessionStarted!();
    }
  }

  Future<void> endSession() async {
    if (_isStandaloneMode) {
      _standaloneHeartbeatTimer?.cancel();
      _standaloneHeartbeatTimer = null;
      await StandaloneMqttService.instance.closeSession(
        launcherDeviceId: deviceId,
        launcherDeviceName: deviceName,
      );
      await _standaloneCoinSubscription?.cancel();
      _standaloneCoinSubscription = null;
      initialized = false;
      isActive = false;
      isConnected = false;
      return;
    }

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
    if (_isStandaloneMode) {
      _standaloneHeartbeatTimer?.cancel();
      _standaloneHeartbeatTimer = null;
      unawaited(
        StandaloneMqttService.instance.closeSession(
          launcherDeviceId: deviceId,
          launcherDeviceName: deviceName,
        ),
      );
      _standaloneCoinSubscription?.cancel();
      _standaloneCoinSubscription = null;
      initialized = false;
      isActive = false;
      isConnected = false;
      return;
    }

    _sessionStatePoller?.cancel();
    socket.removeEventListener(_handleEvent);
    socket.removeConnectedListener(_handleConnected);
    socket.removeDisconnectedListener(_handleDisconnect);
    socket.removeErrorListener(_handleSocketError);
    initialized = false;
  }

  void _startStandaloneHeartbeat() {
    _standaloneHeartbeatTimer?.cancel();
    unawaited(
      StandaloneMqttService.instance.ping(
        launcherDeviceId: deviceId,
        launcherDeviceName: deviceName,
      ),
    );
    _standaloneHeartbeatTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) {
        if (!_isStandaloneMode || !isActive) {
          return;
        }
        unawaited(
          StandaloneMqttService.instance.ping(
            launcherDeviceId: deviceId,
            launcherDeviceName: deviceName,
          ),
        );
      },
    );
  }
}
