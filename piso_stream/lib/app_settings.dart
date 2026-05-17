import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const String businessNameKey = 'business_name';
  static const String deviceNameKey = 'device_name';
  static const String portraitWallpaperKey = 'portrait_wallpaper_path';
  static const String landscapeWallpaperKey = 'landscape_wallpaper_path';
  static const String allowedAppsKey = 'allowed_app_packages';
  static const String deepFreezeEnabledKey = 'deep_freeze_enabled';
  static const String allowAppUpdatesKey = 'allow_app_updates';
  static const String gracePeriodKey = 'grace_period';
  static const String pendingResetAtKey = 'pending_reset_at';
  static const String currentCustomerKey = 'current_customer_username';
  static const String currentCustomerRoleKey = 'current_customer_role';
  static const String sessionExpiresAtKey = 'session_expires_at';
  static const String customerIdleDeadlineKey = 'customer_idle_deadline';
  static const String kioskDeviceIdKey = 'kiosk_device_id';
  static const String kioskDeviceTokenKey = 'kiosk_device_token';
  static const String localAdminUsernameKey = 'local_admin_username';
  static const String localAdminPasswordKey = 'local_admin_password';
  static const String localAdminRoleKey = 'local_admin_role';
  static const String audioEnabledKey = 'audio_enabled';
  static const String audioPathKey = 'audio_path';
  static const String audioLoopKey = 'audio_loop';
  static const String audioVolumeKey = 'audio_volume';
  static const String coinAudioEnabledKey = 'coin_audio_enabled';
  static const String coinAudioPathKey = 'coin_audio_path';
  static const String lowTimeAlertsEnabledKey = 'low_time_alerts_enabled';
  static const String lowTimeAlertsSoundPathKey = 'low_time_alerts_sound_path';
  static const String lowTimeAlertsVibrationEnabledKey =
      'low_time_alerts_vibration_enabled';
  static const String chargerRelayPinKey = 'charger_relay_pin';
  static const String sessionExpiredPendingKey = 'session_expired_pending';
  static const String nativeCloseDebugKey = 'native_close_debug';
  static const String defaultGracePeriodLabel = '1 minute';

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
