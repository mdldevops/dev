import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_settings.dart';
import 'allowed_apps_page.dart';
import 'kiosk_provisioning_page.dart';
import 'media_wallpaper_background.dart';
import 'standalone_sales_page.dart';
import 'services/admin_pin_service.dart';
import 'services/audio_service.dart';
import 'services/ble_charger_service.dart';
import 'services/device_identity_service.dart';
import 'services/local_db_service.dart';
import 'services/shelly_charger_service.dart';
import 'services/socket_service.dart';
import 'services/standalone_mqtt_service.dart';
import 'services/update_service.dart';
import 'theme_provider.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  static const MethodChannel _platformChannel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );
  static const MethodChannel _updateChannel = MethodChannel(
    'pisostream/app_update',
  );

  // State for toggles and values
  bool isDeepFreezeEnabled = false;
  bool _kioskModeEnabled = true;
  bool _backgroundServicesEnabled = true;
  String _setupMode = AppSettings.setupModeServer;
  String _controllerCommunicationMode =
      AppSettings.controllerCommunicationModeSocket;
  String gracePeriod = AppSettings.defaultGracePeriodLabel;
  final TextEditingController _businessNameController = TextEditingController();
  final TextEditingController _deviceNameController = TextEditingController();
  final TextEditingController _chargerBleNameController = TextEditingController(
    text: AppSettings.defaultChargerBleNamePrefix,
  );
  final TextEditingController _shellyOnUrlController = TextEditingController(
    text: AppSettings.defaultShellyOnUrl,
  );
  final TextEditingController _shellyOffUrlController = TextEditingController(
    text: AppSettings.defaultShellyOffUrl,
  );
  final TextEditingController _shellyToggleUrlController =
      TextEditingController(
        text: AppSettings.defaultShellyToggleUrl,
      );
  final TextEditingController _shellyUsernameController =
      TextEditingController();
  final TextEditingController _shellyPasswordController =
      TextEditingController();
  final TextEditingController _standaloneControllerIpController =
      TextEditingController(
        text: AppSettings.defaultStandaloneControllerIp,
      );
  final TextEditingController _onePesoMinutesController =
      TextEditingController(
    text: '6',
  );
  final TextEditingController _fivePesoMinutesController =
      TextEditingController(
    text: '30',
  );
  final TextEditingController _tenPesoMinutesController =
      TextEditingController(
    text: '60',
  );
  final TextEditingController _twentyPesoMinutesController =
      TextEditingController(
    text: '120',
  );
  double _volume = 0.5;
  double _userVolume = 0.5;
  bool _audioEnabled = false;
  bool _audioLoop = true;
  bool _allowAppUpdates = false;
  String? _audioPath;
  bool _coinAudioEnabled = false;
  String? _coinAudioPath;
  bool _isAudioPreviewing = false;
  bool _isCoinAudioPreviewing = false;
  bool _lowTimeAlertsEnabled = true;
  bool _lowTimeAlertsVibrationEnabled = true;
  String? _lowTimeAlertsSoundPath;
  bool _isLowTimeAlertPreviewing = false;
  String? _portraitWallpaperPath;
  String? _landscapeWallpaperPath;
  bool? _isDeviceOwnerActive;
  bool _isApplyingKioskPolicies = false;
  Timer? _activeSessionTimer;
  String? _activeSessionCustomer;
  String? _activeSessionRole;
  Duration? _activeSessionRemaining;
  bool get _isStandaloneMode =>
      AppSettings.isStandaloneModeValue(_setupMode);
  bool _isBleConnecting = false;
  bool _isBleScanning = false;
  bool _chargingControlEnabled = true;
  String _chargerControlMode = AppSettings.chargerControlModeBle;
  String _chargerBleStatus = 'Not connected';
  bool _shellyUseToggle = false;
  bool _shellyUseAuth = false;
  List<BleChargerScanResult> _chargerScanResults =
      const <BleChargerScanResult>[];
  StreamSubscription<List<BleChargerScanResult>>? _chargerScanSubscription;
  StreamSubscription<String>? _chargerStatusSubscription;
  bool _isCheckingCoinController = false;
  String _coinControllerStatus = 'Not checked';
  bool _timeOverlayPermissionGranted = false;
  StreamSubscription<Map<String, dynamic>>?
      _coinControllerMessageSubscription;
  bool _isCheckingForUpdates = false;
  bool _isInstallingUpdate = false;
  double? _updateDownloadProgress;
  bool _isTestingShellyCommand = false;
  final TextEditingController _chargeStartController = TextEditingController(
    text: '20',
  );
  final TextEditingController _chargeStopController = TextEditingController(
    text: '80',
  );
  String _chargerRelayPin = '26';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindBleStatus();
    _loadSavedSettings();
    _loadDeviceOwnerStatus();
    _loadTimeOverlayPermissionStatus();
    _loadActiveSessionState();
    _startActiveSessionWatcher();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadTimeOverlayPermissionStatus();
      _refreshChargingMonitor();
    }
  }

  Future<void> _refreshChargingMonitor() async {
    try {
      debugPrint('[ChargingMonitor][settings] requesting refresh');
      final result = await _platformChannel.invokeMapMethod<String, dynamic>(
        'refreshChargingMonitor',
        {
          'resetDecisionCache': false,
        },
      );
      debugPrint(
        '[ChargingMonitor][settings] result=${result ?? <String, dynamic>{}}',
      );
    } on PlatformException catch (error) {
      debugPrint('[ChargingMonitor][settings] failed: ${error.message}');
    }
  }

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) {
      return;
    }

    setState(() {
      _businessNameController.text =
          prefs.getString(AppSettings.businessNameKey) ?? '';
      _setupMode =
          prefs.getString(AppSettings.setupModeKey) ??
          AppSettings.setupModeServer;
      _deviceNameController.text =
          prefs.getString(AppSettings.deviceNameKey) ?? '';
      _chargerBleNameController.text =
          prefs.getString(AppSettings.chargerBleDeviceNameKey) ??
          AppSettings.defaultChargerBleNamePrefix;
      _chargerControlMode =
          prefs.getString(AppSettings.chargerControlModeKey) ??
          AppSettings.chargerControlModeBle;
      _chargingControlEnabled =
          prefs.getBool(AppSettings.chargingControlEnabledKey) ?? true;
      _shellyOnUrlController.text =
          prefs.getString(AppSettings.shellyChargeOnUrlKey) ??
          AppSettings.defaultShellyOnUrl;
      _shellyOffUrlController.text =
          prefs.getString(AppSettings.shellyChargeOffUrlKey) ??
          AppSettings.defaultShellyOffUrl;
      _shellyUseToggle =
          prefs.getBool(AppSettings.shellyUseToggleKey) ?? false;
      _shellyToggleUrlController.text =
          prefs.getString(AppSettings.shellyToggleUrlKey) ??
          AppSettings.defaultShellyToggleUrl;
      _shellyUseAuth =
          prefs.getBool(AppSettings.shellyUseAuthKey) ?? false;
      _shellyUsernameController.text =
          prefs.getString(AppSettings.shellyUsernameKey) ?? '';
      _shellyPasswordController.text =
          prefs.getString(AppSettings.shellyPasswordKey) ?? '';
      _standaloneControllerIpController.text =
          prefs.getString(AppSettings.standaloneControllerIpKey) ??
          AppSettings.defaultStandaloneControllerIp;
      _controllerCommunicationMode =
          prefs.getString(AppSettings.controllerCommunicationModeKey) ??
          AppSettings.controllerCommunicationModeSocket;
      _portraitWallpaperPath = _normalizeWallpaperPath(
        prefs.getString(AppSettings.portraitWallpaperKey),
      );
      _landscapeWallpaperPath = _normalizeWallpaperPath(
        prefs.getString(AppSettings.landscapeWallpaperKey),
      );
      isDeepFreezeEnabled =
          prefs.getBool(AppSettings.deepFreezeEnabledKey) ?? false;
      _kioskModeEnabled =
          prefs.getBool(AppSettings.kioskModeEnabledKey) ?? true;
      _backgroundServicesEnabled =
          prefs.getBool(AppSettings.backgroundServicesEnabledKey) ?? true;
      _allowAppUpdates =
          prefs.getBool(AppSettings.allowAppUpdatesKey) ?? false;
      _audioEnabled = prefs.getBool(AppSettings.audioEnabledKey) ?? false;
      _audioLoop = prefs.getBool(AppSettings.audioLoopKey) ?? true;
      _volume = prefs.getDouble(AppSettings.audioVolumeKey) ?? 0.5;
      _userVolume =
          prefs.getDouble(AppSettings.userAudioVolumeKey) ??
          prefs.getDouble(AppSettings.audioVolumeKey) ??
          0.5;
      _audioPath = _normalizeWallpaperPath(
        prefs.getString(AppSettings.audioPathKey),
      );
      _coinAudioEnabled =
          prefs.getBool(AppSettings.coinAudioEnabledKey) ?? false;
      _coinAudioPath = _normalizeWallpaperPath(
        prefs.getString(AppSettings.coinAudioPathKey),
      );
      _lowTimeAlertsEnabled =
          prefs.getBool(AppSettings.lowTimeAlertsEnabledKey) ?? true;
      _lowTimeAlertsVibrationEnabled =
          prefs.getBool(AppSettings.lowTimeAlertsVibrationEnabledKey) ?? true;
      _lowTimeAlertsSoundPath = _normalizeWallpaperPath(
        prefs.getString(AppSettings.lowTimeAlertsSoundPathKey),
      );
      _chargerRelayPin =
          prefs.getString(AppSettings.chargerRelayPinKey) ?? '26';
      _chargeStartController.text =
          (prefs.getInt(AppSettings.chargerStartPercentKey) ?? 20).toString();
      _chargeStopController.text =
          (prefs.getInt(AppSettings.chargerStopPercentKey) ?? 80).toString();
      gracePeriod =
          prefs.getString(AppSettings.gracePeriodKey) ??
          AppSettings.defaultGracePeriodLabel;
    });

    final localConfig = await LocalDbService.instance.getStandaloneCoinConfig();

    if (!mounted) {
      return;
    }

    setState(() {
      _onePesoMinutesController.text = localConfig.onePesoMinutes.toString();
      _fivePesoMinutesController.text = localConfig.fivePesoMinutes.toString();
      _tenPesoMinutesController.text = localConfig.tenPesoMinutes.toString();
      _twentyPesoMinutesController.text = localConfig.twentyPesoMinutes
          .toString();
    });

  }

  Future<void> _loadDeviceOwnerStatus() async {
    try {
      final isActive = await _platformChannel.invokeMethod<bool>(
        'isDeviceOwner',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isDeviceOwnerActive = isActive ?? false;
      });
    } on PlatformException {
      if (!mounted) {
        return;
      }

      setState(() {
        _isDeviceOwnerActive = false;
      });
    }
  }

  Future<void> _loadTimeOverlayPermissionStatus() async {
    try {
      final granted = await _platformChannel.invokeMethod<bool>(
        'canDrawTimeOverlay',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _timeOverlayPermissionGranted = granted ?? false;
      });
    } on PlatformException {
      if (!mounted) {
        return;
      }

      setState(() {
        _timeOverlayPermissionGranted = false;
      });
    }
  }

  Future<int?> _getCurrentBatteryLevel() async {
    try {
      final result = await _platformChannel.invokeMapMethod<String, dynamic>(
        'getSystemStatus',
      );
      return (result?['batteryLevel'] as num?)?.toInt();
    } on PlatformException {
      return null;
    }
  }

  Future<void> _testShellyCommand({
    required String label,
    required String url,
  }) async {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Enter the Shelly $label URL first.')),
      );
      return;
    }

    setState(() {
      _isTestingShellyCommand = true;
    });

    final success = await ShellyChargerService.instance.sendManualCommand(
      url: trimmedUrl,
      useAuth: _shellyUseAuth,
      username: _shellyUsernameController.text.trim(),
      password: _shellyPasswordController.text,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isTestingShellyCommand = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Shelly $label command sent successfully.'
              : 'Shelly $label command failed. Check the URL, WiFi, and auth.',
        ),
      ),
    );
  }

  Future<void> _openTimeOverlayPermissionSettings() async {
    try {
      await _platformChannel.invokeMethod<void>(
        'openTimeOverlayPermissionSettings',
      );
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message ?? 'Unable to open overlay permission settings.',
          ),
        ),
      );
    }
  }

  Future<void> _testTimeOverlay() async {
    try {
      await _platformChannel.invokeMethod<void>('testRemainingTimeOverlay');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Overlay test started for 2 minutes.'),
        ),
      );
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message ?? 'Unable to start time overlay test.',
          ),
        ),
      );
    }
  }

  void _bindBleStatus() {
    _chargerScanSubscription = BleChargerService.instance.scanResults.listen((
      results,
    ) {
      if (!mounted) {
        return;
      }
      setState(() {
        _chargerScanResults = results;
      });
    });

    _chargerStatusSubscription = BleChargerService.instance.statusMessages.listen((
      message,
    ) {
      if (!mounted) {
        return;
      }
      setState(() {
        _chargerBleStatus = message;
        _isBleConnecting = false;
        _isBleScanning = false;
      });
    });

    _coinControllerMessageSubscription = StandaloneMqttService.instance
        .messages
        .listen((message) {
          if (!mounted) {
            return;
          }
          setState(() {
            _isCheckingCoinController = false;
            _coinControllerStatus =
                (message['message'] ?? message['type'] ?? 'Coin controller update')
                    .toString();
          });
        });
  }

  void _startActiveSessionWatcher() {
    _activeSessionTimer?.cancel();
    _activeSessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _loadActiveSessionState();
    });
  }

  Future<void> _loadActiveSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    final customer = prefs.getString(AppSettings.currentCustomerKey)?.trim();
    final role = prefs.getString(AppSettings.currentCustomerRoleKey)?.trim();
    final expiresAtMillis = prefs.getInt(AppSettings.sessionExpiresAtKey);
    final remaining = expiresAtMillis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(expiresAtMillis).difference(
            DateTime.now(),
          );

    if (!mounted) {
      return;
    }

    setState(() {
      _activeSessionCustomer =
          customer == null || customer.isEmpty ? null : customer;
      _activeSessionRole = role == null || role.isEmpty ? null : role;
      _activeSessionRemaining = remaining == null
          ? null
          : (remaining.isNegative ? Duration.zero : remaining);
    });
  }

  String _formatRemaining(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 359999);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }

    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildActiveSessionCard() {
    final hasActiveSession =
        _activeSessionRemaining != null &&
        _activeSessionRemaining! > Duration.zero;

    final title = hasActiveSession ? 'Active Session' : 'No Active Session';
    final subtitle = hasActiveSession
        ? '${_activeSessionCustomer ?? 'Guest Session'} (${_activeSessionRole ?? (_activeSessionCustomer == null ? 'walk-in' : 'customer')})\nRemaining: ${_formatRemaining(_activeSessionRemaining!)}'
        : 'No customer session is currently running on this device.';

    return Card(
      color: const Color(0xFF1A1A1A),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(
          hasActiveSession ? Icons.timer : Icons.timer_off,
          color: hasActiveSession ? Colors.cyanAccent : Colors.white54,
        ),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Colors.white70),
        ),
      ),
    );
  }

  Future<void> _applyKioskPolicies() async {
    setState(() {
      _isApplyingKioskPolicies = true;
    });

    try {
      await _platformChannel.invokeMethod<void>('enterKioskMode');
      await _loadDeviceOwnerStatus();

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isDeviceOwnerActive == true
                ? 'Kiosk policies applied.'
                : 'Kiosk mode requested. Device owner is still not active.',
          ),
        ),
      );
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message ?? 'Unable to apply kiosk policies right now.',
          ),
        ),
      );
    } finally {
      if (!mounted) {
        return;
      }

      setState(() {
        _isApplyingKioskPolicies = false;
      });
    }
  }

  Future<void> _openWifiSettings() async {
    try {
      await _platformChannel.invokeMethod<void>('openWifiSettings');
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message ?? 'Unable to open Wi-Fi settings right now.',
          ),
        ),
      );
    }
  }

  Future<void> _powerOffDevice() async {
    try {
      await _platformChannel.invokeMethod<void>('rebootDevice');
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message ?? 'Unable to power off the device right now.',
          ),
        ),
      );
    }
  }

  Future<void> _rebootDevice() async {
    try {
      await _platformChannel.invokeMethod<void>('rebootDevice');
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Unable to reboot the device right now.'),
        ),
      );
    }
  }

  String? _normalizeWallpaperPath(String? path) {
    if (path == null) {
      return null;
    }

    final trimmed = path.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final previousBackgroundServicesEnabled =
        prefs.getBool(AppSettings.backgroundServicesEnabledKey) ?? true;
    await prefs.setString(
      AppSettings.businessNameKey,
      _businessNameController.text.trim(),
    );
    await prefs.setString(AppSettings.setupModeKey, _setupMode);
    if (_isStandaloneMode) {
      SocketService.disconnectShared();
    }
    await prefs.setString(
      AppSettings.standaloneControllerIpKey,
      _standaloneControllerIpController.text.trim().isEmpty
          ? AppSettings.defaultStandaloneControllerIp
          : _standaloneControllerIpController.text.trim(),
    );
    await prefs.setString(
      AppSettings.controllerCommunicationModeKey,
      _controllerCommunicationMode,
    );
    await prefs.setString(
      AppSettings.deviceNameKey,
      _deviceNameController.text.trim(),
    );
    await prefs.setString(
      AppSettings.chargerBleDeviceNameKey,
      _chargerBleNameController.text.trim(),
    );
    await prefs.setString(
      AppSettings.chargerControlModeKey,
      _chargerControlMode,
    );
    await prefs.setBool(
      AppSettings.chargingControlEnabledKey,
      _chargingControlEnabled,
    );
    await prefs.setString(
      AppSettings.shellyChargeOnUrlKey,
      _shellyOnUrlController.text.trim(),
    );
    await prefs.setString(
      AppSettings.shellyChargeOffUrlKey,
      _shellyOffUrlController.text.trim(),
    );
    await prefs.setBool(
      AppSettings.shellyUseToggleKey,
      _shellyUseToggle,
    );
    await prefs.setString(
      AppSettings.shellyToggleUrlKey,
      _shellyToggleUrlController.text.trim(),
    );
    await prefs.setBool(
      AppSettings.shellyUseAuthKey,
      _shellyUseAuth,
    );
    await prefs.setString(
      AppSettings.shellyUsernameKey,
      _shellyUsernameController.text.trim(),
    );
    await prefs.setString(
      AppSettings.shellyPasswordKey,
      _shellyPasswordController.text,
    );
    await prefs.setString(
      AppSettings.portraitWallpaperKey,
      _portraitWallpaperPath ?? '',
    );
    await prefs.setString(
      AppSettings.landscapeWallpaperKey,
      _landscapeWallpaperPath ?? '',
    );
    await prefs.setBool(
      AppSettings.deepFreezeEnabledKey,
      isDeepFreezeEnabled,
    );
    await prefs.setBool(
      AppSettings.kioskModeEnabledKey,
      _kioskModeEnabled,
    );
    await prefs.setBool(
      AppSettings.backgroundServicesEnabledKey,
      _backgroundServicesEnabled,
    );
    await prefs.setBool(AppSettings.allowAppUpdatesKey, _allowAppUpdates);
    await prefs.setBool(AppSettings.audioEnabledKey, _audioEnabled);
    await prefs.setBool(AppSettings.audioLoopKey, _audioLoop);
    await prefs.setDouble(AppSettings.audioVolumeKey, _volume.clamp(0.0, 1.0));
    await prefs.setDouble(
      AppSettings.userAudioVolumeKey,
      _userVolume.clamp(0.0, 1.0),
    );
    await prefs.setString(AppSettings.audioPathKey, _audioPath ?? '');
    await prefs.setBool(AppSettings.coinAudioEnabledKey, _coinAudioEnabled);
    await prefs.setString(AppSettings.coinAudioPathKey, _coinAudioPath ?? '');
    await prefs.setBool(
      AppSettings.lowTimeAlertsEnabledKey,
      _lowTimeAlertsEnabled,
    );
    await prefs.setBool(
      AppSettings.lowTimeAlertsVibrationEnabledKey,
      _lowTimeAlertsVibrationEnabled,
    );
    await prefs.setString(
      AppSettings.lowTimeAlertsSoundPathKey,
      _lowTimeAlertsSoundPath ?? '',
    );
    await prefs.setString(AppSettings.chargerRelayPinKey, _chargerRelayPin);
    await prefs.setInt(
      AppSettings.chargerStartPercentKey,
      int.tryParse(_chargeStartController.text.trim()) ?? 20,
    );
    await prefs.setInt(
      AppSettings.chargerStopPercentKey,
      int.tryParse(_chargeStopController.text.trim()) ?? 80,
    );
    await prefs.setString(AppSettings.gracePeriodKey, gracePeriod);
    await AudioService().setVolume(_userVolume);
    await LocalDbService.instance.saveStandaloneCoinConfig(
      onePesoMinutes: int.tryParse(_onePesoMinutesController.text.trim()) ?? 6,
      fivePesoMinutes:
          int.tryParse(_fivePesoMinutesController.text.trim()) ?? 30,
      tenPesoMinutes: int.tryParse(_tenPesoMinutesController.text.trim()) ?? 60,
      twentyPesoMinutes:
          int.tryParse(_twentyPesoMinutesController.text.trim()) ?? 120,
    );
    if (!isDeepFreezeEnabled) {
      await prefs.remove(AppSettings.pendingResetAtKey);
    }

    if (_lowTimeAlertsEnabled) {
      try {
        await _platformChannel.invokeMethod<void>('requestNotificationPermission');
      } on PlatformException {
        // Best effort only.
      }
    }

    await _platformChannel.invokeMethod<void>('setKioskModeEnabled', {
      'enabled': _kioskModeEnabled,
    });
    await _platformChannel.invokeMethod<void>('setAppUpdatesAllowed', {
      'allowed': _allowAppUpdates,
    });

    final startBelowPercent =
        int.tryParse(_chargeStartController.text.trim()) ?? 20;
    final stopAtPercent =
        int.tryParse(_chargeStopController.text.trim()) ?? 80;

    if (startBelowPercent >= stopAtPercent) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Start charging threshold must be below stop threshold.'),
        ),
      );
      return;
    }

    bool chargingSaved = false;
    if (!_chargingControlEnabled) {
      BleChargerService.instance.resetChargingDecisionCache();
      ShellyChargerService.instance.resetChargingDecisionCache();
    } else if (_chargerControlMode == AppSettings.chargerControlModeBle) {
      BleChargerService.instance.resetChargingDecisionCache();
      final launcherDeviceId = await DeviceIdentityService.getOrCreateDeviceId();
      chargingSaved = await BleChargerService.instance.pushChargingConfig(
        launcherDeviceId: launcherDeviceId,
        launcherDeviceName: _deviceNameController.text.trim().isEmpty
            ? 'Launcher'
            : _deviceNameController.text.trim(),
        startBelowPercent: startBelowPercent,
        stopAtPercent: stopAtPercent,
        relayPin: int.tryParse(_chargerRelayPin) ?? 26,
      );
    } else {
      ShellyChargerService.instance.resetChargingDecisionCache();
      final batteryLevel = await _getCurrentBatteryLevel();
      if (batteryLevel != null) {
        chargingSaved = await ShellyChargerService.instance.syncChargingDecision(
          batteryLevel: batteryLevel,
          startBelowPercent: startBelowPercent,
          stopAtPercent: stopAtPercent,
          onUrl: _shellyOnUrlController.text.trim(),
          offUrl: _shellyOffUrlController.text.trim(),
          useToggle: _shellyUseToggle,
          toggleUrl: _shellyToggleUrlController.text.trim(),
          useAuth: _shellyUseAuth,
          username: _shellyUsernameController.text.trim(),
          password: _shellyPasswordController.text,
        );
      }
    }

    if (!mounted) {
      return;
    }

    try {
      debugPrint('[ChargingMonitor][settings-save] requesting refresh reset=true');
      final result = await _platformChannel.invokeMapMethod<String, dynamic>(
        'refreshChargingMonitor',
        {
          'resetDecisionCache': true,
        },
      );
      debugPrint(
        '[ChargingMonitor][settings-save] result=${result ?? <String, dynamic>{}}',
      );
    } on PlatformException catch (error) {
      debugPrint('[ChargingMonitor][settings-save] failed: ${error.message}');
    }

    final shouldRestartForBackgroundServices =
        previousBackgroundServicesEnabled != _backgroundServicesEnabled;
    final saveMessage = shouldRestartForBackgroundServices
        ? 'Settings saved. Restarting launcher to apply background service changes.'
        : !_chargingControlEnabled
        ? 'Settings saved. Charging API sending is disabled.'
        : _chargerControlMode == AppSettings.chargerControlModeShelly
        ? chargingSaved
              ? 'Settings saved successfully. Shelly charging was evaluated now.'
              : 'Settings saved successfully.'
        : chargingSaved
        ? 'Settings saved successfully and charger config sent over BLE.'
        : 'Settings saved successfully.';

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(saveMessage),
      ),
    );

    if (shouldRestartForBackgroundServices) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) {
        return;
      }
      await _rebootDevice();
    }
  }

  Future<void> _pickWallpaper(bool isPortrait) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: MediaWallpaperBackground.pickerExtensions,
      allowMultiple: false,
    );

    final path = result?.files.single.path;
    if (path == null || path.trim().isEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final key = isPortrait
        ? AppSettings.portraitWallpaperKey
        : AppSettings.landscapeWallpaperKey;

    await prefs.setString(key, path);

    if (!mounted) {
      return;
    }

    setState(() {
      if (isPortrait) {
        _portraitWallpaperPath = path;
      } else {
        _landscapeWallpaperPath = path;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${isPortrait ? 'Portrait' : 'Landscape'} wallpaper selected.',
        ),
      ),
    );
  }

  Future<void> _clearWallpaper(bool isPortrait) async {
    final prefs = await SharedPreferences.getInstance();
    final key = isPortrait
        ? AppSettings.portraitWallpaperKey
        : AppSettings.landscapeWallpaperKey;

    await prefs.remove(key);

    if (!mounted) {
      return;
    }

    setState(() {
      if (isPortrait) {
        _portraitWallpaperPath = null;
      } else {
        _landscapeWallpaperPath = null;
      }
    });
  }

  Future<void> _scanForChargers() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isBleScanning = true;
      _chargerBleStatus = 'Scanning for BLE charger controllers...';
      _chargerScanResults = const <BleChargerScanResult>[];
    });
    await BleChargerService.instance.startScan(
      namePrefix: AppSettings.defaultChargerBleNamePrefix,
    );
  }

  Future<void> _connectToSavedCharger() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isBleConnecting = true;
      _chargerBleStatus = 'Connecting to charger controller...';
    });
    final connected = await BleChargerService.instance.connectByName(
      _chargerBleNameController.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isBleConnecting = false;
      if (connected) {
        _chargerBleStatus =
            'Connected to ${BleChargerService.instance.connectedDeviceName ?? _chargerBleNameController.text.trim()}.';
      }
    });
  }

  Future<void> _disconnectCharger() async {
    await BleChargerService.instance.disconnect();
    if (!mounted) {
      return;
    }
    setState(() {
      _chargerBleStatus = 'Disconnected from charger controller.';
    });
  }

  Future<void> _checkCoinControllerConnection() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isCheckingCoinController = true;
      _coinControllerStatus = 'Checking coin controller...';
    });

    try {
      final connected = await StandaloneMqttService.instance.connectByHost(
        _standaloneControllerIpController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      final savedAddress =
          StandaloneMqttService.instance.connectedHost ??
          _standaloneControllerIpController.text.trim();
      final resolvedAddress = StandaloneMqttService.instance.resolvedHost;
      setState(() {
        _coinControllerStatus = connected
            ? resolvedAddress == null || resolvedAddress == savedAddress
                  ? 'Connected to coin controller at $savedAddress'
                  : 'Connected to coin controller at '
                        '$savedAddress ($resolvedAddress)'
            : 'Unable to connect to the coin controller';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _coinControllerStatus = 'Connection failed: $error';
      });
    } finally {
      if (!mounted) {
        return;
      }
      setState(() {
        _isCheckingCoinController = false;
      });
    }
  }

  Future<void> _openStandaloneSalesPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const StandaloneSalesPage(),
      ),
    );
  }

  Future<void> _pickAudioFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg'],
      allowMultiple: false,
    );

    final path = result?.files.single.path?.trim();
    if (path == null || path.isEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppSettings.audioPathKey, path);

    if (!mounted) {
      return;
    }

    setState(() {
      _audioPath = path;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Audio file selected.')),
    );
  }

  Future<void> _pickCoinAudioFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg'],
      allowMultiple: false,
    );

    final path = result?.files.single.path?.trim();
    if (path == null || path.isEmpty) {
      return;
    }

    final durationMs = await AudioService().getAudioDurationMs(path);
    if (durationMs == null) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to read the audio duration.')),
      );
      return;
    }

    if (durationMs > 5000) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Coin/time audio must be 5 seconds or shorter.'),
        ),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppSettings.coinAudioPathKey, path);

    if (!mounted) {
      return;
    }

    setState(() {
      _coinAudioPath = path;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Coin/time audio selected.')),
    );
  }

  Future<void> _pickLowTimeAlertAudioFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg'],
      allowMultiple: false,
    );

    final path = result?.files.single.path?.trim();
    if (path == null || path.isEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppSettings.lowTimeAlertsSoundPathKey, path);

    if (!mounted) {
      return;
    }

    setState(() {
      _lowTimeAlertsSoundPath = path;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Low-time alert sound selected.')),
    );
  }

  Future<void> _toggleAudioPreview() async {
    final audioService = AudioService();

    if (_isAudioPreviewing) {
      await audioService.stopAudio();
      if (!mounted) {
        return;
      }
      setState(() {
        _isAudioPreviewing = false;
      });
      return;
    }

    if (_audioPath == null || _audioPath!.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select an audio file first.')),
      );
      return;
    }

    try {
      await audioService.playAudio(
        audioPath: _audioPath!,
        loop: _audioLoop,
        volume: _userVolume,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isAudioPreviewing = true;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to preview audio: $error')),
      );
    }
  }

  Future<void> _toggleCoinAudioPreview() async {
    final audioService = AudioService();

    if (_isCoinAudioPreviewing) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isCoinAudioPreviewing = false;
      });
      return;
    }

    if (_coinAudioPath == null || _coinAudioPath!.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a coin/time audio file first.')),
      );
      return;
    }

    try {
      await audioService.playEffectAudio(
        audioPath: _coinAudioPath!,
        volume: _userVolume,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isCoinAudioPreviewing = true;
      });

      Future<void>.delayed(const Duration(seconds: 6), () {
        if (!mounted) {
          return;
        }
        setState(() {
          _isCoinAudioPreviewing = false;
        });
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to preview coin/time audio: $error')),
      );
    }
  }

  Future<void> _toggleLowTimeAlertPreview() async {
    final audioService = AudioService();

    if (_isLowTimeAlertPreviewing) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLowTimeAlertPreviewing = false;
      });
      return;
    }

    if (_lowTimeAlertsSoundPath == null || _lowTimeAlertsSoundPath!.isEmpty) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select an alert sound first.')),
      );
      return;
    }

    try {
      await audioService.playEffectAudio(
        audioPath: _lowTimeAlertsSoundPath!,
        volume: _userVolume,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isLowTimeAlertPreviewing = true;
      });

      Future<void>.delayed(const Duration(seconds: 3), () {
        if (!mounted) {
          return;
        }

        setState(() {
          _isLowTimeAlertPreviewing = false;
        });
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to preview alert sound: $error')),
      );
    }
  }

  Future<void> _checkForUpdates() async {
    if (_isCheckingForUpdates || _isInstallingUpdate) {
      return;
    }

    setState(() {
      _isCheckingForUpdates = true;
    });

    _showBlockingProgressDialog(
      title: 'Checking for Updates',
      message: 'Connecting to GitHub...',
    );

    try {
      final updateInfo = await UpdateService.instance.checkForUpdate();
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();

      if (!updateInfo.updateAvailable) {
        await _showNoUpdateDialog(updateInfo);
        return;
      }

      await _showUpdateAvailableDialog(updateInfo);
    } on UpdateServiceException catch (error) {
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();
      await _showUpdateErrorDialog(error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();
      await _showUpdateErrorDialog(
        'Unable to check for updates. Please connect to the Internet and try again.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingForUpdates = false;
        });
      } else {
        _isCheckingForUpdates = false;
      }
    }
  }

  void _showBlockingProgressDialog({
    required String title,
    required String message,
    double? progress,
  }) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              if (progress == null)
                const LinearProgressIndicator()
              else ...[
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 8),
                Text(
                  '${(progress * 100).round()}%',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _showNoUpdateDialog(AppUpdateInfo updateInfo) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Text(
            'No Update Available',
            style: TextStyle(color: Colors.white),
          ),
          content: Text(
            'You are using the latest version.\n\nCurrent version: ${updateInfo.currentVersion}',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showUpdateAvailableDialog(AppUpdateInfo updateInfo) async {
    final shouldUpdate = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Text(
            'Update Available',
            style: TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Text(
              'Current version: ${updateInfo.currentVersion}\n'
              'New version: ${updateInfo.latestVersion}\n\n'
              'Release Notes:\n'
              '${updateInfo.releaseNotes.isEmpty ? 'No release notes provided.' : updateInfo.releaseNotes}',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('LATER'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('UPDATE'),
            ),
          ],
        );
      },
    );

    if (shouldUpdate == true) {
      await _downloadAndInstallUpdate(updateInfo);
    }
  }

  Future<void> _downloadAndInstallUpdate(AppUpdateInfo updateInfo) async {
    if (_isInstallingUpdate) {
      return;
    }

    final downloadProgress = ValueNotifier<double?>(null);
    setState(() {
      _isInstallingUpdate = true;
      _updateDownloadProgress = null;
    });

    _showDownloadProgressDialog(downloadProgress);

    try {
      final apkFile = await UpdateService.instance.downloadApk(
        updateInfo,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          _updateDownloadProgress = progress.fraction;
          downloadProgress.value = progress.fraction;
        },
      );

      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();
      _showBlockingProgressDialog(
        title: 'Installing Update',
        message: 'Preparing the device for update...',
      );

      await _platformChannel.invokeMethod<void>('prepareForAppUpdate');

      final result = await _updateChannel.invokeMapMethod<String, dynamic>(
        'installApk',
        <String, dynamic>{'apkPath': apkFile.path},
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();

      final status = (result?['status'] ?? '').toString();
      if (status == 'SUCCESS') {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121212),
              title: const Text(
                'Update Installed',
                style: TextStyle(color: Colors.white),
              ),
              content: const Text(
                'The update was installed successfully. The launcher will restart.',
                style: TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      } else if (status == 'MANUAL_INSTALL_STARTED') {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121212),
              title: const Text(
                'Approve Update',
                style: TextStyle(color: Colors.white),
              ),
              content: Text(
                (result?['message'] ??
                        'Android package installer opened. Approve the update to continue.')
                    .toString(),
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      } else {
        await _showUpdateErrorDialog(
          (result?['message'] ?? 'Unable to install the update.').toString(),
        );
      }
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();
      await _showUpdateErrorDialog(
        error.message ?? 'Unable to install the update.',
      );
    } on UpdateServiceException catch (error) {
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();
      await _showUpdateErrorDialog(error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();
      await _showUpdateErrorDialog('Unable to download the update.');
    } finally {
      downloadProgress.dispose();
      if (mounted) {
        setState(() {
          _isInstallingUpdate = false;
          _updateDownloadProgress = null;
        });
      } else {
        _isInstallingUpdate = false;
        _updateDownloadProgress = null;
      }
    }
  }

  void _showDownloadProgressDialog(ValueNotifier<double?> progressNotifier) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return ValueListenableBuilder<double?>(
          valueListenable: progressNotifier,
          builder: (context, progress, _) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121212),
              title: const Text(
                'Downloading Update',
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 12),
                  Text(
                    progress == null
                        ? 'Downloading...'
                        : '${(progress * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showUpdateErrorDialog(String message) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Text(
            'Update Failed',
            style: TextStyle(color: Colors.white),
          ),
          content: Text(message, style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showChangeAdminPinDialog() async {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    try {
      final shouldSave = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF121212),
            title: const Text(
              'Change Admin PIN',
              style: TextStyle(color: Colors.white),
            ),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: currentController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Current PIN',
                      labelStyle: TextStyle(color: Colors.white70),
                      counterText: '',
                    ),
                    validator: (value) {
                      if ((value ?? '').trim().length != 6) {
                        return 'Enter the current 6-digit PIN.';
                      }
                      return null;
                    },
                  ),
                  TextFormField(
                    controller: newController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'New PIN',
                      labelStyle: TextStyle(color: Colors.white70),
                      counterText: '',
                    ),
                    validator: (value) {
                      if ((value ?? '').trim().length != 6) {
                        return 'PIN must be 6 digits.';
                      }
                      return null;
                    },
                  ),
                  TextFormField(
                    controller: confirmController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Confirm New PIN',
                      labelStyle: TextStyle(color: Colors.white70),
                      counterText: '',
                    ),
                    validator: (value) {
                      if (value != newController.text) {
                        return 'PINs do not match.';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (!(formKey.currentState?.validate() ?? false)) {
                    return;
                  }

                  Navigator.of(dialogContext).pop(true);
                },
                child: const Text('Update'),
              ),
            ],
          );
        },
      );

      if (shouldSave != true) {
        return;
      }

      await AdminPinService.updatePin(
        currentPin: currentController.text.trim(),
        newPin: newController.text.trim(),
        useLocalOnly: _isStandaloneMode,
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Admin PIN updated.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      currentController.dispose();
      newController.dispose();
      confirmController.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activeSessionTimer?.cancel();
    AudioService().stopAudio();
    _businessNameController.dispose();
    _deviceNameController.dispose();
    _chargerBleNameController.dispose();
    _shellyOnUrlController.dispose();
    _shellyOffUrlController.dispose();
    _shellyToggleUrlController.dispose();
    _shellyUsernameController.dispose();
    _shellyPasswordController.dispose();
    _standaloneControllerIpController.dispose();
    _onePesoMinutesController.dispose();
    _fivePesoMinutesController.dispose();
    _tenPesoMinutesController.dispose();
    _twentyPesoMinutesController.dispose();
    _chargerScanSubscription?.cancel();
    _chargerStatusSubscription?.cancel();
    _coinControllerMessageSubscription?.cancel();
    _chargeStartController.dispose();
    _chargeStopController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return Scaffold(
          backgroundColor: themeProvider.currentTheme[0],
          appBar: AppBar(
            backgroundColor: themeProvider.currentTheme[1].withValues(
              alpha: 0.8,
            ),
            title: const Text("Settings"),
            actions: [
              IconButton(icon: const Icon(Icons.logout), onPressed: () {}),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildActiveSessionCard(),
                    _buildTile(
                      "Sales",
                      "View standalone totals and coin insert logs",
                      Icons.receipt_long,
                      onTap: _openStandaloneSalesPage,
                    ),
                    _buildTile(
                      "Change Admin PIN",
                      "Update your admin access PIN",
                      Icons.lock,
                      onTap: _showChangeAdminPinDialog,
                    ),
                    _buildTile(
                      "Check for Updates",
                      "Manually check GitHub Releases for a new APK",
                      Icons.system_update,
                      onTap: _isCheckingForUpdates || _isInstallingUpdate
                          ? null
                          : _checkForUpdates,
                      trailing: _isCheckingForUpdates || _isInstallingUpdate
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : null,
                    ),
                    _buildTile(
                      "Power Off",
                      "Turn off the device",
                      Icons.power_settings_new,
                      onTap: _powerOffDevice,
                    ),
                    _buildTile(
                      "Reboot Device",
                      "Restart the whole device",
                      Icons.power_settings_new,
                      onTap: _rebootDevice,
                    ),
                    _buildKioskSection(),
                    _buildTile(
                      "Allowed Apps",
                      "Manage whitelisted applications",
                      Icons.apps,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AllowedAppsPage(),
                          ),
                        );
                      },
                    ),
                    ExpansionTile(
                      leading: const Icon(Icons.router, color: Colors.cyanAccent),
                      title: const Text(
                        "Setup Mode",
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        _isStandaloneMode
                            ? _controllerCommunicationMode ==
                                      AppSettings.controllerCommunicationModeHttp
                                  ? "Launcher <-> coin_controller direct HTTP"
                                  : "Launcher <-> coin_controller direct Socket"
                            : "Launcher <-> Node.js <-> piso kiosk",
                        style: const TextStyle(color: Colors.white70),
                      ),
                      children: [
                        RadioListTile<String>(
                          value: AppSettings.setupModeServer,
                          groupValue: _setupMode,
                          activeColor: Colors.tealAccent,
                          title: const Text(
                            'Server',
                            style: TextStyle(color: Colors.white),
                          ),
                          subtitle: const Text(
                            'Keep the current APP-NODEJS-PISOKIOSK flow.',
                            style: TextStyle(color: Colors.white70),
                          ),
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _setupMode = value;
                            });
                          },
                        ),
                        RadioListTile<String>(
                          value: AppSettings.setupModeStandalone,
                          groupValue: _setupMode,
                          activeColor: Colors.tealAccent,
                          title: const Text(
                            'Standalone',
                            style: TextStyle(color: Colors.white),
                          ),
                          subtitle: const Text(
                            'Connect directly to coin_controller.',
                            style: TextStyle(color: Colors.white70),
                          ),
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _setupMode = value;
                            });
                          },
                        ),
                        if (_isStandaloneMode) ...[
                          const ListTile(
                            title: Text(
                              'coin_controller communication',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              'Choose Socket for the old firmware or HTTP for the REST firmware.',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                          RadioListTile<String>(
                            value: AppSettings.controllerCommunicationModeSocket,
                            groupValue: _controllerCommunicationMode,
                            activeColor: Colors.tealAccent,
                            title: const Text(
                              'Socket',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Use the existing direct WebSocket controller flow.',
                              style: TextStyle(color: Colors.white70),
                            ),
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() {
                                _controllerCommunicationMode = value;
                              });
                            },
                          ),
                          RadioListTile<String>(
                            value: AppSettings.controllerCommunicationModeHttp,
                            groupValue: _controllerCommunicationMode,
                            activeColor: Colors.tealAccent,
                            title: const Text(
                              'HTTP',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Use the ESP32 REST API on port 80.',
                              style: TextStyle(color: Colors.white70),
                            ),
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() {
                                _controllerCommunicationMode = value;
                              });
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: TextFormField(
                              controller: _standaloneControllerIpController,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                labelText: 'ESP32 Address',
                                labelStyle: TextStyle(color: Colors.white70),
                                helperText:
                                    'Socket: 192.168.1.100. HTTP: pisocoin-A99B20.local or IP',
                                helperStyle: TextStyle(color: Colors.white54),
                              ),
                            ),
                          ),
                          ListTile(
                            leading: Icon(
                              StandaloneMqttService.instance.isConnected
                                  ? Icons.check_circle
                                  : Icons.error_outline,
                              color: StandaloneMqttService.instance.isConnected
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent,
                            ),
                            title: const Text(
                              'Coin Controller Status',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              _coinControllerStatus,
                              style: const TextStyle(color: Colors.white70),
                            ),
                            trailing: Wrap(
                              spacing: 8,
                              children: [
                                OutlinedButton(
                                  onPressed: _isCheckingCoinController
                                      ? null
                                      : _checkCoinControllerConnection,
                                  child: Text(
                                    _isCheckingCoinController
                                        ? 'Checking...'
                                        : 'Check',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        '1 Peso',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: TextFormField(
                                        controller: _onePesoMinutesController,
                                        keyboardType: TextInputType.number,
                                        style: const TextStyle(color: Colors.white),
                                        decoration: const InputDecoration(
                                          labelText: 'Minutes',
                                          labelStyle: TextStyle(color: Colors.white70),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        '5 Peso',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: TextFormField(
                                        controller: _fivePesoMinutesController,
                                        keyboardType: TextInputType.number,
                                        style: const TextStyle(color: Colors.white),
                                        decoration: const InputDecoration(
                                          labelText: 'Minutes',
                                          labelStyle: TextStyle(color: Colors.white70),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        '10 Peso',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: TextFormField(
                                        controller: _tenPesoMinutesController,
                                        keyboardType: TextInputType.number,
                                        style: const TextStyle(color: Colors.white),
                                        decoration: const InputDecoration(
                                          labelText: 'Minutes',
                                          labelStyle: TextStyle(color: Colors.white70),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        '20 Peso',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: TextFormField(
                                        controller: _twentyPesoMinutesController,
                                        keyboardType: TextInputType.number,
                                        style: const TextStyle(color: Colors.white),
                                        decoration: const InputDecoration(
                                          labelText: 'Minutes',
                                          labelStyle: TextStyle(color: Colors.white70),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    ExpansionTile(
                      leading: const Icon(Icons.battery_charging_full, color: Colors.lightGreenAccent),
                      title: const Text(
                        "Charging Control",
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        _chargerControlMode == AppSettings.chargerControlModeShelly
                            ? (_shellyUseAuth
                                  ? 'Shelly HTTP control with authorization.'
                                  : 'Shelly HTTP control without authorization.')
                            : _chargerBleStatus,
                        style: TextStyle(
                          color:
                              _chargerControlMode == AppSettings.chargerControlModeShelly
                              ? Colors.white70
                              : BleChargerService.instance.isConnected
                              ? Colors.greenAccent
                              : Colors.white70,
                        ),
                      ),
                      children: [
                        SwitchListTile(
                          title: Text(
                            _chargingControlEnabled
                                ? 'Charging API Enabled'
                                : 'Charging API Disabled',
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: const Text(
                            'When disabled, the launcher will not send BLE or Shelly charging commands.',
                            style: TextStyle(color: Colors.white70),
                          ),
                          value: _chargingControlEnabled,
                          onChanged: (value) {
                            setState(() {
                              _chargingControlEnabled = value;
                            });
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: DropdownButtonFormField<String>(
                            value: _chargerControlMode,
                            dropdownColor: const Color(0xFF1A1A1A),
                            style: const TextStyle(color: Colors.white),
                            iconEnabledColor: Colors.white70,
                            decoration: const InputDecoration(
                              labelText: 'Charging Controller',
                              labelStyle: TextStyle(color: Colors.white70),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: AppSettings.chargerControlModeBle,
                                child: Text(
                                  'BLE Charger Controller',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                              DropdownMenuItem(
                                value: AppSettings.chargerControlModeShelly,
                                child: Text(
                                  'Shelly HTTP',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                            ],
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() {
                                _chargerControlMode = value;
                              });
                            },
                          ),
                        ),
                        if (_chargerControlMode == AppSettings.chargerControlModeBle)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: TextFormField(
                              controller: _chargerBleNameController,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                labelText: 'Charger BLE Name',
                                labelStyle: TextStyle(color: Colors.white70),
                                helperText:
                                    'Use the unique advertised charger Bluetooth name.',
                                helperStyle: TextStyle(color: Colors.white54),
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: TextFormField(
                            controller: _chargeStartController,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Start charging at or below (%)',
                              labelStyle: TextStyle(color: Colors.white70),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: TextFormField(
                            controller: _chargeStopController,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Stop charging at or above (%)',
                              labelStyle: TextStyle(color: Colors.white70),
                            ),
                          ),
                        ),
                        if (_chargerControlMode == AppSettings.chargerControlModeShelly)
                          SwitchListTile(
                            title: const Text(
                              'Use Shelly Toggle Command',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'When enabled, ON/OFF URLs are disabled and the toggle URL is used instead.',
                              style: TextStyle(color: Colors.white70),
                            ),
                            value: _shellyUseToggle,
                            onChanged: (value) {
                              setState(() {
                                _shellyUseToggle = value;
                              });
                            },
                          ),
                        if (_chargerControlMode == AppSettings.chargerControlModeShelly &&
                            _shellyUseToggle)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: TextFormField(
                              controller: _shellyToggleUrlController,
                              keyboardType: TextInputType.url,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                labelText: 'Shelly Toggle Command URL',
                                labelStyle: TextStyle(color: Colors.white70),
                                helperText:
                                    'Example: http://192.168.1.4/relay/1?turn=toggle',
                                helperStyle: TextStyle(color: Colors.white54),
                              ),
                            ),
                          ),
                        if (_chargerControlMode == AppSettings.chargerControlModeShelly)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: TextFormField(
                              controller: _shellyOnUrlController,
                              enabled: !_shellyUseToggle,
                              keyboardType: TextInputType.url,
                              style: TextStyle(
                                color: _shellyUseToggle
                                    ? Colors.white38
                                    : Colors.white,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Shelly ON Command URL',
                                labelStyle: TextStyle(color: Colors.white70),
                                helperText:
                                    'Example: http://192.168.1.5/relay/0?turn=on',
                                helperStyle: TextStyle(color: Colors.white54),
                              ),
                            ),
                          ),
                        if (_chargerControlMode == AppSettings.chargerControlModeShelly)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: TextFormField(
                              controller: _shellyOffUrlController,
                              enabled: !_shellyUseToggle,
                              keyboardType: TextInputType.url,
                              style: TextStyle(
                                color: _shellyUseToggle
                                    ? Colors.white38
                                    : Colors.white,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Shelly OFF Command URL',
                                labelStyle: TextStyle(color: Colors.white70),
                                helperText:
                                    'Example: http://192.168.1.5/relay/0?turn=off',
                                helperStyle: TextStyle(color: Colors.white54),
                              ),
                            ),
                          ),
                        if (_chargerControlMode == AppSettings.chargerControlModeShelly)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _isTestingShellyCommand
                                        ? null
                                        : () => _testShellyCommand(
                                              label: 'ON',
                                              url: _shellyOnUrlController.text,
                                            ),
                                    icon: _isTestingShellyCommand
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.power_settings_new),
                                    label: const Text('Test ON'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _isTestingShellyCommand
                                        ? null
                                        : () => _testShellyCommand(
                                              label: 'OFF',
                                              url: _shellyOffUrlController.text,
                                            ),
                                    icon: const Icon(Icons.power_off),
                                    label: const Text('Test OFF'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (_chargerControlMode == AppSettings.chargerControlModeShelly)
                          SwitchListTile(
                            title: const Text(
                              'Authorization',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Enable when Shelly requires a username and password.',
                              style: TextStyle(color: Colors.white70),
                            ),
                            value: _shellyUseAuth,
                            onChanged: (value) {
                              setState(() {
                                _shellyUseAuth = value;
                              });
                            },
                          ),
                        if (_chargerControlMode == AppSettings.chargerControlModeShelly &&
                            _shellyUseAuth)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: TextFormField(
                              controller: _shellyUsernameController,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                labelText: 'Username',
                                labelStyle: TextStyle(color: Colors.white70),
                              ),
                            ),
                          ),
                        if (_chargerControlMode == AppSettings.chargerControlModeShelly &&
                            _shellyUseAuth)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: TextFormField(
                              controller: _shellyPasswordController,
                              obscureText: true,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                labelText: 'Password',
                                labelStyle: TextStyle(color: Colors.white70),
                              ),
                            ),
                          ),
                        if (_chargerControlMode == AppSettings.chargerControlModeBle)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _isBleScanning ? null : _scanForChargers,
                                    child: Text(
                                      _isBleScanning ? 'Scanning...' : 'Scan',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _isBleConnecting
                                        ? null
                                        : _connectToSavedCharger,
                                    child: Text(
                                      _isBleConnecting ? 'Connecting...' : 'Connect',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: BleChargerService.instance.isConnected
                                        ? _disconnectCharger
                                        : null,
                                    child: const Text('Disconnect'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (_chargerControlMode == AppSettings.chargerControlModeBle &&
                            _chargerScanResults.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                            child: Column(
                              children: _chargerScanResults
                                  .map(
                                    (device) => ListTile(
                                      dense: true,
                                      leading: const Icon(
                                        Icons.bluetooth,
                                        color: Colors.cyanAccent,
                                      ),
                                      title: Text(
                                        device.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                      subtitle: Text(
                                        'RSSI ${device.rssi} • ${device.remoteId}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                      trailing: TextButton(
                                        onPressed: () {
                                          setState(() {
                                            _chargerBleNameController.text =
                                                device.name;
                                          });
                                          _connectToSavedCharger();
                                        },
                                        child: const Text('Use'),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                      ],
                    ),
                    ExpansionTile(
                      leading: const Icon(Icons.ac_unit, color: Colors.blue),
                      title: const Text(
                        "Deep Freeze",
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        "Clear app data after each session.",
                        style: TextStyle(color: Colors.white70),
                      ),
                      children: [
                        SwitchListTile(
                          title: Text(
                            isDeepFreezeEnabled ? "Enabled" : "Disabled",
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: const Text(
                            "Clear data after each session",
                            style: TextStyle(color: Colors.white70),
                          ),
                          value: isDeepFreezeEnabled,
                          onChanged: (val) =>
                              setState(() => isDeepFreezeEnabled = val),
                        ),
                        SwitchListTile(
                          title: Text(
                            _allowAppUpdates
                                ? "Admin App Installs Enabled"
                                : "Admin App Installs Disabled",
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: const Text(
                            "When enabled, only admin sessions can install or update apps. Customers are always blocked.",
                            style: TextStyle(color: Colors.white70),
                          ),
                          value: _allowAppUpdates,
                          onChanged: (val) =>
                              setState(() => _allowAppUpdates = val),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: DropdownButtonFormField<String>(
                            dropdownColor: const Color(0xFF1A1A1A),
                            style: const TextStyle(color: Colors.white),
                            iconEnabledColor: Colors.white70,
                            decoration: InputDecoration(
                              labelText: "Grace Period",
                              labelStyle: const TextStyle(
                                color: Colors.white70,
                              ),
                              filled: true,
                              fillColor: Colors.black.withValues(alpha: 0.22),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                  color: Colors.white12,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                  color: Colors.cyanAccent,
                                ),
                              ),
                            ),
                            initialValue: gracePeriod,
                            items:
                                [
                                      "1 minute",
                                      "2 minutes",
                                      "3 minutes",
                                      "4 minutes",
                                      "5 minutes",
                                    ]
                                    .map(
                                      (label) => DropdownMenuItem(
                                        value: label,
                                        child: Text(
                                          label,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                            onChanged: (val) =>
                                setState(() => gracePeriod = val!),
                          ),
                        ),
                      ],
                    ),
                    _buildTile(
                      "Wifi",
                      "Open Wi-Fi settings for admin connection changes",
                      Icons.wifi,
                      onTap: _openWifiSettings,
                    ),
                    _buildTile(
                      "Time Overlay",
                      "Show the remaining session time above other apps.",
                      Icons.timer_outlined,
                      onTap: _openTimeOverlayPermissionSettings,
                      trailing: Text(
                        _timeOverlayPermissionGranted
                            ? 'Enabled'
                            : 'Not Enabled',
                        style: TextStyle(
                          color: _timeOverlayPermissionGranted
                              ? Colors.lightGreenAccent
                              : Colors.redAccent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _buildTile(
                      "Test Time Overlay",
                      "Show a 2-minute overlay now to verify permission and placement.",
                      Icons.play_circle_outline,
                      onTap: _testTimeOverlay,
                    ),
                    SwitchListTile(
                      title: const Text(
                        "Kiosk Mode",
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        _kioskModeEnabled
                            ? "Enabled. Launcher policies and kiosk restrictions stay active."
                            : "Disabled. App unpins and Play Store installs are allowed after save.",
                        style: const TextStyle(color: Colors.white70),
                      ),
                      value: _kioskModeEnabled,
                      onChanged: (val) {
                        setState(() {
                          _kioskModeEnabled = val;
                        });
                      },
                    ),
                    SwitchListTile(
                      title: const Text(
                        "Background Services",
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        "Turn off overnight to stop launcher sync, polling, and keep-alive work while idle.",
                        style: TextStyle(color: Colors.white70),
                      ),
                      value: _backgroundServicesEnabled,
                      onChanged: (val) {
                        setState(() {
                          _backgroundServicesEnabled = val;
                        });
                      },
                    ),
                    if (_chargerControlMode == AppSettings.chargerControlModeBle)
                      ExpansionTile(
                        leading: const Icon(
                          Icons.electrical_services,
                          color: Colors.lightGreenAccent,
                        ),
                        title: const Text(
                          "Charging Relay Assignment",
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          "Choose which relay pin this launcher controls.",
                          style: TextStyle(color: Colors.white70),
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: DropdownButtonFormField<String>(
                              dropdownColor: const Color(0xFF1A1A1A),
                              style: const TextStyle(color: Colors.white),
                              iconEnabledColor: Colors.white70,
                              decoration: const InputDecoration(
                                labelText: "Relay PIN",
                                labelStyle: TextStyle(color: Colors.white70),
                              ),
                              initialValue: _chargerRelayPin,
                              items:
                                  const ['26', '27', '32', '33']
                                      .map(
                                        (pin) => DropdownMenuItem(
                                          value: pin,
                                          child: Text(
                                            'Relay $pin',
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                              onChanged: (value) {
                                if (value == null) {
                                  return;
                                }
                                setState(() {
                                  _chargerRelayPin = value;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ExpansionTile(
                      leading: const Icon(
                        Icons.notifications_active,
                        color: Colors.orangeAccent,
                      ),
                      title: const Text(
                        "Low-Time Alerts",
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        "Notify at under 1 minute and again at 20 seconds.",
                        style: TextStyle(color: Colors.white70),
                      ),
                      children: [
                        SwitchListTile(
                          title: const Text(
                            "Enable Low-Time Alerts",
                            style: TextStyle(color: Colors.white),
                          ),
                          value: _lowTimeAlertsEnabled,
                          onChanged: (val) {
                            setState(() {
                              _lowTimeAlertsEnabled = val;
                            });
                          },
                        ),
                        SwitchListTile(
                          title: const Text(
                            "Vibrate on Alert",
                            style: TextStyle(color: Colors.white),
                          ),
                          value: _lowTimeAlertsVibrationEnabled,
                          onChanged: (val) {
                            setState(() {
                              _lowTimeAlertsVibrationEnabled = val;
                            });
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _lowTimeAlertsSoundPath ??
                                  'Default notification sound',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            OutlinedButton(
                              onPressed: _pickLowTimeAlertAudioFile,
                              child: const Text("Browse Alert Sound"),
                            ),
                            OutlinedButton(
                              onPressed: _toggleLowTimeAlertPreview,
                              child: Text(
                                _isLowTimeAlertPreviewing
                                    ? "Playing..."
                                    : "Preview Alert",
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                    _buildAppearanceSection(themeProvider),
                  ],
                ),
              ),
              _buildSaveFooter(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAppearanceSection(ThemeProvider themeProvider) {
    return ExpansionTile(
      leading: const Icon(Icons.palette),
      title: const Text("Appearance", style: TextStyle(color: Colors.white)),
      subtitle: const Text(
        "Customize branding and theme",
        style: TextStyle(color: Colors.white70),
      ),
      children: [
        // Business Name
        ListTile(
          title: const Text(
            "Business Name",
            style: TextStyle(color: Colors.white),
          ),
          subtitle: TextField(
            controller: _businessNameController,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: "Enter Name",
              hintStyle: TextStyle(color: Colors.white54),
            ),
          ),
        ),

        ListTile(
          title: const Text(
            "Device Name",
            style: TextStyle(color: Colors.white),
          ),
          subtitle: TextField(
            controller: _deviceNameController,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: "Enter Name",
              hintStyle: TextStyle(color: Colors.white54),
            ),
          ),
        ),

        // Theme Templates (Simplified Card List)
        const Padding(
          padding: EdgeInsets.all(8.0),
          child: Text(
            "Theme Templates",
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: context.watch<ThemeProvider>().themeGradients.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5, // 5 Columns as requested
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
          ),
          itemBuilder: (ctx, index) => _buildThemeSwatch(ctx, index),
        ),
        const SizedBox(height: 20),

        _buildWallpaperSection(
          label: 'Portrait Wallpaper / Video',
          path: _portraitWallpaperPath,
          onBrowse: () => _pickWallpaper(true),
          onClear: () => _clearWallpaper(true),
        ),
        _buildWallpaperSection(
          label: 'Landscape Wallpaper / Video',
          path: _landscapeWallpaperPath,
          onBrowse: () => _pickWallpaper(false),
          onClear: () => _clearWallpaper(false),
        ),

        // Audio Section
        SwitchListTile(
          title: const Text(
            "Enable Audio",
            style: TextStyle(color: Colors.white),
          ),
          value: _audioEnabled,
          onChanged: (val) async {
            if (!val) {
              await AudioService().stopAudio();
            }

            if (!mounted) {
              return;
            }

            setState(() {
              _audioEnabled = val;
              if (!val) {
                _isAudioPreviewing = false;
              }
            });
          },
        ),
        SwitchListTile(
          title: const Text(
            "Loop Audio",
            style: TextStyle(color: Colors.white),
          ),
          value: _audioLoop,
          onChanged: (val) => setState(() => _audioLoop = val),
        ),
        Slider(
          value: _volume,
          onChanged: (val) => setState(() => _volume = val),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Volume can only be changed here.',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          title: const Text(
            'User Sound Volume',
            style: TextStyle(color: Colors.white),
          ),
          subtitle: const Text(
            'Saved playback volume for customer and walk-in sessions.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
        Slider(
          value: _userVolume,
          onChanged: (val) => setState(() => _userVolume = val),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _audioPath ?? 'No audio file selected',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: _pickAudioFile,
              child: const Text("Browse Audio"),
            ),
            OutlinedButton(
              onPressed: _toggleAudioPreview,
              child: Text(_isAudioPreviewing ? "Stop Preview" : "Preview"),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SwitchListTile(
          title: const Text(
            "Enable Coin/Time Audio",
            style: TextStyle(color: Colors.white),
          ),
          subtitle: const Text(
            "Play a short sound when time is received from the server",
            style: TextStyle(color: Colors.white70),
          ),
          value: _coinAudioEnabled,
          onChanged: (val) {
            setState(() {
              _coinAudioEnabled = val;
              if (!val) {
                _isCoinAudioPreviewing = false;
              }
            });
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _coinAudioPath ?? 'No coin/time audio selected',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: _pickCoinAudioFile,
              child: const Text("Browse Coin Audio"),
            ),
            OutlinedButton(
              onPressed: _toggleCoinAudioPreview,
              child: Text(
                _isCoinAudioPreviewing ? "Playing..." : "Preview Coin Audio",
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildThemeSwatch(BuildContext context, int index) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final bool isSelected = themeProvider.selectedThemeIndex == index;
    final List<Color> colors = themeProvider.themeGradients[index];

    return InkWell(
      onTap: () => themeProvider.setTheme(index),
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          // The Gradient implementation
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(10),
          border: isSelected ? Border.all(color: Colors.white, width: 3) : null,
          boxShadow: isSelected
              ? [const BoxShadow(blurRadius: 4, color: Colors.black26)]
              : [],
        ),
      ),
    );
  }

  Widget _buildWallpaperSection({
    required String label,
    required String? path,
    required VoidCallback onBrowse,
    required VoidCallback onClear,
  }) {
    final hasValue = path != null && path.isNotEmpty;

    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.white)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            hasValue ? path : 'No file selected',
            style: const TextStyle(color: Colors.white70),
          ),
          if (hasValue) ...[
            const SizedBox(height: 4),
            Text(
              '${MediaWallpaperBackground.mediaTypeLabel(path)} wallpaper',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton(
                onPressed: onBrowse,
                child: const Text('Browse File'),
              ),
              const SizedBox(width: 12),
              if (hasValue)
                OutlinedButton(onPressed: onClear, child: const Text('Clear')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSaveFooter() {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          onPressed: _saveSettings,
          child: const Text("Save Changes", style: TextStyle(fontSize: 18)),
        ),
      ),
    );
  }

  Widget _buildKioskSection() {
    final isActive = _isDeviceOwnerActive == true;
    final statusText = _isDeviceOwnerActive == null
        ? 'Checking device owner state...'
        : isActive
        ? 'Device Owner Active'
        : 'Device Owner Not Active';
    final statusColor = _isDeviceOwnerActive == null
        ? Colors.white70
        : isActive
        ? Colors.greenAccent
        : Colors.orangeAccent;

    return ExpansionTile(
      leading: const Icon(Icons.security, color: Colors.cyanAccent),
      title: const Text(
        "Kiosk Provisioning",
        style: TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        statusText,
        style: TextStyle(color: statusColor),
      ),
      children: [
        ListTile(
          leading: Icon(
            isActive ? Icons.verified_user : Icons.error_outline,
            color: statusColor,
          ),
          title: Text(
            isActive ? 'Device Owner Active' : 'Device Owner Not Active',
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: const Text(
            'Hard kiosk lockdown only works after device-owner provisioning.',
            style: TextStyle(color: Colors.white70),
          ),
          trailing: IconButton(
            onPressed: _loadDeviceOwnerStatus,
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Refresh status',
          ),
        ),
        ListTile(
          leading: _isApplyingKioskPolicies
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_open, color: Colors.white),
          title: const Text(
            'Apply Kiosk Policies',
            style: TextStyle(color: Colors.white),
          ),
          subtitle: const Text(
            'Run lock task, immersive mode, and device-owner policy hooks now.',
            style: TextStyle(color: Colors.white70),
          ),
          onTap: _isApplyingKioskPolicies ? null : _applyKioskPolicies,
        ),
        _buildTile(
          "Provisioning Checklist",
          "Open setup steps for technicians",
          Icons.assignment_turned_in,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const KioskProvisioningPage(),
              ),
            );
          },
        ),
      ],
    );
  }
}

Widget _buildTile(
  String title,
  String desc,
  IconData icon, {
  VoidCallback? onTap,
  Widget? trailing,
}) {
  return ListTile(
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(color: Colors.white)),
    subtitle: Text(desc, style: const TextStyle(color: Colors.white70)),
    trailing: trailing,
    onTap: onTap,
  );
}
