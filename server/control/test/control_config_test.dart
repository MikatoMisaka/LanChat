import 'dart:convert';
import 'dart:io';

import 'package:lanchat_control/config_store.dart';
import 'package:lanchat_control/control_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('administrator can switch the server encryption mode', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-control');
    final store = ConfigStore(File('${directory.path}/config.json'));
    await store.initialize(
      adminPassword: 'admin-password',
      accessCode: 'server-code',
    );
    final server = ControlServer(store: store, serverName: 'Example');

    final login = await server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/admin/login'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'password': 'admin-password'}),
      ),
    );
    final loginBody = jsonDecode(await login.readAsString()) as Map<String, dynamic>;
    final token = loginBody['token'] as String;

    final response = await server.handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/admin/config'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $token',
        },
        body: jsonEncode({'encryptionMode': 'readable'}),
      ),
    );

    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body['encryptionMode'], 'readable');
    await directory.delete(recursive: true);
  });
}
