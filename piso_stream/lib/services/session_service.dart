import 'dart:async';

import 'controller_communication_service.dart';
import 'standalone_mqtt_service.dart';

class SessionService {
  SessionService._();

  static final SessionService instance = SessionService._();

  Timer? _heartbeatTimer;
  String? _launcherDeviceId;
  String? _launcherDeviceName;
  bool _started = false;

  bool get heartbeatRunning => _heartbeatTimer?.isActive == true;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    print('[SESSION] Service ready');
  }

  Future<void> startControllerHeartbeat({
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    if (heartbeatRunning &&
        _launcherDeviceId == launcherDeviceId &&
        _launcherDeviceName == launcherDeviceName) {
      return;
    }

    await stopControllerHeartbeat();
    _launcherDeviceId = launcherDeviceId;
    _launcherDeviceName = launcherDeviceName;
    await ControllerCommunicationService.instance.applySettings();
    print('[SESSION] Heartbeat started');
    unawaited(_sendHeartbeatOnce());
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_sendHeartbeatOnce());
    });
  }

  Future<void> stopControllerHeartbeat() async {
    if (_heartbeatTimer == null) {
      return;
    }
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _launcherDeviceId = null;
    _launcherDeviceName = null;
    print('[SESSION] Heartbeat stopped');
  }

  Future<void> stop() async {
    _started = false;
    await stopControllerHeartbeat();
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> _sendHeartbeatOnce() async {
    final id = _launcherDeviceId;
    final name = _launcherDeviceName;
    if (id == null || id.isEmpty || name == null) {
      return;
    }
    await StandaloneMqttService.instance.ping(
      launcherDeviceId: id,
      launcherDeviceName: name,
    );
  }
}
