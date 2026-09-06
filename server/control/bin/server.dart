import 'dart:io';

import 'package:lanchat_control/config_store.dart';
import 'package:lanchat_control/control_server.dart';

Future<void> main() async {
  final configFile = File(
    Platform.environment['LANCHAT_CONFIG_PATH'] ?? '/data/lanchat-control.json',
  );
  final store = ConfigStore(configFile);
  final bootstrapCode = await store.initialize(
    adminPassword: _optionalEnvironment('LANCHAT_BOOTSTRAP_ADMIN_PASSWORD'),
    accessCode: _optionalEnvironment('LANCHAT_BOOTSTRAP_ACCESS_CODE'),
  );
  if (bootstrapCode != null) {
    stdout.writeln('LanChat first-run setup code: $bootstrapCode');
    stdout.writeln(
      'Open the control room and set an administrator password. '
      'This code is shown only once.',
    );
  }
  final serverName =
      Platform.environment['LANCHAT_SERVER_NAME'] ?? 'LanChat Server';
  final matrixServerName = _optionalEnvironment('SYNAPSE_SERVER_NAME');
  if (matrixServerName == null || !isValidMatrixServerName(matrixServerName)) {
    stderr.writeln(
      'SYNAPSE_SERVER_NAME must be a host name such as chat.example.com.',
    );
    exitCode = 1;
    return;
  }
  final synapseUrl = _optionalEnvironment('SYNAPSE_INTERNAL_URL');
  final synapseConfigPath = _optionalEnvironment('SYNAPSE_CONFIG_PATH');
  final synapseToken =
      _optionalEnvironment('SYNAPSE_ADMIN_TOKEN') ??
      await _optionalFile('SYNAPSE_ADMIN_TOKEN_FILE');
  final MatrixGateway? matrixGateway =
      synapseUrl == null || synapseToken == null
      ? null
      : SynapseAdminClient(
          baseUrl: Uri.parse(synapseUrl),
          accessToken: synapseToken,
          serverName: matrixServerName,
        );
  final server = ControlServer(
    store: store,
    serverName: serverName,
    matrixGateway: matrixGateway,
    matrixProxyUrl: synapseUrl == null ? null : Uri.parse(synapseUrl),
    synapseConfigFile: synapseConfigPath == null
        ? null
        : File(synapseConfigPath),
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

Future<String?> _optionalFile(String environmentName) async {
  final path = _optionalEnvironment(environmentName);
  if (path == null) return null;
  final file = File(path);
  if (!await file.exists()) return null;
  final value = (await file.readAsString()).trim();
  return value.isEmpty ? null : value;
}
