import 'dart:async';

import 'package:flutter/services.dart';

import 'charging_service.dart';

class BatteryMonitorService {
  BatteryMonitorService._();

  static final BatteryMonitorService instance = BatteryMonitorService._();

  static const MethodChannel _platformChannel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );

  Timer? _timer;
  int? _currentBatteryLevel;

  int? get currentBatteryLevel => _currentBatteryLevel;

  Future<void> start() async {
    if (_timer?.isActive == true) {
      return;
    }
    print('[BATTERY] Monitoring started');
    await checkNow();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      unawaited(checkNow());
    });
  }

  Future<void> checkNow() async {
    try {
      final result = await _platformChannel.invokeMapMethod<String, dynamic>(
        'getSystemStatus',
      );
      final batteryLevel = (result?['batteryLevel'] as num?)?.toInt();
      if (batteryLevel == null) {
        return;
      }
      _currentBatteryLevel = batteryLevel;
      print('[BATTERY] Battery=$batteryLevel%');
      await ChargingService.instance.syncForBattery(batteryLevel);
    } on PlatformException catch (error) {
      print('[BATTERY] monitor failed: ${error.message}');
    }
  }

  Future<void> stop() async {
    if (_timer == null) {
      return;
    }
    print('[BATTERY] Monitoring stopped');
    _timer?.cancel();
    _timer = null;
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> dispose() => stop();
}
