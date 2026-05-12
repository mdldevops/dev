import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DeviceStatusBar extends StatefulWidget {
  const DeviceStatusBar({
    super.key,
    this.leading,
    this.trailingPrefix = const <Widget>[],
  });

  static const MethodChannel platformChannel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );

  final Widget? leading;
  final List<Widget> trailingPrefix;

  @override
  State<DeviceStatusBar> createState() => _DeviceStatusBarState();
}

class _DeviceStatusBarState extends State<DeviceStatusBar> {
  Timer? _clockTimer;
  Timer? _statusTimer;
  DateTime _now = DateTime.now();
  int _batteryLevel = 0;
  int _signalLevel = 0;
  String _connectionLabel = 'Offline';

  @override
  void initState() {
    super.initState();
    _startClock();
    _refreshSystemStatus();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refreshSystemStatus(),
    );
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  void _startClock() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _now = DateTime.now();
      });
    });
  }

  Future<void> _refreshSystemStatus() async {
    try {
      final result = await DeviceStatusBar.platformChannel
          .invokeMapMethod<String, dynamic>('getSystemStatus');

      if (!mounted || result == null) {
        return;
      }

      setState(() {
        _batteryLevel = (result['batteryLevel'] as num?)?.toInt() ?? 0;
        _signalLevel = (result['signalLevel'] as num?)?.toInt() ?? 0;
        _connectionLabel =
            (result['connectionLabel'] as String?)?.trim().isNotEmpty == true
            ? result['connectionLabel'] as String
            : 'Offline';
      });
    } on PlatformException {
      // Keep placeholders quiet if native status is unavailable.
    }
  }

  String _formatTime(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final suffix = value.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  IconData _signalIcon() {
    if (_connectionLabel == 'Wi-Fi') {
      if (_signalLevel >= 4) {
        return Icons.wifi;
      }
      if (_signalLevel >= 2) {
        return Icons.wifi_2_bar;
      }
      if (_signalLevel >= 1) {
        return Icons.wifi_1_bar;
      }
      return Icons.wifi_off;
    }

    if (_connectionLabel == 'Mobile') {
      return Icons.network_cell;
    }

    if (_connectionLabel == 'Ethernet') {
      return Icons.settings_ethernet;
    }

    return Icons.signal_wifi_off;
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white70,
      fontSize: 12,
      letterSpacing: 0.8,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        widget.leading ?? Text(_formatTime(_now), style: style),
        Row(
          children: [
            ...widget.trailingPrefix,
            Icon(_signalIcon(), color: Colors.tealAccent, size: 16),
            const SizedBox(width: 8),
            Text(_connectionLabel, style: style),
            const SizedBox(width: 8),
            Text('${_batteryLevel.clamp(0, 100)}%', style: style),
          ],
        ),
      ],
    );
  }
}
