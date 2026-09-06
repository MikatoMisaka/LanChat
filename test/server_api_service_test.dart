import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lanchat/services/server_api_service.dart';
import 'package:lanchat/services/server_profile.dart';

void main() {
  final profile = ServerProfile(
    id: 'local',
    name: 'Local',
    baseUrl: 'http://127.0.0.1:8080',
    username: 'alice',
  );

  test('fetches server capabilities from the LanChat endpoint', () async {
    final service = ServerApiService(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/server/info');
        return http.Response(
          jsonEncode({
            'serverName': 'Home',
            'setupRequired': false,
            'encryptionMode': 'e2ee',
            'maxImageBytes': 1024,
            'retentionDays': 30,
          }),
          200,
        );
      }),
    );

    final info = await service.fetchInfo(profile);

    expect(info.serverName, 'Home');
    expect(info.setupRequired, isFalse);
    expect(info.maxImageBytes, 1024);
  });

  test('submits a join request and maps a pending device login', () async {
    final service = ServerApiService(
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/join') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['inviteCode'], 'invite');
          expect(body['deviceId'], 'PHONE');
          return http.Response(
            jsonEncode({'requestId': 'request-1', 'status': 'pending'}),
            202,
          );
        }
        expect(request.url.path, '/api/v1/auth/login');
        return http.Response(jsonEncode({'status': 'device_pending'}), 202);
      }),
    );

    final join = await service.submitJoin(
      profile,
      inviteCode: 'invite',
      username: 'alice',
      password: 'user-password',
      displayName: 'Alice',
      deviceId: 'PHONE',
    );
    final login = await service.login(
      profile,
      username: 'alice',
      password: 'user-password',
      deviceId: 'PHONE',
    );

    expect(join.requestId, 'request-1');
    expect(join.status, 'pending');
    expect(login.status, ServerLoginStatus.devicePending);
  });

  test('maps the hidden Matrix session returned after approval', () async {
    final service = ServerApiService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': 'authenticated',
            'token': 'lanchat-session',
            'matrixAccessToken': 'matrix-session',
            'matrixUserId': '@alice:example',
            'matrixDeviceId': 'MATRIX-PHONE',
          }),
          200,
        ),
      ),
    );

    final login = await service.login(
      profile,
      username: 'alice',
      password: 'user-password',
      deviceId: 'PHONE',
    );

    expect(login.status, ServerLoginStatus.authenticated);
    expect(login.token, 'lanchat-session');
    expect(login.matrixAccessToken, 'matrix-session');
    expect(login.matrixUserId, '@alice:example');
    expect(login.matrixDeviceId, 'MATRIX-PHONE');
  });
}
