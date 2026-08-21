import 'controller_endpoint.dart';
import 'socket_service.dart';
import 'standalone_mqtt_service.dart';

class ControllerCommunicationService {
  ControllerCommunicationService._();

  static final ControllerCommunicationService instance =
      ControllerCommunicationService._();

  ControllerTransport? _activeTransport;
  ControllerEndpoint? _activeEndpoint;
  bool _started = false;

  ControllerEndpoint? get activeEndpoint => _activeEndpoint;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    await applySettings();
  }

  Future<void> applySettings() async {
    final config = await ControllerEndpointConfig.load();
    final endpoint = config.activeEndpoint;
    print(
      '[CONTROLLER] Mode=${endpoint.label} Host=${endpoint.host} Port=${endpoint.port}',
    );

    if (_activeTransport != endpoint.transport) {
      await _stopInactiveTransport(endpoint.transport);
    }

    _activeTransport = endpoint.transport;
    _activeEndpoint = endpoint;
  }

  Future<bool> checkConnection() async {
    await applySettings();
    final endpoint =
        _activeEndpoint ?? (await ControllerEndpointConfig.load()).activeEndpoint;
    return StandaloneMqttService.instance.connectByEndpoint(endpoint);
  }

  Future<void> stop() async {
    if (!_started && _activeTransport == null) {
      return;
    }
    _started = false;
    _activeTransport = null;
    _activeEndpoint = null;
    await StandaloneMqttService.instance.disconnect();
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> _stopInactiveTransport(ControllerTransport nextTransport) async {
    if (nextTransport == ControllerTransport.http) {
      print('[CONTROLLER] stopping socket transport before HTTP');
      await StandaloneMqttService.instance.disconnect();
      return;
    }

    print('[CONTROLLER] stopping HTTP controller transport before socket');
    await StandaloneMqttService.instance.disconnect();
  }

  void stopServerSocket() {
    SocketService.disconnectShared();
  }
}
