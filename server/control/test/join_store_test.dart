import 'dart:io';

import 'package:lanchat_control/config_store.dart';
import 'package:lanchat_control/join_store.dart';
import 'package:test/test.dart';

void main() {
  test('stores a pending request, approves it, and never stores plaintext passwords', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-join');
    final config = ConfigStore(File('${directory.path}/config.json'));
    await config.initialize(
      adminPassword: 'admin-password',
      accessCode: 'group-invite',
    );
    final store = JoinStore(
      File('${directory.path}/joins.json'),
      config: config,
    );

    final request = await store.submit(
      inviteCode: 'group-invite',
      username: 'alice',
      password: 'user-password',
      displayName: 'Alice',
      deviceId: 'PHONE',
    );

    expect(request.status, JoinRequestStatus.pending);
    expect((await store.pendingRequests()).single.id, request.id);
    expect(
      await File('${directory.path}/joins.json').readAsString(),
      isNot(contains('user-password')),
    );

    final user = await store.approve(request.id);

    expect(user.username, 'alice');
    expect(await user.passwordHash.verify('user-password'), isTrue);
    expect(await store.findUser('alice'), isNotNull);
    await directory.delete(recursive: true);
  });

  test('a single-use invitation can be consumed only once', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-join');
    final config = ConfigStore(File('${directory.path}/config.json'));
    await config.initialize(
      adminPassword: 'admin-password',
      accessCode: 'group-invite',
    );
    final store = JoinStore(
      File('${directory.path}/joins.json'),
      config: config,
    );
    final invitation = await store.issueInvitation();

    await store.submit(
      inviteCode: invitation,
      username: 'alice',
      password: 'user-password',
      displayName: 'Alice',
      deviceId: 'PHONE',
    );

    await expectLater(
      store.submit(
        inviteCode: invitation,
        username: 'bob',
        password: 'user-password',
        displayName: 'Bob',
        deviceId: 'PHONE',
      ),
      throwsA(isA<JoinStoreException>()),
    );
    await directory.delete(recursive: true);
  });

  test('rejects malformed join requests before writing them', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-join');
    final config = ConfigStore(File('${directory.path}/config.json'));
    await config.initialize(
      adminPassword: 'admin-password',
      accessCode: 'group-invite',
    );
    final store = JoinStore(
      File('${directory.path}/joins.json'),
      config: config,
    );

    await expectLater(
      store.submit(
        inviteCode: 'wrong-code',
        username: 'alice',
        password: 'short',
        displayName: 'Alice',
        deviceId: 'PHONE',
      ),
      throwsA(isA<JoinStoreException>()),
    );
    expect(await File('${directory.path}/joins.json').exists(), isFalse);
    await directory.delete(recursive: true);
  });

  test('requires approval before a second device can sign in', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-join');
    final config = ConfigStore(File('${directory.path}/config.json'));
    await config.initialize(
      adminPassword: 'admin-password',
      accessCode: 'group-invite',
    );
    final store = JoinStore(
      File('${directory.path}/joins.json'),
      config: config,
    );

    final request = await store.submit(
      inviteCode: 'group-invite',
      username: 'alice',
      password: 'user-password',
      displayName: 'Alice',
      deviceId: 'PHONE',
    );
    await store.approve(request.id);

    final pending = await store.authenticate(
      username: 'alice',
      password: 'user-password',
      deviceId: 'LAPTOP',
    );
    expect(pending.status, UserLoginStatus.devicePending);
    expect((await store.pendingDevices()).single.deviceId, 'LAPTOP');

    await store.approveDevice(userId: 'alice', deviceId: 'LAPTOP');
    final authenticated = await store.authenticate(
      username: 'alice',
      password: 'user-password',
      deviceId: 'LAPTOP',
    );
    expect(authenticated.status, UserLoginStatus.authenticated);

    await store.revokeDevice(userId: 'alice', deviceId: 'LAPTOP');
    final revoked = await store.authenticate(
      username: 'alice',
      password: 'user-password',
      deviceId: 'LAPTOP',
    );
    expect(revoked.status, UserLoginStatus.deviceRevoked);
    await directory.delete(recursive: true);
  });

  test('disabled users cannot authenticate', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-join');
    final config = ConfigStore(File('${directory.path}/config.json'));
    await config.initialize(
      adminPassword: 'admin-password',
      accessCode: 'group-invite',
    );
    final store = JoinStore(
      File('${directory.path}/joins.json'),
      config: config,
    );

    final request = await store.submit(
      inviteCode: 'group-invite',
      username: 'alice',
      password: 'user-password',
      displayName: 'Alice',
      deviceId: 'PHONE',
    );
    await store.approve(request.id);
    await store.setUserDisabled('alice', true);

    final result = await store.authenticate(
      username: 'alice',
      password: 'user-password',
      deviceId: 'PHONE',
    );
    expect(result.status, UserLoginStatus.disabled);
    await directory.delete(recursive: true);
  });
}
