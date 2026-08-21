import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';
import 'battery_monitor_service.dart';
import 'charging_service.dart';
import 'controller_communication_service.dart';
import 'remote_command_service.dart';
import 'session_service.dart';
import 'socket_service.dart';

class PisoStreamServiceManager {
  PisoStreamServiceManager._();

  static final PisoStreamServiceManager instance = PisoStreamServiceManager._();

  bool _started = false;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    await applySettings();
  }

  Future<void> applySettings() async {
    final prefs = await SharedPreferences.getInstance();
    final backgroundEnabled =
        prefs.getBool(AppSettings.backgroundServicesEnabledKey) ?? true;
    final setupMode =
        prefs.getString(AppSettings.setupModeKey) ?? AppSettings.setupModeServer;

    print(
      '[SERVICE] apply setupMode=$setupMode background=$backgroundEnabled',
    );

    if (!backgroundEnabled) {
      await stop();
      return;
    }

    _started = true;
    await ChargingService.instance.start();
    await BatteryMonitorService.instance.start();
    await SessionService.instance.start();

    if (AppSettings.isStandaloneModeValue(setupMode)) {
      SocketService.disconnectShared();
      await RemoteCommandService.instance.stop();
      await ControllerCommunicationService.instance.start();
      await ControllerCommunicationService.instance.applySettings();
      return;
    }

    await ControllerCommunicationService.instance.stop();
    await RemoteCommandService.instance.start();
  }

  Future<void> stop() async {
    if (!_started) {
      await _stopAllServices();
      return;
    }
    _started = false;
    await _stopAllServices();
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> _stopAllServices() async {
    await BatteryMonitorService.instance.stop();
    await ChargingService.instance.stop();
    await ControllerCommunicationService.instance.stop();
    await SessionService.instance.stop();
    await RemoteCommandService.instance.stop();
    SocketService.disconnectShared();
    print('[SERVICE] all managed services stopped');
  }
}
