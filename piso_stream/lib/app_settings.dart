import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const String setupModeKey = 'setup_mode';
  static const String standaloneControllerIpKey = 'standalone_controller_ip';
  static const String controllerCommunicationModeKey =
      'controller_communication_mode';
  static const String controllerSocketHostKey = 'controller_socket_host';
  static const String controllerSocketPortKey = 'controller_socket_port';
  static const String controllerHttpHostKey = 'controller_http_host';
  static const String controllerHttpPortKey = 'controller_http_port';
  static const String businessNameKey = 'business_name';
  static const String deviceNameKey = 'device_name';
  static const String portraitWallpaperKey = 'portrait_wallpaper_path';
  static const String landscapeWallpaperKey = 'landscape_wallpaper_path';
  static const String allowedAppsKey = 'allowed_app_packages';
  static const String deepFreezeEnabledKey = 'deep_freeze_enabled';
  static const String kioskModeEnabledKey = 'kiosk_mode_enabled';
  static const String backgroundServicesEnabledKey =
      'background_services_enabled';
  static const String allowAppUpdatesKey = 'allow_app_updates';
  static const String gracePeriodKey = 'grace_period';
  static const String pendingResetAtKey = 'pending_reset_at';
  static const String currentCustomerKey = 'current_customer_username';
  static const String currentCustomerRoleKey = 'current_customer_role';
  static const String sessionExpiresAtKey = 'session_expires_at';
  static const String returnToMenuOnHomeKey = 'return_to_menu_on_home';
  static const String returnToMenuSessionExpiresAtKey =
      'return_to_menu_session_expires_at';
  static const String customerIdleDeadlineKey = 'customer_idle_deadline';
  static const String kioskDeviceIdKey = 'kiosk_device_id';
  static const String kioskDeviceTokenKey = 'kiosk_device_token';
  static const String localAdminUsernameKey = 'local_admin_username';
  static const String localAdminPasswordKey = 'local_admin_password';
  static const String localAdminRoleKey = 'local_admin_role';
  static const String localAdminPinKey = 'local_admin_pin';
  static const String audioEnabledKey = 'audio_enabled';
  static const String audioPathKey = 'audio_path';
  static const String audioLoopKey = 'audio_loop';
  static const String audioVolumeKey = 'audio_volume';
  static const String userAudioVolumeKey = 'user_audio_volume';
  static const String coinAudioEnabledKey = 'coin_audio_enabled';
  static const String coinAudioPathKey = 'coin_audio_path';
  static const String lowTimeAlertsEnabledKey = 'low_time_alerts_enabled';
  static const String lowTimeAlertsSoundPathKey = 'low_time_alerts_sound_path';
  static const String lowTimeAlertsVibrationEnabledKey =
      'low_time_alerts_vibration_enabled';
  static const String chargerRelayPinKey = 'charger_relay_pin';
  static const String chargingControlEnabledKey = 'charging_control_enabled';
  static const String chargerControlModeKey = 'charger_control_mode';
  static const String chargerBleDeviceNameKey = 'charger_ble_device_name';
  static const String chargerStartPercentKey = 'charger_start_percent';
  static const String chargerStopPercentKey = 'charger_stop_percent';
  static const String shellyChargeOnUrlKey = 'shelly_charge_on_url';
  static const String shellyChargeOffUrlKey = 'shelly_charge_off_url';
  static const String shellyUseToggleKey = 'shelly_use_toggle';
  static const String shellyToggleUrlKey = 'shelly_toggle_url';
  static const String shellyUseAuthKey = 'shelly_use_auth';
  static const String shellyUsernameKey = 'shelly_username';
  static const String shellyPasswordKey = 'shelly_password';
  static const String sessionExpiredPendingKey = 'session_expired_pending';
  static const String nativeCloseDebugKey = 'native_close_debug';
  static const String defaultGracePeriodLabel = '1 minute';
  static const String defaultStandaloneControllerIp = '192.168.1.3';
  static const int defaultControllerSocketPort = 81;
  static const int defaultControllerHttpPort = 80;
  static const String defaultChargerBleNamePrefix = 'PisoCharger';
  static const String defaultShellyOnUrl =
      'http://192.168.1.4/relay/0?turn=on';
  static const String defaultShellyOffUrl =
      'http://192.168.1.4/relay/0?turn=off';
  static const String defaultShellyToggleUrl =
      'http://192.168.1.4/relay/1?turn=toggle';
  static const String chargerControlModeBle = 'ble';
  static const String chargerControlModeShelly = 'shelly';
  static const String setupModeServer = 'server';
  static const String setupModeStandalone = 'standalone';
  static const String controllerCommunicationModeSocket = 'socket';
  static const String controllerCommunicationModeHttp = 'http';

  static bool isStandaloneModeValue(String? value) {
    return (value ?? '').trim().toLowerCase() == setupModeStandalone;
  }

  static Duration gracePeriodFromLabel(String? label) {
    final match = RegExp(r'(\d+)').firstMatch(label ?? '');
    final minutes = int.tryParse(match?.group(1) ?? '') ?? 1;
    return Duration(minutes: minutes);
  }

  static String gracePeriodLabelFromDuration(Duration duration) {
    final minutes = duration.inMinutes <= 0 ? 1 : duration.inMinutes;
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }

  static String formatCountdown(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 359999);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  static Future<void> clearPendingReset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pendingResetAtKey);
  }
}
