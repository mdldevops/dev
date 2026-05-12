import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_settings.dart';
import 'allowed_apps_page.dart';
import 'kiosk_provisioning_page.dart';
import 'services/admin_pin_service.dart';
import 'services/api_service.dart';
import 'services/audio_service.dart';
import 'theme_provider.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const MethodChannel _platformChannel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );

  // State for toggles and values
  bool isDeepFreezeEnabled = false;
  String gracePeriod = AppSettings.defaultGracePeriodLabel;
  final TextEditingController _businessNameController = TextEditingController();
  final TextEditingController _deviceNameController = TextEditingController();
  double _volume = 0.5;
  bool _audioEnabled = false;
  bool _audioLoop = true;
  bool _allowAppUpdates = true;
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
  final TextEditingController _chargeStartController = TextEditingController(
    text: '30',
  );
  final TextEditingController _chargeStopController = TextEditingController(
    text: '80',
  );

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
    _loadDeviceOwnerStatus();
  }

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) {
      return;
    }

    setState(() {
      _businessNameController.text =
          prefs.getString(AppSettings.businessNameKey) ?? '';
      _deviceNameController.text =
          prefs.getString(AppSettings.deviceNameKey) ?? '';
      _portraitWallpaperPath = _normalizeWallpaperPath(
        prefs.getString(AppSettings.portraitWallpaperKey),
      );
      _landscapeWallpaperPath = _normalizeWallpaperPath(
        prefs.getString(AppSettings.landscapeWallpaperKey),
      );
      isDeepFreezeEnabled =
          prefs.getBool(AppSettings.deepFreezeEnabledKey) ?? false;
      _allowAppUpdates =
          prefs.getBool(AppSettings.allowAppUpdatesKey) ?? true;
      _audioEnabled = prefs.getBool(AppSettings.audioEnabledKey) ?? false;
      _audioLoop = prefs.getBool(AppSettings.audioLoopKey) ?? true;
      _volume = prefs.getDouble(AppSettings.audioVolumeKey) ?? 0.5;
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
      gracePeriod =
          prefs.getString(AppSettings.gracePeriodKey) ??
          AppSettings.defaultGracePeriodLabel;
    });

    final chargingConfig = await ApiService.getChargingConfig();
    if (!mounted || chargingConfig == null) {
      return;
    }

    final settings = chargingConfig['settings'] as Map<String, dynamic>?;
    if (settings == null) {
      return;
    }

    setState(() {
      _chargeStartController.text =
          ((settings['startBelowPercent'] as num?)?.toInt() ?? 30).toString();
      _chargeStopController.text =
          ((settings['stopAtPercent'] as num?)?.toInt() ?? 80).toString();
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

  Future<void> _restartApp() async {
    try {
      await _platformChannel.invokeMethod<void>('restartApp');
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Unable to restart the app right now.'),
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
    await prefs.setString(
      AppSettings.businessNameKey,
      _businessNameController.text.trim(),
    );
    await prefs.setString(
      AppSettings.deviceNameKey,
      _deviceNameController.text.trim(),
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
    await prefs.setBool(AppSettings.allowAppUpdatesKey, _allowAppUpdates);
    await prefs.setBool(AppSettings.audioEnabledKey, _audioEnabled);
    await prefs.setBool(AppSettings.audioLoopKey, _audioLoop);
    await prefs.setDouble(AppSettings.audioVolumeKey, _volume.clamp(0.0, 1.0));
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
    await prefs.setString(AppSettings.gracePeriodKey, gracePeriod);
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

    await _platformChannel.invokeMethod<void>('setAppUpdatesAllowed', {
      'allowed': _allowAppUpdates,
    });

    final startBelowPercent =
        int.tryParse(_chargeStartController.text.trim()) ?? 30;
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

    final chargingSaved = await ApiService.updateChargingConfig(
      startBelowPercent: startBelowPercent,
      stopAtPercent: stopAtPercent,
    );

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(
          chargingSaved
              ? 'Settings saved.'
              : 'Local settings saved, but charging settings could not reach the server.',
        ),
      ),
    );
  }

  Future<void> _pickWallpaper(bool isPortrait) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'],
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
        volume: _volume,
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
        volume: _volume,
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
        volume: _volume,
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
    AudioService().stopAudio();
    _businessNameController.dispose();
    _deviceNameController.dispose();
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
                    _buildTile(
                      "Change Admin PIN",
                      "Update your admin access PIN",
                      Icons.lock,
                      onTap: _showChangeAdminPinDialog,
                    ),
                    _buildTile(
                      "Restart App",
                      "Close and relaunch the kiosk app",
                      Icons.restart_alt,
                      onTap: _restartApp,
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
                      leading: const Icon(Icons.battery_charging_full, color: Colors.lightGreenAccent),
                      title: const Text(
                        "Charging Control",
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        "Server-controlled battery charging thresholds.",
                        style: TextStyle(color: Colors.white70),
                      ),
                      children: [
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
                            _allowAppUpdates ? "App Updates Allowed" : "App Updates Blocked",
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: const Text(
                            "Allow updating installed and whitelisted apps while kiosk mode is active",
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
          label: 'Portrait Wallpaper',
          path: _portraitWallpaperPath,
          onBrowse: () => _pickWallpaper(true),
          onClear: () => _clearWallpaper(true),
        ),
        _buildWallpaperSection(
          label: 'Landscape Wallpaper',
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
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
