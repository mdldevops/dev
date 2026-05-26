import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';

class BleChargerScanResult {
  const BleChargerScanResult({
    required this.name,
    required this.remoteId,
    required this.rssi,
  });

  final String name;
  final String remoteId;
  final int rssi;
}

class BleChargerService {
  BleChargerService._();

  static final BleChargerService instance = BleChargerService._();

  static final Guid serviceUuid = Guid(
    '91f05e01-0000-4f9c-bb88-5a9f6d770001',
  );
  static final Guid commandCharacteristicUuid = Guid(
    '91f05e01-0000-4f9c-bb88-5a9f6d770002',
  );
  static final Guid statusCharacteristicUuid = Guid(
    '91f05e01-0000-4f9c-bb88-5a9f6d770003',
  );

  final StreamController<List<BleChargerScanResult>> _scanResultsController =
      StreamController<List<BleChargerScanResult>>.broadcast();
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _commandCharacteristic;
  BluetoothCharacteristic? _statusCharacteristic;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<List<int>>? _statusSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  bool _lastRelayEnabled = false;
  bool _hasRelayState = false;

  Stream<List<BleChargerScanResult>> get scanResults =>
      _scanResultsController.stream;
  Stream<String> get statusMessages => _statusController.stream;

  String? get connectedDeviceName {
    final name = _device?.platformName.trim();
    if (name == null || name.isEmpty) {
      return null;
    }
    return name;
  }

  bool get isConnected => _device != null && _commandCharacteristic != null;

  Future<void> startScan({String? namePrefix}) async {
    await _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      final devices = results
          .map((result) {
            final name = result.device.platformName.trim();
            if (name.isEmpty) {
              return null;
            }
            if (namePrefix != null &&
                namePrefix.isNotEmpty &&
                !name.toLowerCase().contains(namePrefix.toLowerCase())) {
              return null;
            }
            return BleChargerScanResult(
              name: name,
              remoteId: result.device.remoteId.str,
              rssi: result.rssi,
            );
          })
          .whereType<BleChargerScanResult>()
          .fold<Map<String, BleChargerScanResult>>({}, (map, item) {
            final previous = map[item.remoteId];
            if (previous == null || item.rssi > previous.rssi) {
              map[item.remoteId] = item;
            }
            return map;
          })
          .values
          .toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));

      _scanResultsController.add(devices);
    });

    await FlutterBluePlus.stopScan();
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  Future<bool> connectBySavedName() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(AppSettings.chargerBleDeviceNameKey)?.trim();
    if (name == null || name.isEmpty) {
      _statusController.add('No charger BLE name saved yet.');
      return false;
    }
    return connectByName(name);
  }

  Future<bool> connectByName(String targetName) async {
    if (targetName.trim().isEmpty) {
      _statusController.add('Enter the charger BLE name first.');
      return false;
    }

    final savedSystemDevices = await FlutterBluePlus.systemDevices([]);
    for (final device in savedSystemDevices) {
      if (device.platformName.trim() == targetName.trim()) {
        return _connectToDevice(device);
      }
    }

    final completer = Completer<BluetoothDevice?>();
    late StreamSubscription<List<ScanResult>> tempSubscription;
    tempSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        if (result.device.platformName.trim() == targetName.trim()) {
          if (!completer.isCompleted) {
            completer.complete(result.device);
          }
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      final foundDevice = await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => null,
      );
      await FlutterBluePlus.stopScan();
      await tempSubscription.cancel();

      if (foundDevice == null) {
        _statusController.add('Unable to find charger "$targetName".');
        return false;
      }

      return _connectToDevice(foundDevice);
    } catch (error) {
      await tempSubscription.cancel();
      _statusController.add('BLE scan failed: $error');
      return false;
    }
  }

  Future<bool> _connectToDevice(BluetoothDevice device) async {
    try {
      await disconnect();
      await device.connect(
        timeout: const Duration(seconds: 10),
        license: License.free,
      );

      BluetoothCharacteristic? commandCharacteristic;
      BluetoothCharacteristic? statusCharacteristic;

      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid != serviceUuid) {
          continue;
        }
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == commandCharacteristicUuid) {
            commandCharacteristic = characteristic;
          } else if (characteristic.uuid == statusCharacteristicUuid) {
            statusCharacteristic = characteristic;
          }
        }
      }

      if (commandCharacteristic == null || statusCharacteristic == null) {
        await device.disconnect();
        _statusController.add('Connected device is not a compatible charger controller.');
        return false;
      }

      _device = device;
      _commandCharacteristic = commandCharacteristic;
      _statusCharacteristic = statusCharacteristic;

      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _clearConnection();
          _statusController.add('Charger controller disconnected.');
        }
      });

      await statusCharacteristic.setNotifyValue(true);
      _statusSubscription = statusCharacteristic.onValueReceived.listen((bytes) {
        try {
          final payload = utf8.decode(bytes);
          _statusController.add(payload);
        } catch (_) {}
      });

      _statusController.add('Connected to ${device.platformName}.');
      return true;
    } catch (error) {
      _clearConnection();
      _statusController.add('BLE connection failed: $error');
      return false;
    }
  }

  Future<void> disconnect() async {
    final device = _device;
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _commandCharacteristic = null;
    _statusCharacteristic = null;
    _device = null;
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  Future<bool> pushChargingConfig({
    required String launcherDeviceId,
    required String launcherDeviceName,
    required int startBelowPercent,
    required int stopAtPercent,
    required int relayPin,
  }) async {
    final characteristic = _commandCharacteristic;
    if (characteristic == null) {
      _statusController.add('Connect to a charger controller first.');
      return false;
    }

    final payload = jsonEncode(<String, dynamic>{
      'type': 'charger_config',
      'launcher_device_id': launcherDeviceId,
      'launcher_device_name': launcherDeviceName,
      'start_below_percent': startBelowPercent,
      'stop_at_percent': stopAtPercent,
      'relay_pin': relayPin,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    try {
      await characteristic.write(utf8.encode(payload), withoutResponse: false);
      _statusController.add('Charging config sent to controller.');
      return true;
    } catch (error) {
      _statusController.add('Unable to send charging config: $error');
      return false;
    }
  }

  Future<void> syncChargingDecision({
    required int batteryLevel,
    required int startBelowPercent,
    required int stopAtPercent,
    required int relayPin,
    required String launcherDeviceId,
    required String launcherDeviceName,
  }) async {
    if (batteryLevel < 0 || batteryLevel > 100) {
      return;
    }

    if (!isConnected) {
      final connected = await connectBySavedName();
      if (!connected) {
        return;
      }
    }

    final shouldEnable = _determineRelayState(
      batteryLevel: batteryLevel,
      startBelowPercent: startBelowPercent,
      stopAtPercent: stopAtPercent,
    );

    if (_hasRelayState && shouldEnable == _lastRelayEnabled) {
      return;
    }

    final characteristic = _commandCharacteristic;
    if (characteristic == null) {
      return;
    }

    final payload = jsonEncode(<String, dynamic>{
      'type': 'charger_command',
      'launcher_device_id': launcherDeviceId,
      'launcher_device_name': launcherDeviceName,
      'enabled': shouldEnable,
      'battery_level': batteryLevel,
      'relay_pin': relayPin,
      'reason': shouldEnable ? 'battery_below_start' : 'battery_reached_stop',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    try {
      await characteristic.write(utf8.encode(payload), withoutResponse: false);
      _hasRelayState = true;
      _lastRelayEnabled = shouldEnable;
    } catch (error) {
      _statusController.add('Unable to send charger command: $error');
    }
  }

  bool _determineRelayState({
    required int batteryLevel,
    required int startBelowPercent,
    required int stopAtPercent,
  }) {
    if (!_hasRelayState) {
      return batteryLevel <= startBelowPercent;
    }
    if (batteryLevel <= startBelowPercent) {
      return true;
    }
    if (batteryLevel >= stopAtPercent) {
      return false;
    }
    return _lastRelayEnabled;
  }

  void _clearConnection() {
    _statusSubscription?.cancel();
    _statusSubscription = null;
    _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _commandCharacteristic = null;
    _statusCharacteristic = null;
    _device = null;
  }
}
