import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:lanchat_control/control_server.dart';
import 'package:test/test.dart';

void main() {
  test("resets a user's password through the Synapse admin API", () async {
    final client = RecordingHttpClient();
    final admin = SynapseAdminClient(
      baseUrl: Uri.parse('https://chat.example.com'),
      accessToken: 'synapse-admin-token',
      serverName: 'chat.example.com',
      client: client,
    );

    await admin.resetUserPassword('@alice:chat.example.com', 'new-password');

    expect(client.method, 'PUT');
    expect(
      client.url.toString(),
      'https://chat.example.com/_synapse/admin/v2/users/%40alice%3Achat.example.com',
    );
    expect(client.headers['authorization'], 'Bearer synapse-admin-token');
    expect(jsonDecode(client.body)['password'], 'new-password');
  });

  test("lists and revokes a user's devices", () async {
    final client = RecordingHttpClient(responseBody: '[{"device_id":"PHONE"}]');
    final admin = SynapseAdminClient(
      baseUrl: Uri.parse('https://chat.example.com'),
      accessToken: 'synapse-admin-token',
      serverName: 'chat.example.com',
      client: client,
    );

    expect(await admin.listDevices('@alice:chat.example.com'), hasLength(1));
    expect(client.method, 'GET');
    await admin.revokeDevice('@alice:chat.example.com', 'PHONE');

    expect(client.method, 'DELETE');
    expect(
      client.url.toString(),
      'https://chat.example.com/_synapse/admin/v2/users/%40alice%3Achat.example.com/devices/PHONE',
    );
  });
}

class RecordingHttpClient extends http.BaseClient {
  RecordingHttpClient({this.responseBody = '[]'});

  final String responseBody;
  String method = '';
  Uri url = Uri.parse('https://localhost');
  String body = '';
  Map<String, String> headers = {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    method = request.method;
    url = request.url;
    headers = request.headers;
    body = await request.finalize().bytesToString();
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(responseBody)),
      200,
      headers: const {'content-type': 'application/json'},
      request: request,
    );
  }
}
