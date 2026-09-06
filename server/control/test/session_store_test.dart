import 'dart:io';

import 'package:lanchat_control/session_store.dart';
import 'package:test/test.dart';

void main() {
  test('creates, looks up, and revokes a device session', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-session');
    final store = SessionStore(File('${directory.path}/sessions.json'));

    final token = await store.create(userId: 'alice', deviceId: 'PHONE');

    expect((await store.lookup(token))?.userId, 'alice');
    expect(await store.lookup('wrong-token'), isNull);
    await store.revokeDevice(userId: 'alice', deviceId: 'PHONE');
    expect(await store.lookup(token), isNull);
    expect(
      await File('${directory.path}/sessions.json').readAsString(),
      isNot(contains(token)),
    );
    await directory.delete(recursive: true);
  });

  test('revokes a token and reports unexpired sessions', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-session');
    final store = SessionStore(File('${directory.path}/sessions.json'));

    final token = await store.create(userId: 'alice', deviceId: 'PHONE');
    expect((await store.activeSessions()).length, 1);

    await store.revokeToken(token);

    expect(await store.activeSessions(), isEmpty);
    await directory.delete(recursive: true);
  });
}
