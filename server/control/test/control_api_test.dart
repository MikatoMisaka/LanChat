import 'dart:convert';
import 'dart:io';

import 'package:lanchat_control/config_store.dart';
import 'package:lanchat_control/control_server.dart';
import 'package:lanchat_control/join_store.dart';
import 'package:lanchat_control/session_store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('supports setup, join approval, and per-device approval', () async {
    final directory = await Directory.systemTemp.createTemp('lanchat-api');
    final config = ConfigStore(File('${directory.path}/config.json'));
    final bootstrapCode = await config.initialize();
    final joinStore = JoinStore(
      File('${directory.path}/joins.json'),
      config: config,
    );
    final sessionStore = SessionStore(File('${directory.path}/sessions.json'));
    final matrixGateway = _FakeMatrixGateway();
    final server = ControlServer(
      store: config,
      serverName: 'Example',
      matrixServerName: 'example',
      joinStore: joinStore,
      sessionStore: sessionStore,
      matrixGateway: matrixGateway,
    );

    final info = await _send(server, 'GET', '/api/v1/server/info');
    expect(info.statusCode, 200);
    final infoBody = await _body(info);
    expect(infoBody['setupRequired'], isTrue);
    expect(infoBody['maxFileBytes'], 100 * 1024 * 1024);

    final setup = await _send(
      server,
      'POST',
      '/api/v1/admin/setup',
      body: {'bootstrapCode': bootstrapCode, 'password': 'admin-password'},
    );
    expect(setup.statusCode, 200);
    final adminToken = (await _body(setup))['token'] as String;

    final rotate = await _send(
      server,
      'POST',
      '/api/v1/admin/access-code/rotate',
      token: adminToken,
      body: {'accessCode': 'group-invite'},
    );
    expect(rotate.statusCode, 200);

    final stats = await _send(
      server,
      'GET',
      '/api/v1/admin/stats',
      token: adminToken,
    );
    final statsBody = await _body(stats);
    expect(statsBody['matrixBridgeConfigured'], isTrue);
    expect(statsBody['matrixProxyConfigured'], isFalse);

    final invitationResponse = await _send(
      server,
      'POST',
      '/api/v1/admin/invitations',
      token: adminToken,
      body: {'singleUse': false, 'lifetimeDays': 30},
    );
    expect(invitationResponse.statusCode, 200);
    final invitationCode = (await _body(invitationResponse))['code'] as String;
    final invitations = await _send(
      server,
      'GET',
      '/api/v1/admin/invitations',
      token: adminToken,
    );
    final invitationBody = await _body(invitations);
    expect(invitations.statusCode, 200);
    final invitationId =
        (invitationBody['invitations'] as List).single['id'] as String;
    expect(invitationBody['invitations'], hasLength(1));
    final revokeInvitation = await _send(
      server,
      'DELETE',
      '/api/v1/admin/invitations/$invitationId',
      token: adminToken,
    );
    expect(revokeInvitation.statusCode, 200);
    expect(invitationCode, isNotEmpty);

    final join = await _send(
      server,
      'POST',
      '/api/v1/auth/join',
      body: {
        'inviteCode': 'group-invite',
        'username': 'alice',
        'password': 'user-password',
        'displayName': 'Alice',
        'deviceId': 'PHONE',
      },
    );
    expect(join.statusCode, 202);
    final requestId = (await _body(join))['requestId'] as String;

    final pending = await _send(
      server,
      'GET',
      '/api/v1/admin/requests',
      token: adminToken,
    );
    expect(pending.statusCode, 200);
    expect(
      ((await _body(pending))['requests'] as List).single['id'],
      requestId,
    );

    final approve = await _send(
      server,
      'POST',
      '/api/v1/admin/requests/$requestId/approve',
      token: adminToken,
    );
    expect(approve.statusCode, 200);

    final firstLogin = await _send(
      server,
      'POST',
      '/api/v1/auth/login',
      body: {
        'username': 'alice',
        'password': 'user-password',
        'deviceId': 'PHONE',
      },
    );
    expect(firstLogin.statusCode, 200);
    final firstLoginBody = await _body(firstLogin);
    expect(firstLoginBody['status'], 'authenticated');
    expect(firstLoginBody['matrixAccessToken'], 'matrix-token');
    expect(matrixGateway.createdUsers, contains('alice'));
    expect(
      (await joinStore.devicesForUser('alice')).single.matrixDeviceId,
      'MATRIX-PHONE',
    );
    final aliceToken = firstLoginBody['token'] as String;

    final bobJoin = await _send(
      server,
      'POST',
      '/api/v1/auth/join',
      body: {
        'inviteCode': 'group-invite',
        'username': 'bob',
        'password': 'user-password',
        'displayName': 'Bob',
        'deviceId': 'PHONE',
      },
    );
    final bobRequestId = (await _body(bobJoin))['requestId'] as String;
    await _send(
      server,
      'POST',
      '/api/v1/admin/requests/$bobRequestId/approve',
      token: adminToken,
    );
    final directoryResponse = await _send(
      server,
      'GET',
      '/api/v1/directory/users',
      token: aliceToken,
    );
    final directoryBody = await _body(directoryResponse);
    expect(directoryResponse.statusCode, 200);
    expect((directoryBody['users'] as List).single['username'], 'bob');
    expect((directoryBody['users'] as List).single['userId'], '@bob:example');

    final secondLogin = await _send(
      server,
      'POST',
      '/api/v1/auth/login',
      body: {
        'username': 'alice',
        'password': 'user-password',
        'deviceId': 'LAPTOP',
      },
    );
    expect(secondLogin.statusCode, 202);
    expect((await _body(secondLogin))['status'], 'device_pending');

    final devices = await _send(
      server,
      'GET',
      '/api/v1/admin/devices/pending',
      token: adminToken,
    );
    expect(devices.statusCode, 200);
    expect(
      ((await _body(devices))['devices'] as List).single['deviceId'],
      'LAPTOP',
    );

    final approveDevice = await _send(
      server,
      'POST',
      '/api/v1/admin/users/alice/devices/LAPTOP/approve',
      token: adminToken,
    );
    expect(approveDevice.statusCode, 200);

    final laptopLogin = await _send(
      server,
      'POST',
      '/api/v1/auth/login',
      body: {
        'username': 'alice',
        'password': 'user-password',
        'deviceId': 'LAPTOP',
      },
    );
    expect(laptopLogin.statusCode, 200);
    final laptopLoginBody = await _body(laptopLogin);
    expect(laptopLoginBody['status'], 'authenticated');
    final laptopToken = laptopLoginBody['token'] as String;

    final me = await _send(server, 'GET', '/api/v1/me', token: laptopToken);
    expect(me.statusCode, 200);

    final requestStatus = await _send(
      server,
      'GET',
      '/api/v1/auth/join/$requestId',
    );
    expect((await _body(requestStatus))['status'], 'approved');

    final revoke = await _send(
      server,
      'DELETE',
      '/api/v1/admin/users/alice/devices/LAPTOP',
      token: adminToken,
    );
    expect(revoke.statusCode, 200);
    expect(matrixGateway.revokedDevices, contains('alice:MATRIX-PHONE'));
    final revokedMe = await _send(
      server,
      'GET',
      '/api/v1/me',
      token: laptopToken,
    );
    expect(revokedMe.statusCode, 401);
    await directory.delete(recursive: true);
  });
}

class _FakeMatrixGateway implements MatrixGateway {
  final createdUsers = <String>[];
  final revokedDevices = <String>[];

  @override
  Future<void> createUser(
    String username,
    String password,
    String displayName,
  ) async {
    createdUsers.add(username);
  }

  @override
  Future<MatrixLogin> loginUser(String username, String password) async =>
      const MatrixLogin(
        accessToken: 'matrix-token',
        userId: '@alice:example',
        deviceId: 'MATRIX-PHONE',
      );

  @override
  Future<String?> userIdForToken(String accessToken) async => '@alice:example';

  @override
  Future<void> revokeUserDevice(String username, String matrixDeviceId) async {
    revokedDevices.add('$username:$matrixDeviceId');
  }

  @override
  Future<void> updatePassword(String username, String password) async {}

  @override
  Future<void> setUserDisabled({
    required String username,
    required bool disabled,
    required String matrixPassword,
    required String displayName,
  }) async {}
}

Future<Response> _send(
  ControlServer server,
  String method,
  String path, {
  Map<String, Object?>? body,
  String? token,
}) async {
  final headers = <String, String>{'content-type': 'application/json'};
  if (token != null) headers['authorization'] = 'Bearer $token';
  return await server.handler(
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: headers,
      body: body == null ? null : jsonEncode(body),
    ),
  );
}

Future<Map<String, dynamic>> _body(Response response) async =>
    jsonDecode(await response.readAsString()) as Map<String, dynamic>;
