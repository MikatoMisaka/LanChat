import 'dart:convert';
import 'dart:io';

import 'package:lanchat_control/config_store.dart';
import 'package:lanchat_control/control_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test(
    'administrator cannot switch the server away from client encryption',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lanchat-control',
      );
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
      final loginBody =
          jsonDecode(await login.readAsString()) as Map<String, dynamic>;
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

      expect(response.statusCode, 400);
      final config = await server.handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/admin/config'),
          headers: {'authorization': 'Bearer $token'},
        ),
      );
      final body =
          jsonDecode(await config.readAsString()) as Map<String, dynamic>;
      expect(body['encryptionMode'], 'e2ee');
      await directory.delete(recursive: true);
    },
  );

  test('first initialization returns a one-time setup code', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-setup');
    final store = ConfigStore(File('${directory.path}/config.json'));

    final bootstrapCode = await store.initialize();

    expect(bootstrapCode, isNotNull);
    expect(await store.setupRequired, isTrue);
    await store.completeSetup(
      bootstrapCode: bootstrapCode!,
      adminPassword: 'new-admin-password',
    );
    expect(await store.setupRequired, isFalse);
    expect(await store.verifyAdminPassword('new-admin-password'), isTrue);
    await expectLater(
      store.completeSetup(
        bootstrapCode: bootstrapCode,
        adminPassword: 'another-password',
      ),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });
}
