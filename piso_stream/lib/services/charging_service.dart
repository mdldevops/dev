import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';
import 'ble_charger_service.dart';
import 'device_identity_service.dart';
import 'shelly_charger_service.dart';

class ChargingService {
  ChargingService._();

  static final ChargingService instance = ChargingService._();

  String? _activeMode;
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
    final enabled = prefs.getBool(AppSettings.chargingControlEnabledKey) ?? true;
    final nextMode =
        prefs.getString(AppSettings.chargerControlModeKey) ??
        AppSettings.chargerControlModeBle;

    if (!enabled) {
      await stop();
      return;
    }

    if (_activeMode != nextMode) {
      await _stopMode(_activeMode);
      _activeMode = nextMode;
    }

    print('[CHARGER] Active mode=$_activeMode');
  }

  Future<void> syncForBattery(int batteryLevel) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(AppSettings.chargingControlEnabledKey) ?? true;
    if (!enabled) {
      return;
    }

    await applySettings();
    final start = prefs.getInt(AppSettings.chargerStartPercentKey) ?? 20;
    final stop = prefs.getInt(AppSettings.chargerStopPercentKey) ?? 80;

    if (_activeMode == AppSettings.chargerControlModeShelly) {
      await ShellyChargerService.instance.syncChargingDecision(
        batteryLevel: batteryLevel,
        startBelowPercent: start,
        stopAtPercent: stop,
        onUrl: prefs.getString(AppSettings.shellyChargeOnUrlKey) ?? '',
        offUrl: prefs.getString(AppSettings.shellyChargeOffUrlKey) ?? '',
        useToggle: prefs.getBool(AppSettings.shellyUseToggleKey) ?? false,
        toggleUrl:
            prefs.getString(AppSettings.shellyToggleUrlKey) ??
            AppSettings.defaultShellyToggleUrl,
        useAuth: prefs.getBool(AppSettings.shellyUseAuthKey) ?? false,
        username: prefs.getString(AppSettings.shellyUsernameKey) ?? '',
        password: prefs.getString(AppSettings.shellyPasswordKey) ?? '',
      );
      return;
    }

    final launcherDeviceId = await DeviceIdentityService.getOrCreateDeviceId();
    await BleChargerService.instance.syncChargingDecision(
      batteryLevel: batteryLevel,
      startBelowPercent: start,
      stopAtPercent: stop,
      relayPin:
          int.tryParse(prefs.getString(AppSettings.chargerRelayPinKey) ?? '26') ??
          26,
      launcherDeviceId: launcherDeviceId,
      launcherDeviceName:
          prefs.getString(AppSettings.deviceNameKey)?.trim().isNotEmpty == true
          ? prefs.getString(AppSettings.deviceNameKey)!.trim()
          : 'Launcher',
    );
  }

  Future<void> stop() async {
    if (!_started && _activeMode == null) {
      return;
    }
    _started = false;
    await _stopMode(_activeMode);
    _activeMode = null;
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> _stopMode(String? mode) async {
    if (mode == AppSettings.chargerControlModeBle) {
      print('[BLE] Stopping');
      await BleChargerService.instance.stopScan();
      await BleChargerService.instance.disconnect();
    }
    if (mode == AppSettings.chargerControlModeShelly) {
      print('[SHELLY] Stopping recurring operations');
      ShellyChargerService.instance.resetChargingDecisionCache();
    }
  }
}
