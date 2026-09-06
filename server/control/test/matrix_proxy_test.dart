import 'dart:io';

import 'package:lanchat_control/config_store.dart';
import 'package:lanchat_control/control_server.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

void main() {
  test(
    'proxies unknown Matrix paths through the LanChat entry point',
    () async {
      final upstream = await shelf_io.serve(
        (request) => Response.ok(
          'matrix-upstream',
          headers: const {'content-type': 'text/plain'},
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      final directory = await Directory.systemTemp.createTemp('lanchat-proxy');
      final config = ConfigStore(File('${directory.path}/config.json'));
      await config.initialize(
        adminPassword: 'admin-password',
        accessCode: 'group-invite',
      );
      final server = ControlServer(
        store: config,
        serverName: 'Example',
        matrixProxyUrl: Uri.parse('http://127.0.0.1:${upstream.port}'),
      );

      final response = await server.handler(
        Request(
          'GET',
          Uri.parse('http://localhost/_matrix/client/versions?test=1'),
        ),
      );

      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'matrix-upstream');
      await upstream.close(force: true);
      await directory.delete(recursive: true);
    },
  );

  test('rejects a media upload above the configured file limit', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-proxy');
    final config = ConfigStore(File('${directory.path}/config.json'));
    await config.initialize(
      adminPassword: 'admin-password',
      accessCode: 'group-invite',
    );
    await config.update(maxFileBytes: 1024);
    final server = ControlServer(
      store: config,
      serverName: 'Example',
      matrixProxyUrl: Uri.parse('http://127.0.0.1:1'),
    );

    final response = await server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/_matrix/media/v3/upload'),
        headers: const {'content-type': 'application/octet-stream'},
        body: List<int>.filled(2048, 0),
      ),
    );

    expect(response.statusCode, 413);
    await directory.delete(recursive: true);
  });

  test('rejects a chunked media upload while it is being streamed', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-proxy');
    final config = ConfigStore(File('${directory.path}/config.json'));
    await config.initialize(
      adminPassword: 'admin-password',
      accessCode: 'group-invite',
    );
    await config.update(maxFileBytes: 1024);
    final server = ControlServer(
      store: config,
      serverName: 'Example',
      matrixProxyUrl: Uri.parse('http://127.0.0.1:1'),
    );

    final response = await server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/_matrix/media/v3/upload'),
        headers: const {'content-type': 'application/octet-stream'},
        body: Stream<List<int>>.fromIterable([List<int>.filled(2048, 0)]),
      ),
    );

    expect(response.statusCode, 413);
    await directory.delete(recursive: true);
  });
}
