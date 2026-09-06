import 'dart:io';

import 'package:lanchat_control/config_store.dart';
import 'package:lanchat_control/control_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('serves the control-room shell and local assets', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-web');
    final config = ConfigStore(File('${directory.path}/config.json'));
    await config.initialize(
      adminPassword: 'admin-password',
      accessCode: 'group-invite',
    );
    final server = ControlServer(
      store: config,
      serverName: 'Example',
      webDirectory: Directory('web'),
    );

    final html = await server.handler(
      Request('GET', Uri.parse('http://localhost/')),
    );
    final css = await server.handler(
      Request('GET', Uri.parse('http://localhost/styles.css')),
    );
    final js = await server.handler(
      Request('GET', Uri.parse('http://localhost/app.js')),
    );

    expect(html.statusCode, 200);
    expect(await html.readAsString(), contains('data-view="overview"'));
    expect(css.statusCode, 200);
    expect(await css.readAsString(), contains('--jade'));
    expect(js.statusCode, 200);
    expect(await js.readAsString(), contains('/api/v1/admin/requests'));
    await directory.delete(recursive: true);
  });
}
