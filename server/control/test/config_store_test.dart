import 'dart:io';

import 'package:lanchat_control/config_store.dart';
import 'package:test/test.dart';

void main() {
  test('hashes and verifies admin and access credentials', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-control');
    final store = ConfigStore(File('${directory.path}/config.json'));

    await store.initialize(
      adminPassword: 'admin-password',
      accessCode: 'server-code',
    );

    expect(await store.verifyAdminPassword('admin-password'), isTrue);
    expect(await store.verifyAdminPassword('wrong'), isFalse);
    expect(await store.verifyAccessCode('server-code'), isTrue);
    expect(await store.verifyAccessCode('wrong'), isFalse);
    expect(
      await File('${directory.path}/config.json').readAsString(),
      isNot(contains('admin-password')),
    );
    expect(
      await File('${directory.path}/config.json').readAsString(),
      isNot(contains('server-code')),
    );
    await directory.delete(recursive: true);
  });

  test('rotates the access code without changing the admin password', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-control');
    final store = ConfigStore(File('${directory.path}/config.json'));
    await store.initialize(
      adminPassword: 'admin-password',
      accessCode: 'old-code',
    );

    await store.rotateAccessCode('new-code');

    expect(await store.verifyAccessCode('old-code'), isFalse);
    expect(await store.verifyAccessCode('new-code'), isTrue);
    expect(await store.verifyAdminPassword('admin-password'), isTrue);
    await directory.delete(recursive: true);
  });

  test(
    'changes the administrator password and exposes bounded statistics',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lanchat-control',
      );
      final store = ConfigStore(File('${directory.path}/config.json'));
      await store.initialize(
        adminPassword: 'admin-password',
        accessCode: 'server-code',
      );

      await store.changeAdminPassword('new-admin-password');
      expect(await store.verifyAdminPassword('admin-password'), isFalse);
      expect(await store.verifyAdminPassword('new-admin-password'), isTrue);
      expect(store.allowImage('alice', 1024), isTrue);
      store.recordMessage(userId: 'alice', imageBytes: 1024);
      expect(store.stats()['imageBytes'], 2048);
      await directory.delete(recursive: true);
    },
  );

  test('derives a stable private bridge password from a user hash', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-bridge');
    final file = File('${directory.path}/config.json');
    final first = ConfigStore(file);
    await first.initialize(
      adminPassword: 'admin-password',
      accessCode: 'server-code',
    );
    final hash = await PasswordHash.create('user-password');

    final derived = await first.matrixPasswordFor(hash);
    final restored = ConfigStore(file);
    await restored.load();

    expect(await restored.matrixPasswordFor(hash), derived);
    expect(derived, isNot('user-password'));
    await directory.delete(recursive: true);
  });
}
