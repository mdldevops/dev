import 'dart:async';
import 'package:flutter/material.dart';
import 'package:piso_stream/menu_page.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'app_settings.dart';
import 'admin_login.dart';
import 'coin_session_page.dart';
import 'customer_auth_page.dart';
import 'device_status_bar.dart';
import 'services/customer_account_service.dart';
import 'services/device_identity_service.dart';
import 'services/ble_charger_service.dart';
import 'services/standalone_mqtt_service.dart';
import 'services/socket_service.dart';
import 'services/api_service.dart';
import 'theme_provider.dart';

final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isBroadcastDialogVisible = false;
  SocketService? _sharedSocket;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  @override
  void dispose() {
    _sharedSocket?.removeBroadcastListener(_showBroadcastPopup);
    super.dispose();
  }

  Future<void> _initializeServices() async {
    final prefs = await SharedPreferences.getInstance();
    final setupMode = prefs.getString(AppSettings.setupModeKey);
    if (AppSettings.isStandaloneModeValue(setupMode)) {
      _sharedSocket?.removeBroadcastListener(_showBroadcastPopup);
      _sharedSocket?.disconnect();
      _sharedSocket = null;
      return;
    }

    await _initializeSharedSocket();
  }

  Future<void> _initializeSharedSocket() async {
    final deviceId = await DeviceIdentityService.getOrCreateDeviceId();
    final sharedSocket = SocketService(
      url: ApiService.socketUrl,
      deviceId: deviceId,
    );
    sharedSocket.addBroadcastListener(_showBroadcastPopup);
    sharedSocket.connect();
    _sharedSocket = sharedSocket;
  }

  Future<void> _showBroadcastPopup(String message) async {
    final context = appNavigatorKey.currentContext;
    if (context == null || _isBroadcastDialogVisible) {
      return;
    }

    _isBroadcastDialogVisible = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Text(
            'Admin Broadcast',
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
    _isBroadcastDialogVisible = false;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      home: const ArcadeLaunchPage(),
      navigatorObservers: [routeObserver],
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.0)),
          child: child!,
        );
      },
    );
  }
}

class ArcadeLaunchPage extends StatefulWidget {
  const ArcadeLaunchPage({super.key});

  @override
  State<ArcadeLaunchPage> createState() => _ArcadeLaunchPageState();
}

class _ArcadeLaunchPageState extends State<ArcadeLaunchPage>
    with RouteAware, WidgetsBindingObserver {
  static const String _defaultBusinessName = 'PISO STREAM';
  static const String _defaultDeviceName = 'CP1';
  static const String _launcherVersion = 'Launcher v1.0.2+2';
  static const MethodChannel _platformChannel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );

  String _businessName = _defaultBusinessName;
  String _deviceName = _defaultDeviceName;
  String _setupMode = AppSettings.setupModeServer;
  String? _portraitWallpaperPath;
  String? _landscapeWallpaperPath;
  String _gracePeriodLabel = AppSettings.defaultGracePeriodLabel;
  bool _isDeepFreezeEnabled = false;
  Duration? _pendingResetRemaining;
  String? _currentCustomerUsername;
  String? _currentCustomerRole;
  bool _isDeviceLocked = false;
  String _deviceLockMessage = 'Device is locked.';
  int? _chargerRelayPin;
  PageRoute<dynamic>? _route;
  Timer? _resetTimer;
  Timer? _customerIdleTimer;
  Timer? _deviceLockTimer;
  Timer? _deviceStateTimer;
  String? _deviceId;
  bool _isStartingCoinSession = false;

  bool get _isStandaloneMode =>
      AppSettings.isStandaloneModeValue(_setupMode);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enableKioskMode();
    _loadSavedSettings();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute && route != _route) {
      if (_route != null) {
        routeObserver.unsubscribe(this);
      }
      _route = route;
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    if (_route != null) {
      routeObserver.unsubscribe(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    _resetTimer?.cancel();
    _customerIdleTimer?.cancel();
    _deviceLockTimer?.cancel();
    _deviceStateTimer?.cancel();
    super.dispose();
  }

  @override
  void didPopNext() {
    _loadSavedSettings();
  }

  @override
  void didPushNext() {
    _deviceStateTimer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _enableKioskMode();
      _loadSavedSettings();
    }
  }

  Future<void> _enableKioskMode() async {
    try {
      await _platformChannel.invokeMethod<void>('enterKioskMode');
    } on PlatformException {
      // Best effort only. Full kiosk enforcement depends on device policy.
    }
  }

  Future<void> _refreshNativeKioskPolicies() async {
    try {
      await _platformChannel.invokeMethod<void>('enterKioskMode');
    } on PlatformException {
      // Best effort only. Native side may still re-apply on resume/app launch.
    }
  }

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBusinessName = prefs
        .getString(AppSettings.businessNameKey)
        ?.trim();
    final savedDeviceName = prefs.getString(AppSettings.deviceNameKey)?.trim();
    final savedPortraitWallpaper = prefs
        .getString(AppSettings.portraitWallpaperKey)
        ?.trim();
    final savedLandscapeWallpaper = prefs
        .getString(AppSettings.landscapeWallpaperKey)
        ?.trim();
    final setupMode =
        prefs.getString(AppSettings.setupModeKey) ??
        AppSettings.setupModeServer;
    final gracePeriodLabel =
        prefs.getString(AppSettings.gracePeriodKey) ??
        AppSettings.defaultGracePeriodLabel;
    final isDeepFreezeEnabled =
        prefs.getBool(AppSettings.deepFreezeEnabledKey) ?? false;
    String? currentCustomer = prefs
        .getString(AppSettings.currentCustomerKey)
        ?.trim();
    String? currentCustomerRole = prefs
        .getString(AppSettings.currentCustomerRoleKey)
        ?.trim()
        .toLowerCase();
    final pendingResetAtMillis = prefs.getInt(AppSettings.pendingResetAtKey);
    final pendingResetAt = pendingResetAtMillis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(pendingResetAtMillis);
    final pendingResetRemaining = pendingResetAt?.difference(DateTime.now());
    final idleDeadlineMillis = prefs.getInt(
      AppSettings.customerIdleDeadlineKey,
    );
    final idleDeadline = idleDeadlineMillis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(idleDeadlineMillis);
    final didExpire =
        prefs.getBool(AppSettings.sessionExpiredPendingKey) ?? false;
    var showExpiredSnackbar = false;

    if (didExpire) {
      await prefs.remove(AppSettings.sessionExpiredPendingKey);
      showExpiredSnackbar = true;
      if (currentCustomer != null &&
          currentCustomer.isNotEmpty &&
          currentCustomerRole != 'admin') {
        await CustomerAccountService.clearCurrentCustomer();
        currentCustomer = null;
        currentCustomerRole = null;
      }
    }

    if (currentCustomer != null &&
        currentCustomer.isNotEmpty &&
        currentCustomerRole != 'admin' &&
        idleDeadline != null &&
        idleDeadline.isBefore(DateTime.now())) {
      await CustomerAccountService.clearCurrentCustomer();
      currentCustomer = null;
      currentCustomerRole = null;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _businessName = (savedBusinessName == null || savedBusinessName.isEmpty)
          ? _defaultBusinessName
          : savedBusinessName;
      _setupMode = setupMode;
      _deviceName = (savedDeviceName == null || savedDeviceName.isEmpty)
          ? _defaultDeviceName
          : savedDeviceName;
      _portraitWallpaperPath =
          (savedPortraitWallpaper == null || savedPortraitWallpaper.isEmpty)
          ? null
          : savedPortraitWallpaper;
      _landscapeWallpaperPath =
          (savedLandscapeWallpaper == null || savedLandscapeWallpaper.isEmpty)
          ? null
          : savedLandscapeWallpaper;
      _gracePeriodLabel = gracePeriodLabel;
      _isDeepFreezeEnabled = isDeepFreezeEnabled;
      _currentCustomerUsername =
          (currentCustomer == null || currentCustomer.isEmpty)
          ? null
          : currentCustomer;
      _currentCustomerRole =
          (currentCustomerRole == null || currentCustomerRole.isEmpty)
          ? null
          : currentCustomerRole;
      _chargerRelayPin = int.tryParse(
        prefs.getString(AppSettings.chargerRelayPinKey) ?? '26',
      );
      _pendingResetRemaining =
          pendingResetRemaining == null || pendingResetRemaining.isNegative
          ? (pendingResetAt == null ? null : Duration.zero)
          : pendingResetRemaining;
    });

    if (showExpiredSnackbar) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Session expired and you have been logged out.'),
          ),
        );
      });
    }

    _startResetWatcher();
    await _startCustomerIdleTimer();
    if (_isStandaloneMode) {
      _deviceStateTimer?.cancel();
      _deviceLockTimer?.cancel();
      setState(() {
        _isDeviceLocked = false;
        _deviceLockMessage = 'Device is ready.';
      });
      return;
    }

    await _refreshDeviceLockStatus();
    _startDeviceLockWatcher();
    _initializeDeviceStateSync();
  }

  Future<void> _initializeDeviceStateSync() async {
    if (_isStandaloneMode) {
      _deviceStateTimer?.cancel();
      return;
    }

    _deviceId ??= await DeviceIdentityService.getOrCreateDeviceId();
    await _syncDeviceState();
    _deviceStateTimer?.cancel();
    _deviceStateTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _syncDeviceState();
    });
  }

  Future<int?> _getBatteryLevel() async {
    try {
      final result = await _platformChannel.invokeMapMethod<String, dynamic>(
        'getSystemStatus',
      );
      return (result?['batteryLevel'] as num?)?.toInt();
    } on PlatformException {
      return null;
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

    final prefs = await SharedPreferences.getInstance();
    final expiresAtMillis = prefs.getInt(AppSettings.sessionExpiresAtKey);
    final expiresAt = expiresAtMillis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(expiresAtMillis);
    final hasSessionExpiry =
        expiresAt != null && expiresAt.isAfter(DateTime.now());
    final isActiveCustomerSession =
        (_currentCustomerRole ?? 'customer') != 'admin' && hasSessionExpiry;
    final remainingSeconds = isActiveCustomerSession
        ? expiresAt!.difference(DateTime.now()).inSeconds.clamp(0, 864000)
        : 0;
    final batteryLevel = await _getBatteryLevel();
    final chargerStartPercent =
        prefs.getInt(AppSettings.chargerStartPercentKey) ?? 30;
    final chargerStopPercent =
        prefs.getInt(AppSettings.chargerStopPercentKey) ?? 80;
    if (batteryLevel != null) {
      await BleChargerService.instance.syncChargingDecision(
        batteryLevel: batteryLevel,
        startBelowPercent: chargerStartPercent,
        stopAtPercent: chargerStopPercent,
        relayPin: _chargerRelayPin ?? 26,
        launcherDeviceId: deviceId,
        launcherDeviceName: _deviceName,
      );
    }
    await ApiService.updateDeviceState(
      deviceId: deviceId,
      status: 'online',
      remainingSeconds: remainingSeconds,
      isSessionActive: isActiveCustomerSession,
      username: _currentCustomerUsername,
      role: _currentCustomerRole,
      batteryLevel: batteryLevel,
      chargerRelayPin: _chargerRelayPin,
    );
  }

  void _startDeviceLockWatcher() {
    _deviceLockTimer?.cancel();
    _deviceLockTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _refreshDeviceLockStatus();
    });
  }

  Future<void> _refreshDeviceLockStatus() async {
    if (_isStandaloneMode) {
      return;
    }

    final deviceId = await DeviceIdentityService.getOrCreateDeviceId();
    final status = await ApiService.getDeviceStatus(deviceId);
    if (!mounted || status == null) {
      return;
    }

    setState(() {
      _isDeviceLocked = status.isLocked;
      _deviceLockMessage = status.message.isEmpty
          ? 'Device is locked.'
          : status.message;
    });
  }

  void _startResetWatcher() {
    _resetTimer?.cancel();

    if (!_isDeepFreezeEnabled || _pendingResetRemaining == null) {
      return;
    }

    if (_pendingResetRemaining == Duration.zero) {
      _runPendingReset();
      return;
    }

    _resetTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final prefs = await SharedPreferences.getInstance();
      final resetAtMillis = prefs.getInt(AppSettings.pendingResetAtKey);

      if (resetAtMillis == null) {
        timer.cancel();
        if (!mounted) {
          return;
        }
        setState(() {
          _pendingResetRemaining = null;
        });
        return;
      }

      final remaining = DateTime.fromMillisecondsSinceEpoch(
        resetAtMillis,
      ).difference(DateTime.now());

      if (!mounted) {
        timer.cancel();
        return;
      }

      if (remaining <= Duration.zero) {
        timer.cancel();
        setState(() {
          _pendingResetRemaining = Duration.zero;
        });
        await _runPendingReset();
        return;
      }

      setState(() {
        _pendingResetRemaining = remaining;
      });
    });
  }

  Future<void> _runPendingReset() async {
    final prefs = await SharedPreferences.getInstance();
    final packages =
        prefs.getStringList(AppSettings.allowedAppsKey) ?? <String>[];

    try {
      await _platformChannel.invokeMethod<void>('returnLauncherToFront');
    } on PlatformException {
      // Best effort only.
    }

    await CustomerAccountService.clearCurrentCustomer();

    if (packages.isNotEmpty) {
      try {
        await _platformChannel.invokeMethod<void>(
          'resetWhitelistedApps',
          <String, dynamic>{'packageNames': packages},
        );
      } on PlatformException {
        // Keep the UI responsive even if the device does not permit package reset.
      }
    }

    await AppSettings.clearPendingReset();

    if (!mounted) {
      return;
    }

    setState(() {
      _pendingResetRemaining = null;
      _currentCustomerUsername = null;
      _currentCustomerRole = null;
    });

    try {
      await _platformChannel.invokeMethod<void>('restartApp');
    } on PlatformException {
      // Best effort only.
    }
  }

  Future<void> _startCoinSession(String? wallpaperPath) async {
    if (_isStartingCoinSession) {
      return;
    }

    if (mounted) {
      setState(() {
        _isStartingCoinSession = true;
      });
    }

    try {
    if (_isDeviceLocked) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_deviceLockMessage)));
      return;
    }

    if (_isStandaloneMode) {
      final launcherDeviceId = await DeviceIdentityService.getOrCreateDeviceId();
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
        launcherDeviceName: _deviceName,
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
        _deviceName,
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
      if (status == 'locked') {
        final message = (sessionResult['message'] ?? 'Device is locked.')
            .toString();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        return;
      }

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

      if (status != 'started') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to start coin session.')),
        );
        return;
      }
    }

    _customerIdleTimer?.cancel();
    await CustomerAccountService.clearIdleDeadline();

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CoinSessionPage(
          businessName: _businessName,
          deviceName: _deviceName,
          wallpaperPath: wallpaperPath,
          sessionAlreadyStarted: true,
          currentCustomerUsername: _currentCustomerUsername,
          currentCustomerRole: _currentCustomerRole,
        ),
      ),
    );
    } finally {
      if (mounted) {
        setState(() {
          _isStartingCoinSession = false;
        });
      } else {
        _isStartingCoinSession = false;
      }
    }
  }

  Future<void> _startCustomerIdleTimer() async {
    _customerIdleTimer?.cancel();

    if (_currentCustomerUsername == null) {
      return;
    }

    if (_currentCustomerRole == 'admin') {
      return;
    }

    var deadline = await CustomerAccountService.getIdleDeadline();
    if (deadline == null) {
      await CustomerAccountService.startIdleDeadline();
      deadline = await CustomerAccountService.getIdleDeadline();
    }

    if (deadline == null) {
      return;
    }

    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      await _logoutCustomer(showMessage: false);
      return;
    }

    _customerIdleTimer = Timer(remaining, () async {
      await _logoutCustomer(showMessage: true);
    });
  }

  Future<void> _logoutCustomer({required bool showMessage}) async {
    _customerIdleTimer?.cancel();
    await CustomerAccountService.clearCurrentCustomer();
    await _refreshNativeKioskPolicies();

    if (!mounted) {
      return;
    }

    setState(() {
      _currentCustomerUsername = null;
      _currentCustomerRole = null;
    });

    if (showMessage) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Customer account logged out due to inactivity.'),
        ),
      );
    }
  }

  Future<void> _handleCustomerAuth(CustomerAuthMode mode) async {
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
      await _refreshNativeKioskPolicies();

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

      if (!mounted) {
        return;
      }

      setState(() {
        _currentCustomerUsername = result.username;
        _currentCustomerRole = result.role;
      });

      if (result.isAdmin) {
        await CustomerAccountService.clearIdleDeadline();
        _customerIdleTimer?.cancel();
        final wallpaperPath = _wallpaperPathForOrientation(
          MediaQuery.of(context).orientation,
        );
        if (!mounted) {
          return;
        }

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => MenuPage(
              businessName: _businessName,
              deviceName: _deviceName,
              wallpaperPath: wallpaperPath,
              initialSessionTime: Duration.zero,
              currentCustomerUsername: result.username,
              currentCustomerRole: result.role,
              isOpenTime: true,
            ),
          ),
        );
        return;
      }

      final savedSessionSeconds =
          mode == CustomerAuthMode.login && result.savedSessionSeconds > 0
          ? await CustomerAccountService.claimSavedSession(result.username)
          : 0;

      if (savedSessionSeconds > 0) {
        final wallpaperPath = _wallpaperPathForOrientation(
          MediaQuery.of(context).orientation,
        );
        await CustomerAccountService.clearIdleDeadline();
        _customerIdleTimer?.cancel();
        if (!mounted) {
          return;
        }

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => MenuPage(
              businessName: _businessName,
              deviceName: _deviceName,
              wallpaperPath: wallpaperPath,
              initialSessionTime: Duration(seconds: savedSessionSeconds),
              currentCustomerUsername: result.username,
              currentCustomerRole: result.role,
            ),
          ),
        );
        return;
      }

      await CustomerAccountService.startIdleDeadline();
      await _startCustomerIdleTimer();

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isStandaloneMode
                ? 'Admin login successful.'
                : mode == CustomerAuthMode.login
                ? 'Logged in as ${result.username}.'
                : 'Registered as ${result.username}.',
          ),
        ),
      );
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

  String _sessionNoteText() {
    if (_isDeviceLocked) {
      return _deviceLockMessage;
    }

    if (!_isDeepFreezeEnabled) {
      return 'Insert coin to start playing';
    }

    if (_pendingResetRemaining != null) {
      return 'Session data resets in ${AppSettings.formatCountdown(_pendingResetRemaining!)}. Insert coin to keep it.';
    }

    return 'Session data resets after $_gracePeriodLabel when the session ends.';
  }

  String? _wallpaperPathForOrientation(Orientation orientation) {
    final candidate = orientation == Orientation.landscape
        ? _landscapeWallpaperPath
        : _portraitWallpaperPath;

    if (candidate == null || candidate.isEmpty) {
      return null;
    }

    final file = File(candidate);
    return file.existsSync() ? candidate : null;
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final orientation = MediaQuery.of(context).orientation;
    final wallpaperPath = _wallpaperPathForOrientation(orientation);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor:
          themeProvider.currentTheme[0], // Use the first color as background
      body: Stack(
        children: [
          Positioned.fill(
            child: wallpaperPath == null
                ? Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: themeProvider.currentTheme,
                      ),
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(wallpaperPath),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) {
                          return Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: themeProvider.currentTheme,
                              ),
                            ),
                          );
                        },
                      ),
                      Container(color: Colors.black.withValues(alpha: 0.28)),
                    ],
                  ),
          ),
          const Positioned.fill(child: _ArcadeGrid()),
          const Positioned.fill(child: _NeonGlow()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  _TopStatusBar(
                    onAdminTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const PasscodeScreen(),
                        ),
                      );
                    },
                    showLoginAction: _isStandaloneMode,
                    isAdminLoggedIn: _currentCustomerRole == 'admin',
                    onLoginTap: () async {
                      if (_currentCustomerRole == 'admin') {
                        await _logoutCustomer(showMessage: false);
                        return;
                      }
                      await _handleCustomerAuth(CustomerAuthMode.login);
                    },
                  ),
                  const SizedBox(height: 16),
                  // PC Name/Title - Two Lines
                  Column(
                    children: [
                      Text(
                        _businessName,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 20,
                          letterSpacing: 3,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        _deviceName,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.cyanAccent,
                          fontSize: 20,
                          letterSpacing: 3,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: const Text(
                          _launcherVersion,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (!_isStandaloneMode)
                        _CustomerAccessBar(
                          currentCustomerUsername: _currentCustomerUsername,
                          onLogin: () =>
                              _handleCustomerAuth(CustomerAuthMode.login),
                          onRegister: () =>
                              _handleCustomerAuth(CustomerAuthMode.register),
                          onLogout: () => _logoutCustomer(showMessage: false),
                        ),
                    ],
                  ),
                  const Spacer(),
                  _ArcadeHeadline(
                    title: _isDeviceLocked
                        ? 'DEVICE LOCKED'
                        : (_isStartingCoinSession ? 'OPENING COIN...' : 'INSERT COIN'),
                    subtitle: _isDeviceLocked
                        ? _deviceLockMessage
                        : (_isStartingCoinSession
                              ? 'Please wait while the coin controller is opening'
                              : 'Insert coin to start playing'),
                    onTap: _isDeviceLocked || _isStartingCoinSession
                        ? null
                        : () => _startCoinSession(wallpaperPath),
                  ),
                  const Spacer(flex: 2),
                  _SessionNote(message: _sessionNoteText()),
                  const SizedBox(height: 24),
                  const _ConnectionStatus(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({
    required this.onAdminTap,
    this.showLoginAction = false,
    this.isAdminLoggedIn = false,
    this.onLoginTap,
  });

  final VoidCallback onAdminTap;
  final bool showLoginAction;
  final bool isAdminLoggedIn;
  final VoidCallback? onLoginTap;

  @override
  Widget build(BuildContext context) {
    return DeviceStatusBar(
      trailingPrefix: [
        if (showLoginAction)
          IconButton(
            icon: Icon(
              isAdminLoggedIn ? Icons.logout : Icons.login,
              color: isAdminLoggedIn ? Colors.orangeAccent : Colors.white70,
              size: 20,
            ),
            onPressed: onLoginTap,
          ),
        if (showLoginAction) const SizedBox(width: 8),
        IconButton(
          icon: const Icon(
            Icons.admin_panel_settings,
            color: Colors.tealAccent,
            size: 20,
          ),
          onPressed: onAdminTap,
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

class _ArcadeHeadline extends StatefulWidget {
  const _ArcadeHeadline({
    this.onTap,
    required this.title,
    required this.subtitle,
  });

  final VoidCallback? onTap;
  final String title;
  final String subtitle;

  @override
  State<_ArcadeHeadline> createState() => _ArcadeHeadlineState();
}

class _ArcadeHeadlineState extends State<_ArcadeHeadline>
    with SingleTickerProviderStateMixin {
  late AnimationController _blinkController;
  late Animation<Color?> _colorAnimation;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat();

    _colorAnimation = TweenSequence<Color?>([
      TweenSequenceItem(
        tween: ColorTween(begin: Colors.white, end: Colors.pinkAccent),
        weight: 33,
      ),
      TweenSequenceItem(
        tween: ColorTween(begin: Colors.pinkAccent, end: Colors.cyanAccent),
        weight: 33,
      ),
      TweenSequenceItem(
        tween: ColorTween(begin: Colors.cyanAccent, end: Colors.white),
        weight: 34,
      ),
    ]).animate(_blinkController);
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Company Logo
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.cyanAccent, width: 2),
          ),
          child: const Icon(
            Icons.videogame_asset,
            size: 48,
            color: Colors.cyanAccent,
          ),
        ),
        const SizedBox(height: 24),
        AnimatedBuilder(
          animation: _colorAnimation,
          builder: (context, child) {
            return GestureDetector(
              onTap: widget.onTap,
              child: Text(
                widget.title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.onTap == null
                      ? Colors.redAccent
                      : _colorAnimation.value,
                  fontSize: 48,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w900,
                  shadows: [
                    Shadow(
                      color: Colors.pinkAccent.withValues(alpha: 0.8),
                      blurRadius: 30,
                    ),
                    Shadow(
                      color: Colors.cyanAccent.withValues(alpha: 0.4),
                      blurRadius: 20,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        Text(
          widget.subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white70,
            fontSize: 18,
            height: 1.4,
            fontWeight: FontWeight.w500,
            shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
          ),
        ),
      ],
    );
  }
}

class _SessionNote extends StatelessWidget {
  const _SessionNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 14,
          height: 1.4,
        ),
      ),
    );
  }
}

class _CustomerAccessBar extends StatelessWidget {
  const _CustomerAccessBar({
    required this.currentCustomerUsername,
    required this.onLogin,
    required this.onRegister,
    required this.onLogout,
  });

  final String? currentCustomerUsername;
  final VoidCallback onLogin;
  final VoidCallback onRegister;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final isGuest = currentCustomerUsername == null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.person, color: Colors.white70, size: 16),
              const SizedBox(width: 8),
              Text(
                isGuest ? 'Guest' : currentCustomerUsername!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              if (isGuest)
                OutlinedButton(onPressed: onLogin, child: const Text('Login')),
              if (isGuest)
                ElevatedButton(
                  onPressed: onRegister,
                  child: const Text('Register'),
                ),
              if (!isGuest)
                OutlinedButton(
                  onPressed: onLogout,
                  child: const Text('Logout'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 3,
          width: 120,
          decoration: BoxDecoration(
            color: Colors.greenAccent,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Connected',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 14,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

class _NeonGlow extends StatelessWidget {
  const _NeonGlow();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: -150,
            top: 120,
            child: Container(
              width: 360,
              height: 360,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Colors.pinkAccent.withValues(alpha: 0.18),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: -120,
            bottom: 40,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Colors.cyanAccent.withValues(alpha: 0.14),
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

class _ArcadeGrid extends StatelessWidget {
  const _ArcadeGrid();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _ArcadeGridPainter());
  }
}

class _ArcadeGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.tealAccent.withValues(alpha: 0.08)
      ..strokeWidth = 1;

    final horizonY = size.height * 0.58;
    for (double y = horizonY; y < size.height; y += 18) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    for (int i = 0; i <= 18; i++) {
      final dx = size.width * i / 18;
      final end = Offset(
        size.width / 2 + (dx - size.width / 2) * 4,
        size.height,
      );
      canvas.drawLine(Offset(dx, horizonY), end, linePaint);
    }

    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final borderRect = Rect.fromLTWH(16, 16, size.width - 32, size.height - 32);
    canvas.drawRRect(
      RRect.fromRectAndRadius(borderRect, const Radius.circular(24)),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
