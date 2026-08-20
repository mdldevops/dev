import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';
import 'coin_session_page.dart';
import 'customer_auth_page.dart';
import 'main.dart';
import 'media_wallpaper_background.dart';
import 'services/api_service.dart';
import 'services/standalone_mqtt_service.dart';
import 'services/ble_charger_service.dart';
import 'services/customer_account_service.dart';
import 'services/device_identity_service.dart';
import 'services/shelly_charger_service.dart';
import 'theme_provider.dart';

class MenuPage extends StatefulWidget {
  const MenuPage({
    super.key,
    required this.businessName,
    required this.deviceName,
    required this.wallpaperPath,
    required this.initialSessionTime,
    this.currentCustomerUsername,
    this.currentCustomerRole,
    this.isOpenTime = false,
  });

  final String businessName;
  final String deviceName;
  final String? wallpaperPath;
  final Duration initialSessionTime;
  final String? currentCustomerUsername;
  final String? currentCustomerRole;
  final bool isOpenTime;

  @override
  State<MenuPage> createState() => _MenuPageState();
}

class _MenuPageState extends State<MenuPage> {
  static const MethodChannel _channel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );
  static const int _firstSessionWarningSeconds = 59;
  static const int _secondSessionWarningSeconds = 10;
  static const double _sessionCountdownSpeedMultiplier = 1.3;

  Duration _remainingTime = Duration.zero;
  Timer? _timer;
  Timer? _deviceStateTimer;
  List<_WhitelistApp> _whitelistedApps = const <_WhitelistApp>[];
  String? _currentCustomerUsername;
  String? _currentCustomerRole;
  String _setupMode = AppSettings.setupModeServer;
  String? _deviceId;
  int? _chargerRelayPin;
  DateTime? _sessionExpiresAt;
  bool _sentOneMinuteWarning = false;
  bool _sentTwentySecondWarning = false;
  bool _sessionExpiredHandled = false;
  bool _isHandlingEndSessionPrompt = false;
  bool _isEndingSession = false;
  bool _isOpeningCoinPage = false;
  bool _isClearingCache = false;
  int? _lastSyncedRemainingSecond;
  Offset _floatingTimeOffset = const Offset(20, 88);

  bool get _isFinalCountdownLocked =>
      !widget.isOpenTime &&
      _remainingTime > Duration.zero &&
      _remainingTime.inSeconds <= _secondSessionWarningSeconds;

  bool get _isStandaloneMode => AppSettings.isStandaloneModeValue(_setupMode);

  Duration get _visibleRemainingTime {
    if (widget.isOpenTime) {
      return _remainingTime;
    }

    return Duration(
      milliseconds:
          (_remainingTime.inMilliseconds * _sessionCountdownSpeedMultiplier)
              .round(),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    _remainingTime = _scaleSessionDuration(widget.initialSessionTime);
    _sessionExpiresAt = widget.isOpenTime
        ? null
        : DateTime.now().add(_remainingTime);
    _sentOneMinuteWarning =
        _remainingTime.inSeconds < _firstSessionWarningSeconds;
    _sentTwentySecondWarning =
        _remainingTime.inSeconds < _secondSessionWarningSeconds;
    _currentCustomerUsername = widget.currentCustomerUsername;
    _currentCustomerRole = widget.currentCustomerRole;
    unawaited(_markReturnToMenuOnHome());
    if (!widget.isOpenTime) {
      _startTimer();
    }
    _loadWhitelistApps();
    _loadCurrentCustomer();
    _initializeDeviceStateSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _timer?.cancel();
    _deviceStateTimer?.cancel();
    unawaited(_cancelSessionMonitoring());
    unawaited(_cancelSessionWarningNotification());
    super.dispose();
  }

  late final WidgetsBindingObserver _lifecycleObserver = _MenuLifecycleObserver(
    onResumed: _handleResumeChecks,
  );

  Future<void> _markReturnToMenuOnHome() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppSettings.returnToMenuOnHomeKey, true);
    if (_sessionExpiresAt == null) {
      await prefs.remove(AppSettings.returnToMenuSessionExpiresAtKey);
    } else {
      await prefs.setInt(
        AppSettings.returnToMenuSessionExpiresAtKey,
        _sessionExpiresAt!.millisecondsSinceEpoch,
      );
    }
  }

  Future<void> _clearReturnToMenuOnHome() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppSettings.returnToMenuOnHomeKey);
    await prefs.remove(AppSettings.returnToMenuSessionExpiresAtKey);
  }

  Future<void> _initializeDeviceStateSync() async {
    final prefs = await SharedPreferences.getInstance();
    _setupMode =
        prefs.getString(AppSettings.setupModeKey) ??
        AppSettings.setupModeServer;
    _chargerRelayPin = int.tryParse(
      prefs.getString(AppSettings.chargerRelayPinKey) ?? '26',
    );
    _restoreSessionExpiryFromPrefs(prefs);
    if (!widget.isOpenTime && _sessionExpiresAt != null) {
      await prefs.setInt(
        AppSettings.sessionExpiresAtKey,
        _sessionExpiresAt!.millisecondsSinceEpoch,
      );
    }
    if (_isStandaloneMode) {
      _deviceStateTimer?.cancel();
    } else {
      _deviceId = await DeviceIdentityService.getOrCreateDeviceId();
      await _syncDeviceState();
    }
    if (!widget.isOpenTime) {
      await _scheduleSessionMonitoring();
    }
    _deviceStateTimer?.cancel();
    if (!_isStandaloneMode) {
      _deviceStateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _syncDeviceState();
      });
    }
  }

  Future<void> _syncDeviceState() async {
    if (_isStandaloneMode) {
      return;
    }

    final deviceId = _deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }

    _refreshRemainingTimeFromClock();

    int? batteryLevel;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getSystemStatus',
      );
      batteryLevel = (result?['batteryLevel'] as num?)?.toInt();
    } on PlatformException {
      batteryLevel = null;
    }

    final prefs = await SharedPreferences.getInstance();
    final chargerStartPercent =
        prefs.getInt(AppSettings.chargerStartPercentKey) ?? 20;
    final chargerStopPercent =
        prefs.getInt(AppSettings.chargerStopPercentKey) ?? 80;
    final chargerControlMode =
        prefs.getString(AppSettings.chargerControlModeKey) ??
        AppSettings.chargerControlModeBle;
    final chargingControlEnabled =
        prefs.getBool(AppSettings.chargingControlEnabledKey) ?? true;
    if (batteryLevel != null && chargingControlEnabled) {
      if (chargerControlMode == AppSettings.chargerControlModeShelly) {
        await ShellyChargerService.instance.syncChargingDecision(
          batteryLevel: batteryLevel,
          startBelowPercent: chargerStartPercent,
          stopAtPercent: chargerStopPercent,
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
      } else {
        await BleChargerService.instance.syncChargingDecision(
          batteryLevel: batteryLevel,
          startBelowPercent: chargerStartPercent,
          stopAtPercent: chargerStopPercent,
          relayPin: _chargerRelayPin ?? 26,
          launcherDeviceId: deviceId,
          launcherDeviceName: widget.deviceName,
        );
      }
    }

    await ApiService.updateDeviceState(
      deviceId: deviceId,
      status: 'online',
      remainingSeconds: widget.isOpenTime ? 0 : _visibleRemainingTime.inSeconds,
      isSessionActive: true,
      username: _currentCustomerUsername,
      role: _currentCustomerRole,
      batteryLevel: batteryLevel,
      chargerRelayPin: _chargerRelayPin,
    );
  }

  Future<void> _markDeviceOffline() async {
    if (_isStandaloneMode) {
      return;
    }

    final deviceId = _deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }

    await ApiService.updateDeviceState(
      deviceId: deviceId,
      status: 'offline',
      remainingSeconds: 0,
      isSessionActive: false,
      username: _currentCustomerUsername,
      role: _currentCustomerRole,
      batteryLevel: null,
      chargerRelayPin: _chargerRelayPin,
    );
  }

  Future<void> _loadCurrentCustomer() async {
    if (_currentCustomerUsername != null && _currentCustomerRole != null) {
      return;
    }

    final currentCustomer = await CustomerAccountService.getCurrentCustomer();
    final currentRole = await CustomerAccountService.getCurrentCustomerRole();
    if (!mounted) {
      return;
    }

    setState(() {
      _currentCustomerUsername = currentCustomer;
      _currentCustomerRole = currentRole;
    });
  }

  Future<void> _goToMainPage({bool scheduleReset = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppSettings.sessionExpiresAtKey);
    await prefs.remove(AppSettings.returnToMenuOnHomeKey);
    await prefs.remove(AppSettings.returnToMenuSessionExpiresAtKey);

    if (scheduleReset) {
      final isDeepFreezeEnabled =
          prefs.getBool(AppSettings.deepFreezeEnabledKey) ?? false;
      if (isDeepFreezeEnabled) {
        final gracePeriodLabel =
            prefs.getString(AppSettings.gracePeriodKey) ??
            AppSettings.defaultGracePeriodLabel;
        final gracePeriod = AppSettings.gracePeriodFromLabel(gracePeriodLabel);
        final resetAt = DateTime.now().add(gracePeriod);
        await prefs.setInt(
          AppSettings.pendingResetAtKey,
          resetAt.millisecondsSinceEpoch,
        );
      } else {
        await prefs.remove(AppSettings.pendingResetAtKey);
      }
    }

    if (!mounted) {
      return;
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ArcadeLaunchPage()),
      (route) => false,
    );
  }

  Future<void> _handleSessionExpired() async {
    if (_sessionExpiredHandled) {
      return;
    }
    _sessionExpiredHandled = true;

    if (widget.isOpenTime) {
      return;
    }

    if (_currentCustomerUsername != null) {
      await CustomerAccountService.saveSession(
        username: _currentCustomerUsername!,
        remainingSeconds: 0,
      );
      await CustomerAccountService.startIdleDeadline();
    }

    await _cancelSessionWarningNotification();
    await _cancelSessionMonitoring();
    await _markDeviceOffline();
    await _goToMainPage(scheduleReset: true);
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      _refreshRemainingTimeFromClock();

      if (_remainingTime <= Duration.zero) {
        timer.cancel();
        _handleSessionExpired();
        return;
      }

      _checkAndSendSessionWarnings();

      final currentRemainingSecond = _remainingTime.inSeconds;
      if (currentRemainingSecond != _lastSyncedRemainingSecond &&
          currentRemainingSecond % 5 == 0) {
        _lastSyncedRemainingSecond = currentRemainingSecond;
        _syncDeviceState();
      }
    });
  }

  int _calculateGridColumnCount(double maxWidth) {
    const minTileWidth = 92.0;
    final computedColumns = (maxWidth / minTileWidth).floor();
    return math.max(3, math.min(computedColumns, 8));
  }

  Future<void> _checkAndSendSessionWarnings() async {
    final secondsLeft = _remainingTime.inSeconds;

    if (!_sentOneMinuteWarning && secondsLeft <= _firstSessionWarningSeconds) {
      _sentOneMinuteWarning = true;
      await _showSessionWarningNotification(
        title: 'Less than 1 minute remaining',
        body:
            'Your session is almost over. Insert coins now if you want to continue.',
      );
    }

    if (!_sentTwentySecondWarning &&
        secondsLeft <= _secondSessionWarningSeconds) {
      _sentTwentySecondWarning = true;
      await _returnLauncherToFront();
    }
  }

  Future<void> _scheduleSessionMonitoring() async {
    if (widget.isOpenTime || _remainingTime <= Duration.zero) {
      return;
    }

    final now = DateTime.now();
    final expiresAt = _sessionExpiresAt ?? now.add(_remainingTime);
    _sessionExpiresAt = expiresAt;
    final warnOneMinuteAt = expiresAt.subtract(
      const Duration(seconds: _firstSessionWarningSeconds),
    );
    final warnTwentySecondsAt = expiresAt.subtract(
      const Duration(seconds: _secondSessionWarningSeconds),
    );

    try {
      await _channel.invokeMethod<void>('scheduleSessionMonitoring', {
        'expiresAtMs': expiresAt.millisecondsSinceEpoch,
        'warnOneMinuteAtMs': warnOneMinuteAt.isAfter(now)
            ? warnOneMinuteAt.millisecondsSinceEpoch
            : null,
        'warnTwentySecondsAtMs': warnTwentySecondsAt.isAfter(now)
            ? warnTwentySecondsAt.millisecondsSinceEpoch
            : null,
      });
    } on PlatformException {
      // Best effort only.
    }
  }

  Future<void> _cancelSessionMonitoring() async {
    try {
      await _channel.invokeMethod<void>('cancelSessionMonitoring');
    } on PlatformException {
      // Best effort only.
    }
  }

  Future<void> _handleResumeChecks() async {
    if (!mounted) {
      return;
    }

    await _refreshChargingMonitor();

    if (widget.isOpenTime || _sessionExpiredHandled) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    _restoreSessionExpiryFromPrefs(prefs);
    _refreshRemainingTimeFromClock();
    if (_remainingTime <= Duration.zero) {
      await _handleSessionExpired();
      return;
    }

    final didExpire =
        prefs.getBool(AppSettings.sessionExpiredPendingKey) ?? false;
    if (!didExpire) {
      return;
    }

    await prefs.remove(AppSettings.sessionExpiredPendingKey);
    if (!mounted) {
      return;
    }
    await _handleSessionExpired();
  }

  Future<void> _refreshChargingMonitor() async {
    try {
      debugPrint('[ChargingMonitor][menu] requesting refresh');
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'refreshChargingMonitor',
        {'resetDecisionCache': false},
      );
      debugPrint(
        '[ChargingMonitor][menu] result=${result ?? <String, dynamic>{}}',
      );
    } on PlatformException catch (error) {
      debugPrint('[ChargingMonitor][menu] failed: ${error.message}');
    }
  }

  void _refreshRemainingTimeFromClock() {
    if (widget.isOpenTime) {
      return;
    }

    final expiresAt = _sessionExpiresAt;
    if (expiresAt == null) {
      return;
    }

    final nextRemaining = expiresAt.difference(DateTime.now());
    final normalized = nextRemaining.isNegative ? Duration.zero : nextRemaining;

    if (!mounted) {
      _remainingTime = normalized;
      return;
    }

    if (_remainingTime != normalized) {
      setState(() {
        _remainingTime = normalized;
      });
    }
  }

  void _restoreSessionExpiryFromPrefs(SharedPreferences prefs) {
    if (widget.isOpenTime) {
      return;
    }

    final storedExpiryMillis = prefs.getInt(AppSettings.sessionExpiresAtKey);
    final storedExpiry = storedExpiryMillis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(storedExpiryMillis);

    if (storedExpiry != null) {
      final currentExpiry = _sessionExpiresAt;
      final normalizedCurrent = currentExpiry?.difference(DateTime.now());
      final shouldKeepCurrentExpiry =
          currentExpiry != null &&
          normalizedCurrent != null &&
          !normalizedCurrent.isNegative &&
          currentExpiry.isAfter(storedExpiry);

      if (shouldKeepCurrentExpiry) {
        _remainingTime = normalizedCurrent;
        return;
      }

      _sessionExpiresAt = storedExpiry;
      final normalized = storedExpiry.difference(DateTime.now());
      _remainingTime = normalized.isNegative ? Duration.zero : normalized;
      return;
    }

    if (_sessionExpiresAt == null && _remainingTime > Duration.zero) {
      _sessionExpiresAt = DateTime.now().add(_remainingTime);
    }
  }

  Future<void> _closeAndClearWhitelistedApps() async {
    final prefs = await SharedPreferences.getInstance();
    final packages =
        prefs.getStringList(AppSettings.allowedAppsKey) ?? <String>[];

    if (packages.isEmpty) {
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'resetWhitelistedApps',
        <String, dynamic>{'packageNames': packages},
      );
    } on PlatformException {
      // Best effort only.
    }
  }

  Future<void> _handleManualClearCache() async {
    if (_isClearingCache) {
      return;
    }

    final shouldClear = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Text(
            'Force Close Apps',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Force close the whitelisted apps running in the background now?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Force Close'),
            ),
          ],
        );
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 180));
    await _returnLauncherToFront();

    if (shouldClear != true || !mounted) {
      return;
    }

    setState(() {
      _isClearingCache = true;
    });

    var loadingShown = false;
    try {
      loadingShown = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return const AlertDialog(
              backgroundColor: Color(0xFF121212),
              content: Row(
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Force closing apps...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await _closeAndClearWhitelistedApps();
      if (mounted && loadingShown) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingShown = false;
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Whitelisted apps force closed.')),
      );
    } catch (_) {
      if (mounted && loadingShown) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingShown = false;
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to force close whitelisted apps.'),
        ),
      );
    } finally {
      if (mounted && loadingShown) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) {
        setState(() {
          _isClearingCache = false;
        });
      }
    }
  }

  Future<void> _showSessionWarningNotification({
    required String title,
    required String body,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final alertsEnabled =
        prefs.getBool(AppSettings.lowTimeAlertsEnabledKey) ?? true;
    if (!alertsEnabled) {
      return;
    }

    final soundPath = prefs
        .getString(AppSettings.lowTimeAlertsSoundPathKey)
        ?.trim();
    final vibrationEnabled =
        prefs.getBool(AppSettings.lowTimeAlertsVibrationEnabledKey) ?? true;

    try {
      await _channel.invokeMethod<void>('showSessionWarningNotification', {
        'title': title,
        'body': body,
        'soundPath': soundPath == null || soundPath.isEmpty ? null : soundPath,
        'vibrationEnabled': vibrationEnabled,
      });
    } on PlatformException {
      // Best effort only. Session countdown continues even if notifications fail.
    }
  }

  Future<void> _returnLauncherToFront() async {
    try {
      await _channel.invokeMethod<void>('returnLauncherToFront');
    } on PlatformException {
      // Best effort only.
    }
  }

  Future<void> _cancelSessionWarningNotification() async {
    try {
      await _channel.invokeMethod<void>('cancelSessionWarningNotification');
    } on PlatformException {
      // Best effort only.
    }
  }

  Future<void> _loadWhitelistApps() async {
    final prefs = await SharedPreferences.getInstance();
    final packages =
        prefs.getStringList(AppSettings.allowedAppsKey) ?? <String>[];

    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'getInstalledAppsForPackages',
        <String, dynamic>{'packageNames': packages},
      );
      final installedApps =
          (result ?? <dynamic>[])
              .whereType<Map>()
              .map(
                (dynamic item) => _WhitelistApp.fromMap(
                  Map<dynamic, dynamic>.from(item as Map),
                ),
              )
              .where((app) => packages.contains(app.packageName))
              .toList()
            ..sort(
              (a, b) =>
                  a.appName.toLowerCase().compareTo(b.appName.toLowerCase()),
            );

      if (!mounted) {
        return;
      }

      setState(() {
        _whitelistedApps = installedApps;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _whitelistedApps = packages
            .map(
              (packageName) =>
                  _WhitelistApp(appName: packageName, packageName: packageName),
            )
            .toList();
      });
    }
  }

  Future<void> _launchWhitelistedApp(_WhitelistApp app) async {
    if (_isFinalCountdownLocked) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('App launching is locked during the final 20 seconds.'),
        ),
      );
      return;
    }

    try {
      await _markReturnToMenuOnHome();
      if (widget.isOpenTime) {
        await _channel.invokeMethod<void>('startOpenTimeOverlay');
      } else if (_sessionExpiresAt != null) {
        await _channel.invokeMethod<void>('startRemainingTimeOverlay', {
          'displayRemainingMs': _visibleRemainingTime.inMilliseconds,
          'countdownMultiplier': _sessionCountdownSpeedMultiplier,
        });
      }
      await _channel.invokeMethod<void>('launchApp', <String, dynamic>{
        'packageName': app.packageName,
        'allowPlayStore': _currentCustomerRole == 'admin',
      });
    } on PlatformException catch (error) {
      try {
        await _channel.invokeMethod<void>('stopRemainingTimeOverlay');
      } on PlatformException {
        // Best effort only.
      }
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Unable to open ${app.appName}'),
        ),
      );
    }
  }

  Future<void> _openCoinSessionPage() async {
    if (_isOpeningCoinPage) {
      return;
    }

    if (mounted) {
      setState(() {
        _isOpeningCoinPage = true;
      });
    }

    try {
      await _cancelSessionWarningNotification();
      await _cancelSessionMonitoring();
      await _clearReturnToMenuOnHome();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppSettings.sessionExpiresAtKey);

      if (_isStandaloneMode) {
        final launcherDeviceId =
            await DeviceIdentityService.getOrCreateDeviceId();
        final controller = StandaloneMqttService.instance;
        final connected = await controller.connectBySavedHost();

        if (!mounted) {
          return;
        }

        if (!connected) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Unable to connect to the standalone coin controller.',
              ),
            ),
          );
          return;
        }

        final openResult = await controller.openSession(
          launcherDeviceId: launcherDeviceId,
          launcherDeviceName: widget.deviceName,
        );

        if (!mounted) {
          return;
        }

        if (!openResult.allowed) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(openResult.message)));
          return;
        }
      } else {
        final deviceId = await DeviceIdentityService.getOrCreateDeviceId();
        final sessionResult = await ApiService.startSessionWithRetry(
          deviceId,
          widget.deviceName,
        );

        if (!mounted) {
          return;
        }

        if (sessionResult == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unable to contact the server right now.'),
            ),
          );
          return;
        }

        final status = (sessionResult['status'] ?? '').toString();
        if (status == 'busy') {
          final message =
              (sessionResult['message'] ??
                      'Another customer is currently inserting coins. Please try again in a moment.')
                  .toString();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
          return;
        }

        if (status == 'locked') {
          final message = (sessionResult['message'] ?? 'Device is locked.')
              .toString();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
          return;
        }

        if (status != 'started') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to start coin session.')),
          );
          return;
        }
      }

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CoinSessionPage(
            businessName: widget.businessName,
            deviceName: widget.deviceName,
            wallpaperPath: widget.wallpaperPath,
            initialSelectedTime: _visibleRemainingTime,
            fromMenuPage: true,
            sessionAlreadyStarted: true,
            currentCustomerUsername: _currentCustomerUsername,
            currentCustomerRole: _currentCustomerRole,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isOpeningCoinPage = false;
        });
      } else {
        _isOpeningCoinPage = false;
      }
    }
  }

  Future<void> _saveCurrentTimeForAccount(String username) async {
    await CustomerAccountService.saveSession(
      username: username,
      remainingSeconds: _visibleRemainingTime.inSeconds,
    );
  }

  Future<void> _saveAndEndSession(String username) async {
    await _saveCurrentTimeForAccount(username);
    await _cancelSessionWarningNotification();
    await _cancelSessionMonitoring();
    await _markDeviceOffline();
    await _closeAndClearWhitelistedApps();
    await CustomerAccountService.clearCurrentCustomer();
    await _goToMainPage(scheduleReset: true);
  }

  Future<void> _clearAndEndSession() async {
    if (_currentCustomerUsername != null &&
        _currentCustomerRole != 'admin' &&
        !_isStandaloneMode) {
      try {
        await CustomerAccountService.clearSavedSession(
          _currentCustomerUsername!,
        );
      } catch (_) {
        // Best effort only. The session still ends locally.
      }
    }

    await _cancelSessionWarningNotification();
    await _cancelSessionMonitoring();
    if (!_isStandaloneMode) {
      await _markDeviceOffline();
    }
    await _closeAndClearWhitelistedApps();
    await CustomerAccountService.clearCurrentCustomer();
    await _goToMainPage(scheduleReset: true);
  }

  Future<void> _authenticateAndSaveBeforeExit(CustomerAuthMode mode) async {
    if (_isStandaloneMode && mode != CustomerAuthMode.login) {
      return;
    }

    final credentials = await showCustomerAuthPage(context, mode: mode);
    if (credentials == null) {
      return;
    }

    try {
      final result = mode == CustomerAuthMode.login
          ? await CustomerAccountService.login(
              username: credentials.username,
              password: credentials.password,
            )
          : await CustomerAccountService.register(
              username: credentials.username,
              password: credentials.password,
            );

      await CustomerAccountService.setCurrentCustomer(
        result.username,
        role: result.role,
      );

      if (_isStandaloneMode && !result.isAdmin) {
        await CustomerAccountService.clearCurrentCustomer();
        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Only admin login is available in standalone mode.'),
          ),
        );
        return;
      }

      if (result.isAdmin) {
        await _cancelSessionWarningNotification();
        await _markDeviceOffline();
        await _closeAndClearWhitelistedApps();
        await CustomerAccountService.clearCurrentCustomer();
        await _goToMainPage(scheduleReset: false);
        return;
      }

      await _saveAndEndSession(result.username);
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  Future<void> _handleEndSessionPressed() async {
    if (_isHandlingEndSessionPrompt || _isEndingSession) {
      return;
    }

    if (_isStandaloneMode) {
      setState(() {
        _isHandlingEndSessionPrompt = true;
      });

      bool? shouldEnd;
      try {
        shouldEnd = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121212),
              title: const Text(
                'End Session',
                style: TextStyle(color: Colors.white),
              ),
              content: const Text(
                'Are you sure you want to end this session?',
                style: TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('No'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Yes'),
                ),
              ],
            );
          },
        );
      } finally {
        await Future<void>.delayed(const Duration(milliseconds: 180));
        await _returnLauncherToFront();
        if (mounted) {
          setState(() {
            _isHandlingEndSessionPrompt = false;
          });
        } else {
          _isHandlingEndSessionPrompt = false;
        }
      }

      if (shouldEnd != true) {
        return;
      }

      await _runEndSessionAction(_clearAndEndSession);
      return;
    }

    if (widget.isOpenTime || _currentCustomerRole == 'admin') {
      await _runEndSessionAction(_clearAndEndSession);
      return;
    }

    if (_currentCustomerUsername != null) {
      await _runEndSessionAction(_clearAndEndSession);
      return;
    }

    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Text(
            'End Session',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Login or register an account to save the remaining time before ending this session.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop('end'),
              child: const Text('End Anyway'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop('login'),
              child: const Text('Login'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop('register'),
              child: const Text('Register'),
            ),
          ],
        );
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 180));
    await _returnLauncherToFront();

    if (action == 'login') {
      await _runEndSessionAction(
        () => _authenticateAndSaveBeforeExit(CustomerAuthMode.login),
      );
      return;
    }

    if (action == 'register') {
      await _runEndSessionAction(
        () => _authenticateAndSaveBeforeExit(CustomerAuthMode.register),
      );
      return;
    }

    await _runEndSessionAction(_clearAndEndSession);
  }

  Future<void> _runEndSessionAction(Future<void> Function() action) async {
    if (_isEndingSession) {
      return;
    }

    if (mounted) {
      setState(() {
        _isEndingSession = true;
      });
    } else {
      _isEndingSession = true;
    }

    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          _isEndingSession = false;
        });
      } else {
        _isEndingSession = false;
      }
    }
  }

  String _formatSessionTime(Duration duration) {
    final totalSeconds = duration.inMilliseconds <= 0
        ? 0
        : ((duration.inMilliseconds + 999) ~/ 1000).clamp(0, 359999);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Duration _scaleSessionDuration(Duration original) {
    if (widget.isOpenTime) {
      return original;
    }
    if (original <= Duration.zero) {
      return Duration.zero;
    }

    final scaledMilliseconds =
        (original.inMilliseconds / _sessionCountdownSpeedMultiplier).round();
    return Duration(
      milliseconds: scaledMilliseconds <= 0 ? 1000 : scaledMilliseconds,
    );
  }

  void _updateFloatingTimeOffset(
    DragUpdateDetails details,
    BoxConstraints constraints,
  ) {
    const controlWidth = 88.0;
    const controlHeight = 32.0;
    final nextOffset = _floatingTimeOffset + details.delta;
    final maxX = math.max(0.0, constraints.maxWidth - controlWidth);
    final maxY = math.max(0.0, constraints.maxHeight - controlHeight);

    setState(() {
      _floatingTimeOffset = Offset(
        nextOffset.dx.clamp(0.0, maxX),
        nextOffset.dy.clamp(0.0, maxY),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: themeProvider.currentTheme[0],
        body: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Positioned.fill(
                child: _MenuBackground(
                  wallpaperPath: widget.wallpaperPath,
                  gradientColors: themeProvider.currentTheme,
                ),
              ),
              const Positioned.fill(child: _MenuGrid()),
              const Positioned.fill(child: _MenuGlow()),
              SafeArea(
                minimum: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text(
                                'Active Session',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              ElevatedButton.icon(
                                onPressed: _isOpeningCoinPage
                                    ? null
                                    : _openCoinSessionPage,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.tealAccent.shade400,
                                  foregroundColor: Colors.black,
                                  minimumSize: const Size(0, 36),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: _isOpeningCoinPage
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.monetization_on,
                                        size: 18,
                                      ),
                                label: Text(
                                  _isOpeningCoinPage
                                      ? 'Opening...'
                                      : 'Insert Coin',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: _isClearingCache
                                  ? null
                                  : _handleManualClearCache,
                              tooltip: 'Force close apps',
                              icon: _isClearingCache
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.cleaning_services_outlined,
                                      color: Colors.white,
                                    ),
                            ),
                            TextButton(
                              onPressed:
                                  (_isHandlingEndSessionPrompt ||
                                      _isEndingSession)
                                  ? null
                                  : _handleEndSessionPressed,
                              child: _isEndingSession
                                  ? const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                        SizedBox(width: 8),
                                        Text(
                                          'Ending...',
                                          style: TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    )
                                  : const Text(
                                      'End Session',
                                      style: TextStyle(color: Colors.white),
                                    ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (_isFinalCountdownLocked) ...[
                      const SizedBox(height: 10),
                      const Text(
                        'App launching is locked during the final 20 seconds.',
                        style: TextStyle(
                          color: Colors.amberAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Expanded(
                      child: _whitelistedApps.isEmpty
                          ? const Center(
                              child: Text(
                                'No whitelisted apps selected.',
                                style: TextStyle(color: Colors.white70),
                              ),
                            )
                          : LayoutBuilder(
                              builder: (context, gridConstraints) {
                                final crossAxisCount =
                                    _calculateGridColumnCount(
                                      gridConstraints.maxWidth,
                                    );
                                return GridView.builder(
                                  padding: const EdgeInsets.only(
                                    top: 8,
                                    left: 4,
                                    right: 4,
                                    bottom: 8,
                                  ),
                                  itemCount: _whitelistedApps.length,
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: crossAxisCount,
                                        mainAxisSpacing: 18,
                                        crossAxisSpacing: 18,
                                        childAspectRatio: 0.78,
                                      ),
                                  itemBuilder: (context, index) {
                                    final app = _whitelistedApps[index];
                                    final isLocked = _isFinalCountdownLocked;
                                    return InkWell(
                                      onTap: isLocked
                                          ? null
                                          : () => _launchWhitelistedApp(app),
                                      borderRadius: BorderRadius.circular(12),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 56,
                                            height: 56,
                                            child: app.iconBytes != null
                                                ? Image.memory(
                                                    app.iconBytes!,
                                                    fit: BoxFit.contain,
                                                    errorBuilder: (_, _, _) {
                                                      return _fallbackIcon(app);
                                                    },
                                                    color: isLocked
                                                        ? Colors.white54
                                                        : null,
                                                    colorBlendMode: isLocked
                                                        ? BlendMode.modulate
                                                        : null,
                                                  )
                                                : _fallbackIcon(app),
                                          ),
                                          const SizedBox(height: 8),
                                          SizedBox(
                                            width: 72,
                                            child: Text(
                                              app.appName,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: isLocked
                                                    ? Colors.white54
                                                    : Colors.white,
                                                fontSize: 11,
                                                height: 1.15,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: _floatingTimeOffset.dx,
                top: _floatingTimeOffset.dy,
                child: GestureDetector(
                  onPanUpdate: (details) =>
                      _updateFloatingTimeOffset(details, constraints),
                  child: _FloatingRemainingTime(
                    value: widget.isOpenTime
                        ? 'OPEN TIME'
                        : _formatSessionTime(_visibleRemainingTime),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingRemainingTime extends StatelessWidget {
  const _FloatingRemainingTime({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 88,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.68),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.35)),
          boxShadow: const [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          value,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.cyanAccent,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

class _MenuBackground extends StatelessWidget {
  const _MenuBackground({
    required this.wallpaperPath,
    required this.gradientColors,
  });

  final String? wallpaperPath;
  final List<Color> gradientColors;

  @override
  Widget build(BuildContext context) {
    return MediaWallpaperBackground(
      path: wallpaperPath,
      gradientColors: gradientColors,
      overlayOpacity: 0.36,
    );
  }
}

class _MenuGlow extends StatelessWidget {
  const _MenuGlow();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: -120,
            top: 100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Colors.pinkAccent.withValues(alpha: 0.14),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: -80,
            bottom: 80,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Colors.cyanAccent.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuGrid extends StatelessWidget {
  const _MenuGrid();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _MenuGridPainter());
  }
}

class _MenuGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.tealAccent.withValues(alpha: 0.08)
      ..strokeWidth = 1;

    for (double y = 120; y < size.height; y += 26) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _WhitelistApp {
  const _WhitelistApp({
    required this.appName,
    required this.packageName,
    this.iconBytes,
  });

  final String appName;
  final String packageName;
  final Uint8List? iconBytes;

  factory _WhitelistApp.fromMap(Map<dynamic, dynamic> map) {
    return _WhitelistApp(
      appName: (map['appName'] as String?)?.trim().isNotEmpty == true
          ? map['appName'] as String
          : (map['packageName'] as String? ?? 'Unknown App'),
      packageName: map['packageName'] as String? ?? '',
      iconBytes: map['icon'] is Uint8List ? map['icon'] as Uint8List : null,
    );
  }
}

class _MenuLifecycleObserver with WidgetsBindingObserver {
  _MenuLifecycleObserver({required this.onResumed});

  final Future<void> Function() onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onResumed();
    }
  }
}

Widget _fallbackIcon(_WhitelistApp app) {
  return Center(
    child: Text(
      app.appName.isEmpty ? '?' : app.appName[0].toUpperCase(),
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
    ),
  );
}
