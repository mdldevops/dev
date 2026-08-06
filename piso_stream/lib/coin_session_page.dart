import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:piso_stream/controller/kiosk_controller.dart';
import 'package:piso_stream/device_status_bar.dart';
import 'package:piso_stream/services/api_service.dart';
import 'package:piso_stream/services/audio_service.dart';
import 'package:piso_stream/services/customer_account_service.dart';
import 'package:piso_stream/services/device_identity_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';
import 'main.dart';
import 'menu_page.dart';
import 'theme_provider.dart';

late KioskController kiosk;

class CoinSessionPage extends StatefulWidget {
  const CoinSessionPage({
    super.key,
    required this.businessName,
    required this.deviceName,
    required this.wallpaperPath,
    this.initialSelectedTime = Duration.zero,
    this.fromMenuPage = false,
    this.sessionAlreadyStarted = false,
    this.currentCustomerUsername,
    this.currentCustomerRole,
  });

  final String businessName;
  final String deviceName;
  final String? wallpaperPath;
  final Duration initialSelectedTime;
  final bool fromMenuPage;
  final bool sessionAlreadyStarted;
  final String? currentCustomerUsername;
  final String? currentCustomerRole;

  @override
  State<CoinSessionPage> createState() => _CoinSessionPageState();
}

class _CoinSessionPageState extends State<CoinSessionPage>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );
  static const int _defaultCountdownSeconds = 60;
  static const int _cancelDelaySeconds = 3;

  late int _remainingSeconds;
  late Duration _selectedTime;
  bool _showStartPlaying = false;
  bool _sessionActive = false;
  bool _connectionError = false;
  Timer? _timer;
  bool _isClosing = false;
  bool _isCancelling = false;
  bool _isInitializingKiosk = true;
  bool _socketConnected = false;
  String _diagnosticMessage = 'Preparing session request...';
  late AudioService _audioService;
  bool _audioEnabled = false;
  String? _audioPath;
  bool _audioLoop = true;
  double _audioVolume = 1.0;
  bool _coinAudioEnabled = false;
  String? _coinAudioPath;
  bool _isStandaloneMode = false;
  bool _cancelDelayActive = true;
  Timer? _cancelDelayTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audioService = AudioService();
    _remainingSeconds = _defaultCountdownSeconds;
    _selectedTime = widget.initialSelectedTime;
    _showStartPlaying = _selectedTime > Duration.zero;
    _startCountdown();
    _startCancelDelay();

    _initializeKiosk();
    _refreshChargingMonitor();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _cancelDelayTimer?.cancel();
    _audioService.stopAudio();
    if (!_isClosing) {
      kiosk.dispose();
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshChargingMonitor();
    }
  }

  Future<void> _refreshChargingMonitor() async {
    try {
      debugPrint('[ChargingMonitor][coin] requesting refresh');
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'refreshChargingMonitor',
        {
          'resetDecisionCache': false,
        },
      );
      debugPrint(
        '[ChargingMonitor][coin] result=${result ?? <String, dynamic>{}}',
      );
    } on PlatformException catch (error) {
      debugPrint('[ChargingMonitor][coin] failed: ${error.message}');
    }
  }

  void _startCancelDelay() {
    _cancelDelayTimer?.cancel();
    _cancelDelayActive = true;
    _cancelDelayTimer = Timer(
      const Duration(seconds: _cancelDelaySeconds),
      () {
        if (!mounted) {
          return;
        }
        setState(() {
          _cancelDelayActive = false;
        });
      },
    );
  }

  Future<void> _disposeKiosk({bool releaseSession = false}) async {
    if (_isClosing) {
      return;
    }

    _isClosing = true;

    if (releaseSession && _isStandaloneMode) {
      try {
        await kiosk.endSession();
      } catch (error) {
        debugPrint('Standalone end session during dispose failed: $error');
      }
      return;
    }

    if (releaseSession && !_isStandaloneMode) {
      try {
        await ApiService.releaseSession(
          kiosk.deviceId,
          deviceName: widget.deviceName,
        );
      } catch (error) {
        debugPrint('Release session during dispose failed: $error');
      }
    }

    kiosk.onUpdate = null;
    kiosk.onSessionStarted = null;
    kiosk.onDisconnected = null;
    kiosk.onError = null;
    kiosk.dispose();
  }

  Future<void> _loadAudioSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isStandaloneMode = AppSettings.isStandaloneModeValue(
      prefs.getString(AppSettings.setupModeKey),
    );
    final audioPath = prefs.getString(AppSettings.audioPathKey)?.trim();

    if (!mounted) {
      return;
    }

    setState(() {
      _audioEnabled = prefs.getBool(AppSettings.audioEnabledKey) ?? false;
      _audioPath = audioPath == null || audioPath.isEmpty ? null : audioPath;
      _audioLoop = prefs.getBool(AppSettings.audioLoopKey) ?? true;
      _audioVolume =
          prefs.getDouble(AppSettings.userAudioVolumeKey) ??
          prefs.getDouble(AppSettings.audioVolumeKey) ??
          0.5;
      _coinAudioEnabled =
          prefs.getBool(AppSettings.coinAudioEnabledKey) ?? false;
      final coinAudioPath = prefs
          .getString(AppSettings.coinAudioPathKey)
          ?.trim();
      _coinAudioPath = coinAudioPath == null || coinAudioPath.isEmpty
          ? null
          : coinAudioPath;
    });
  }

  Future<void> _startConfiguredAudioIfNeeded() async {
    if (!_audioEnabled || _audioPath == null || _audioPath!.isEmpty) {
      await _audioService.stopAudio();
      return;
    }

    try {
      await _audioService.playAudio(
        audioPath: _audioPath!,
        loop: _audioLoop,
        volume: _audioVolume,
      );
    } catch (error) {
      debugPrint('Unable to start configured audio: $error');
    }
  }

  Future<void> _playCoinAudioIfNeeded() async {
    if (!_coinAudioEnabled ||
        _coinAudioPath == null ||
        _coinAudioPath!.isEmpty) {
      return;
    }

    try {
      await _audioService.playEffectAudio(
        audioPath: _coinAudioPath!,
        volume: _audioVolume,
      );
    } catch (error) {
      debugPrint('Unable to play coin audio: $error');
    }
  }

  Future<void> _initializeKiosk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isStandaloneMode = AppSettings.isStandaloneModeValue(
        prefs.getString(AppSettings.setupModeKey),
      );
      final deviceId = await DeviceIdentityService.getOrCreateDeviceId();
      kiosk = KioskController(
        deviceId: deviceId,
        deviceName: widget.deviceName,
        sessionAlreadyStarted: widget.sessionAlreadyStarted,
      );

      kiosk.onUpdate = (t, m) {
        if (!mounted) return;
        print("Time update received: total=$t, minutes=$m");
        _addTime(Duration(minutes: m));
        unawaited(_playCoinAudioIfNeeded());
      };

      kiosk.onSessionStarted = () {
        if (!mounted) return;
        print("Session started! Ready for coins.");
        setState(() {
          _sessionActive = true;
          _diagnosticMessage = _socketConnected
              ? 'Session active. Waiting for coin events.'
              : 'Session active. Socket is reconnecting.';
        });
      };

      kiosk.onConnected = () {
        if (!mounted) return;
        setState(() {
          _socketConnected = true;
          _diagnosticMessage = _sessionActive
              ? 'Session active. Socket connected.'
              : 'Socket connected. Session reserved.';
        });
      };

      kiosk.onDisconnected = () {
        if (!mounted) return;
        setState(() {
          _socketConnected = false;
          _diagnosticMessage = _sessionActive
              ? 'Session active. Socket reconnecting...'
              : 'Socket disconnected. Reconnecting...';
          // Don't show error notification - socket will auto-reconnect
          if (!_sessionActive) {
            _connectionError = false;
          }
        });
      };

      kiosk.onError = (error) {
        if (!mounted) return;

        final normalizedError = error.toLowerCase();
        final isSocketReconnectWarning =
            normalizedError.contains('socket connection timed out') ||
            normalizedError.contains('live coin updates are waiting') ||
            normalizedError.contains('connect_error') ||
            normalizedError.contains('timeout');

        setState(() {
          if (_sessionActive && isSocketReconnectWarning) {
            _socketConnected = false;
            _diagnosticMessage =
                'Session active. Waiting for socket reconnection...';
            // Don't show error message for reconnection warnings
            _connectionError = false;
            return;
          }

          // Only show errors if not a socket reconnection warning
          if (!isSocketReconnectWarning && _sessionActive) {
            _connectionError = false;
            _diagnosticMessage = 'Session active. Coins are being monitored.';
            return;
          }

          _connectionError = true;
          _diagnosticMessage = error;
        });
      };

      await kiosk.initialize();

      if (!mounted) {
        return;
      }

      await _loadAudioSettings();
      await _startConfiguredAudioIfNeeded();

      setState(() {
        _isInitializingKiosk = false;
        _socketConnected = kiosk.isConnected;
        _diagnosticMessage = _sessionActive
            ? (_socketConnected
                  ? 'Session active. Socket connected.'
                  : 'Session active. Socket reconnecting...')
            : (_socketConnected
                  ? 'Socket connected. Session reserved.'
                  : 'Waiting for socket connection.');
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializingKiosk = false;
        _connectionError = true;
        _diagnosticMessage = 'Session initialization failed.';
      });
    }
  }

  Future<void> _cancelAndExit() async {
    if (_isCancelling || _cancelDelayActive) {
      return;
    }

    if (mounted) {
      setState(() {
        _isCancelling = true;
      });
    }

    try {
      await _disposeKiosk(releaseSession: true);
    } catch (error) {
      debugPrint('Cancel teardown failed: $error');
    }

    if (!mounted) {
      return;
    }

    if (widget.fromMenuPage) {
      _goToMenuPage();
      return;
    }

    _goToMainPage();
  }

  Future<void> _handleNoTimeTimeout() async {
    if (widget.currentCustomerUsername != null &&
        widget.currentCustomerRole != 'admin') {
      await CustomerAccountService.clearCurrentCustomer();
    }

    await _cancelAndExit();
  }

  void _goToMainPage() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ArcadeLaunchPage()),
      (route) => false,
    );
  }

  void _goToMenuPage() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => MenuPage(
          businessName: widget.businessName,
          deviceName: widget.deviceName,
          wallpaperPath: widget.wallpaperPath,
          initialSessionTime: _selectedTime,
          currentCustomerUsername: widget.currentCustomerUsername,
          currentCustomerRole: widget.currentCustomerRole,
          isOpenTime: widget.currentCustomerRole == 'admin',
        ),
      ),
    );
  }

  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_remainingSeconds <= 0) {
        timer.cancel();
        if (_selectedTime <= Duration.zero) {
          _handleNoTimeTimeout();
          return;
        }

        setState(() {
          _remainingSeconds = _defaultCountdownSeconds;
          _showStartPlaying = true;
        });
        return;
      }

      setState(() {
        _remainingSeconds -= 1;
      });
    });
  }

  void _addTime(Duration duration) {
    AppSettings.clearPendingReset();
    _cancelDelayTimer?.cancel();

    setState(() {
      // Always accumulate time - whether before or during active session
      _selectedTime = _selectedTime + duration;
      _remainingSeconds = _defaultCountdownSeconds;
      _showStartPlaying = _selectedTime > Duration.zero;
      _cancelDelayActive = false;
    });
    _startCountdown();
  }

  String _formatSessionTime(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours > 0 && minutes > 0) {
      return '$hours hr $minutes mins.';
    }
    if (hours > 0) {
      return '$hours hr.';
    }
    return '${duration.inMinutes} mins.';
  }

  Color _countdownColor(double progress) {
    if (progress > 0.5) {
      return Color.lerp(
        Colors.orangeAccent,
        Colors.greenAccent,
        (progress - 0.5) * 2,
      )!;
    }
    return Color.lerp(Colors.redAccent, Colors.orangeAccent, progress * 2)!;
  }

  Future<void> _startPlaying() async {
    await _audioService.stopAudio();

    if (widget.currentCustomerUsername != null &&
        widget.currentCustomerRole != 'admin') {
      await CustomerAccountService.saveSession(
        username: widget.currentCustomerUsername!,
        remainingSeconds: _selectedTime.inSeconds,
      );
      await CustomerAccountService.clearIdleDeadline();
    }

    if (!_isStandaloneMode) {
      try {
        await ApiService.endSession(
          kiosk.deviceId,
          deviceName: widget.deviceName,
        );
      } catch (error) {
        debugPrint('Confirm session during Start Playing failed: $error');
      }
    }

    await _disposeKiosk(releaseSession: false);

    if (!mounted) return;

    _goToMenuPage();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final progress = _remainingSeconds / _defaultCountdownSeconds;
    final countdownColor = _countdownColor(progress.clamp(0.0, 1.0));

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: themeProvider.currentTheme[0],
        body: Stack(
          children: [
            Positioned.fill(
              child: _SessionBackground(
                wallpaperPath: widget.wallpaperPath,
                gradientColors: themeProvider.currentTheme,
              ),
            ),
            const Positioned.fill(child: _SessionGrid()),
            const Positioned.fill(child: _SessionGlow()),
            SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  const DeviceStatusBar(),
                  const SizedBox(height: 8),
                  _SessionHeader(
                    businessName: widget.businessName,
                    deviceName: widget.deviceName,
                  ),
                  const Spacer(),
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
                  if (_isInitializingKiosk)
                    const Column(
                      children: [
                        Text(
                          'INITIALIZING DEVICE',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 18,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 8),
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.cyanAccent,
                            ),
                          ),
                        ),
                      ],
                    )
                  else if (!_sessionActive)
                    const Column(
                      children: [
                        Text(
                          'SESSION RESERVED',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: 18,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 8),
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.orangeAccent,
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    const Text(
                      '--Please Insert COIN--',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w900,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 10),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  _CountdownRing(
                    progress: progress.clamp(0.0, 1.0),
                    seconds: _remainingSeconds,
                    color: countdownColor,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _formatSessionTime(_selectedTime),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_sessionActive)
                    const Opacity(
                      opacity: 0.5,
                      child: Text(
                        'Time will be added with each coin inserted',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  const Spacer(flex: 2),
                  if (_showStartPlaying)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _startPlaying,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.tealAccent.shade400,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                          child: const Text(
                            'Start Playing',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!_sessionActive || _selectedTime <= Duration.zero)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _isCancelling || _cancelDelayActive
                            ? null
                            : () async {
                                if (_sessionActive &&
                                    _selectedTime > Duration.zero) {
                                  return;
                                }
                                await _cancelAndExit();
                              },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                          backgroundColor: Colors.black.withValues(alpha: 0.2),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        child: Text(
                          _isCancelling
                              ? 'Cancelling...'
                              : _cancelDelayActive
                              ? 'Cancel (${_cancelDelaySeconds}s)'
                              : 'Cancel',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  if (_cancelDelayActive) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Cancel unlocks after a short delay to avoid accidental exit.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountdownRing extends StatelessWidget {
  const _CountdownRing({
    required this.progress,
    required this.seconds,
    required this.color,
  });

  final double progress;
  final int seconds;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      height: 170,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 170,
            height: 170,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 12,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${(progress * 100).round()}%',
                style: TextStyle(
                  color: color,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$seconds seconds',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

}

class _SessionBackground extends StatelessWidget {
  const _SessionBackground({
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
        Container(color: Colors.black.withValues(alpha: 0.28)),
      ],
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({required this.businessName, required this.deviceName});

  final String businessName;
  final String deviceName;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          businessName,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 20,
            letterSpacing: 3,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          deviceName,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.cyanAccent,
            fontSize: 20,
            letterSpacing: 3,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _SessionGlow extends StatelessWidget {
  const _SessionGlow();

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

class _SessionGrid extends StatelessWidget {
  const _SessionGrid();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _SessionGridPainter());
  }
}

class _SessionGridPainter extends CustomPainter {
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
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
