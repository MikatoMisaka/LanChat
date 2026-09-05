import 'dart:io';

import 'package:lanchat_control/config_store.dart';
import 'package:lanchat_control/control_server.dart';

Future<void> main() async {
  final configFile = File(
    Platform.environment['LANCHAT_CONFIG_PATH'] ?? '/data/lanchat-control.json',
  );
  final store = ConfigStore(configFile);
  await store.initialize(
    adminPassword:
        Platform.environment['LANCHAT_BOOTSTRAP_ADMIN_PASSWORD'] ?? '',
    accessCode: Platform.environment['LANCHAT_BOOTSTRAP_ACCESS_CODE'] ?? '',
  );
  final server = ControlServer(
    store: store,
    serverName: Platform.environment['LANCHAT_SERVER_NAME'] ?? 'LanChat Server',
    synapseUrl: _optionalEnvironment('SYNAPSE_INTERNAL_URL'),
    synapseAdminToken: _optionalEnvironment('SYNAPSE_ADMIN_TOKEN'),
    webDirectory: Directory(
      Platform.environment['LANCHAT_WEB_ROOT'] ?? '/app/web',
    ),
  );
  final httpServer = await server.start(
    host: Platform.environment['LANCHAT_CONTROL_HOST'] ?? '0.0.0.0',
    port:
        int.tryParse(Platform.environment['LANCHAT_CONTROL_PORT'] ?? '') ??
        8080,
  );
  stdout.writeln(
    'LanChat control listening on ${httpServer.address.host}:${httpServer.port}',
  );
}

String? _optionalEnvironment(String name) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) return null;
  return value.trim();
}
