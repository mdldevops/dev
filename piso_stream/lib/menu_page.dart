import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';
import 'admin_login.dart';
import 'coin_session_page.dart';
import 'customer_auth_page.dart';
import 'main.dart';
import 'services/api_service.dart';
import 'services/customer_account_service.dart';
import 'services/device_identity_service.dart';
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
  static const int _secondSessionWarningSeconds = 20;

  Duration _remainingTime = Duration.zero;
  Timer? _timer;
  Timer? _deviceStateTimer;
  final bool _isConnected = true;
  List<_WhitelistApp> _whitelistedApps = const <_WhitelistApp>[];
  String? _currentCustomerUsername;
  String? _currentCustomerRole;
  String? _deviceId;
  int? _chargerRelayPin;
  bool _sentOneMinuteWarning = false;
  bool _sentTwentySecondWarning = false;

  @override
  void initState() {
    super.initState();
    _remainingTime = widget.initialSessionTime;
    _sentOneMinuteWarning =
        widget.initialSessionTime.inSeconds < _firstSessionWarningSeconds;
    _sentTwentySecondWarning =
        widget.initialSessionTime.inSeconds < _secondSessionWarningSeconds;
    _currentCustomerUsername = widget.currentCustomerUsername;
    _currentCustomerRole = widget.currentCustomerRole;
    if (!widget.isOpenTime) {
      _startTimer();
    }
    _loadWhitelistApps();
    _loadCurrentCustomer();
    _initializeDeviceStateSync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _deviceStateTimer?.cancel();
    unawaited(_cancelSessionWarningNotification());
    super.dispose();
  }

  Future<void> _initializeDeviceStateSync() async {
    _deviceId = await DeviceIdentityService.getOrCreateDeviceId();
    final prefs = await SharedPreferences.getInstance();
    _chargerRelayPin = int.tryParse(
      prefs.getString(AppSettings.chargerRelayPinKey) ?? '26',
    );
    await _syncDeviceState();
    _deviceStateTimer?.cancel();
    _deviceStateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _syncDeviceState();
    });
  }

  Future<void> _syncDeviceState() async {
    final deviceId = _deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }

    int? batteryLevel;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getSystemStatus',
      );
      batteryLevel = (result?['batteryLevel'] as num?)?.toInt();
    } on PlatformException {
      batteryLevel = null;
    }

    await ApiService.updateDeviceState(
      deviceId: deviceId,
      status: 'online',
      remainingSeconds: widget.isOpenTime ? 0 : _remainingTime.inSeconds,
      isSessionActive: true,
      username: _currentCustomerUsername,
      role: _currentCustomerRole,
      batteryLevel: batteryLevel,
      chargerRelayPin: _chargerRelayPin,
    );
  }

  Future<void> _markDeviceOffline() async {
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
    if (scheduleReset) {
      final prefs = await SharedPreferences.getInstance();
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
    await _markDeviceOffline();
    await _goToMainPage(scheduleReset: true);
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_remainingTime <= Duration.zero) {
        timer.cancel();
        _handleSessionExpired();
        return;
      }

      setState(() {
        _remainingTime -= const Duration(seconds: 1);
      });

      _checkAndSendSessionWarnings();

      if (_remainingTime.inSeconds % 5 == 0) {
        _syncDeviceState();
      }
    });
  }

  Future<void> _checkAndSendSessionWarnings() async {
    final secondsLeft = _remainingTime.inSeconds;

    if (!_sentOneMinuteWarning && secondsLeft <= _firstSessionWarningSeconds) {
      _sentOneMinuteWarning = true;
      await _showSessionWarningNotification(
        title: 'Session ending soon',
        body: 'Your session has less than 1 minute remaining.',
      );
    }

    if (!_sentTwentySecondWarning && secondsLeft <= _secondSessionWarningSeconds) {
      _sentTwentySecondWarning = true;
      await _showSessionWarningNotification(
        title: '20 seconds remaining',
        body: 'Insert coins now if you want to continue your session.',
      );
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
        'getInstalledApps',
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
    try {
      await _channel.invokeMethod<void>('launchApp', <String, dynamic>{
        'packageName': app.packageName,
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Unable to open ${app.appName}')),
      );
    }
  }

  Future<void> _openCoinSessionPage() async {
    await _cancelSessionWarningNotification();

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
        const SnackBar(content: Text('Unable to contact the server right now.')),
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

    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CoinSessionPage(
          businessName: widget.businessName,
          deviceName: widget.deviceName,
          wallpaperPath: widget.wallpaperPath,
          initialSelectedTime: _remainingTime,
          fromMenuPage: true,
          sessionAlreadyStarted: true,
          currentCustomerUsername: _currentCustomerUsername,
          currentCustomerRole: _currentCustomerRole,
        ),
      ),
    );
  }

  Future<void> _saveCurrentTimeForAccount(String username) async {
    await CustomerAccountService.saveSession(
      username: username,
      remainingSeconds: _remainingTime.inSeconds,
    );
  }

  Future<void> _saveAndEndSession(String username) async {
    await _saveCurrentTimeForAccount(username);
    await _cancelSessionWarningNotification();
    await _markDeviceOffline();
    await CustomerAccountService.clearCurrentCustomer();
    await _goToMainPage(scheduleReset: true);
  }

  Future<void> _authenticateAndSaveBeforeExit(CustomerAuthMode mode) async {
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

      if (result.isAdmin) {
        await _cancelSessionWarningNotification();
        await _markDeviceOffline();
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
        SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _handleEndSessionPressed() async {
    if (widget.isOpenTime || _currentCustomerRole == 'admin') {
      await _cancelSessionWarningNotification();
      await _markDeviceOffline();
      await CustomerAccountService.clearCurrentCustomer();
      await _goToMainPage(scheduleReset: false);
      return;
    }

    if (_currentCustomerUsername != null) {
      await _saveAndEndSession(_currentCustomerUsername!);
      return;
    }

    final action = await showDialog<String>(
      context: context,
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

    if (action == 'login') {
      await _authenticateAndSaveBeforeExit(CustomerAuthMode.login);
      return;
    }

    if (action == 'register') {
      await _authenticateAndSaveBeforeExit(CustomerAuthMode.register);
      return;
    }

    await _cancelSessionWarningNotification();
    await _markDeviceOffline();
    await CustomerAccountService.clearCurrentCustomer();
    await _goToMainPage(scheduleReset: true);
  }

  String _formatSessionTime(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: themeProvider.currentTheme[0],
        body: Stack(
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
                      const Text(
                        'Active Session',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextButton(
                        onPressed: _handleEndSessionPressed,
                        child: const Text(
                          'End Session',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InfoCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _InfoRow(
                          label: 'Business Name',
                          value: widget.businessName,
                        ),
                        _InfoRow(label: 'Device Name', value: widget.deviceName),
                        _InfoRow(
                          label: 'Customer',
                          value: _currentCustomerUsername ?? 'Guest',
                        ),
                        _InfoRow(
                          label: 'Status',
                          value: _isConnected ? 'Connected' : 'Disconnected',
                          valueColor: _isConnected
                              ? Colors.greenAccent
                              : Colors.redAccent,
                        ),
                        _InfoRow(
                          label: 'Remaining Time',
                          value: widget.isOpenTime
                              ? 'OPEN TIME'
                              : _formatSessionTime(_remainingTime),
                          valueColor: Colors.cyanAccent,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _InfoCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Whitelisted Apps',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: _whitelistedApps.isEmpty
                                ? const Center(
                                    child: Text(
                                      'No whitelisted apps selected.',
                                      style: TextStyle(color: Colors.white70),
                                    ),
                                  )
                                : GridView.builder(
                                    itemCount: _whitelistedApps.length,
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: 4,
                                          mainAxisSpacing: 10,
                                          crossAxisSpacing: 10,
                                          childAspectRatio: 0.75,
                                        ),
                                    itemBuilder: (context, index) {
                                      final app = _whitelistedApps[index];
                                      return InkWell(
                                        onTap: () => _launchWhitelistedApp(app),
                                        borderRadius: BorderRadius.circular(16),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 52,
                                              height: 52,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: Colors.white.withValues(
                                                  alpha: 0.08,
                                                ),
                                                border: Border.all(
                                                  color: Colors.white12,
                                                ),
                                              ),
                                              child: ClipOval(
                                                child: app.iconBytes != null
                                                    ? Image.memory(
                                                        app.iconBytes!,
                                                        fit: BoxFit.contain,
                                                        errorBuilder: (_, _, _) {
                                                          return _fallbackIcon(app);
                                                        },
                                                      )
                                                    : _fallbackIcon(app),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            SizedBox(
                                              width: 60,
                                              child: Text(
                                                app.appName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const PasscodeScreen(),
                              ),
                            );
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.45),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text('Admin Page'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _openCoinSessionPage,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.tealAccent.shade400,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text('Open Coin Page'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white12),
      ),
      child: child,
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor = Colors.white,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: const TextStyle(color: Colors.white70)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor, fontWeight: FontWeight.w700),
            ),
          ),
        ],
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
    if (wallpaperPath == null) {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: gradientColors,
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          File(wallpaperPath!),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) {
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: gradientColors,
                ),
              ),
            );
          },
        ),
        Container(color: Colors.black.withValues(alpha: 0.36)),
      ],
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

Widget _fallbackIcon(_WhitelistApp app) {
  return Center(
    child: Text(
      app.appName.isEmpty ? '?' : app.appName[0].toUpperCase(),
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
    ),
  );
}
