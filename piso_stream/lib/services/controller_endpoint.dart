import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';

enum ControllerTransport { socket, http }

class ControllerEndpoint {
  const ControllerEndpoint({
    required this.transport,
    required this.host,
    required this.port,
  });

  final ControllerTransport transport;
  final String host;
  final int port;

  String get label => transport == ControllerTransport.socket ? 'SOCKET' : 'HTTP';

  Uri uri([String path = '', Map<String, String>? queryParameters]) {
    if (transport == ControllerTransport.http) {
      return Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: path,
        queryParameters: queryParameters,
      );
    }

    return Uri(scheme: 'ws', host: host, port: port, path: path);
  }

  @override
  String toString() => '$label $host:$port';
}

class ControllerEndpointConfig {
  const ControllerEndpointConfig({
    required this.mode,
    required this.socketHost,
    required this.socketPort,
    required this.httpHost,
    required this.httpPort,
  });

  final ControllerTransport mode;
  final String socketHost;
  final int socketPort;
  final String httpHost;
  final int httpPort;

  ControllerEndpoint get activeEndpoint {
    if (mode == ControllerTransport.http) {
      return ControllerEndpoint(
        transport: ControllerTransport.http,
        host: httpHost,
        port: httpPort,
      );
    }

    return ControllerEndpoint(
      transport: ControllerTransport.socket,
      host: socketHost,
      port: socketPort,
    );
  }

  static Future<ControllerEndpointConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final legacyHost =
        prefs.getString(AppSettings.standaloneControllerIpKey)?.trim();
    final fallbackHost =
        legacyHost == null || legacyHost.isEmpty
            ? AppSettings.defaultStandaloneControllerIp
            : legacyHost;
    final modeValue =
        prefs.getString(AppSettings.controllerCommunicationModeKey) ??
        AppSettings.controllerCommunicationModeSocket;

    final socketHost =
        prefs.getString(AppSettings.controllerSocketHostKey)?.trim();
    final httpHost = prefs.getString(AppSettings.controllerHttpHostKey)?.trim();

    return ControllerEndpointConfig(
      mode: modeValue == AppSettings.controllerCommunicationModeHttp
          ? ControllerTransport.http
          : ControllerTransport.socket,
      socketHost: socketHost == null || socketHost.isEmpty
          ? fallbackHost
          : socketHost,
      socketPort:
          prefs.getInt(AppSettings.controllerSocketPortKey) ??
          AppSettings.defaultControllerSocketPort,
      httpHost: httpHost == null || httpHost.isEmpty ? fallbackHost : httpHost,
      httpPort:
          prefs.getInt(AppSettings.controllerHttpPortKey) ??
          AppSettings.defaultControllerHttpPort,
    );
  }
}
