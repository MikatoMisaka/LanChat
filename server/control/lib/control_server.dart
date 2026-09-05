// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'config_store.dart';

class ControlServer {
  ControlServer({
    required this.store,
    required this.serverName,
    this.synapseUrl,
    this.synapseAdminToken,
    Directory? webDirectory,
  }) : _webDirectory = webDirectory;

  final ConfigStore store;
  final String serverName;
  final String? synapseUrl;
  final String? synapseAdminToken;
  final Directory? _webDirectory;
  final Map<String, DateTime> _adminSessions = {};
  final _random = Random.secure();
  HttpServer? _server;

  Handler get handler {
    final router = Router()
      ..get('/', _index)
      ..get('/healthz', _health)
      ..post('/_lanchat/v1/access/verify', _verifyAccess)
      ..get('/_lanchat/v1/access/authorize', _authorizeAccess)
      ..post('/api/v1/usage/message', _recordMessage)
      ..post('/api/v1/admin/login', _adminLogin)
      ..get('/api/v1/admin/config', _adminConfig)
      ..put('/api/v1/admin/config', _updateConfig)
      ..post('/api/v1/admin/password', _changePassword)
      ..post('/api/v1/admin/access-code/rotate', _rotateAccessCode)
      ..get('/api/v1/admin/stats', _adminStats)
      ..get('/api/v1/admin/users', _listUsers)
      ..post('/api/v1/admin/users', _createUser)
      ..post('/api/v1/admin/users/<userId>/password', _resetUserPassword)
      ..get('/api/v1/admin/users/<userId>/devices', _listUserDevices)
      ..delete('/api/v1/admin/users/<userId>/devices/<deviceId>', _revokeDevice)
      ..post('/api/v1/admin/users/<userId>/deactivate', _deactivateUser);
    return const Pipeline().addHandler(router.call);
  }

  Future<HttpServer> start({String host = '0.0.0.0', int port = 8080}) async {
    _server = await shelf_io.serve(handler, host, port);
    return _server!;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<Response> _index(Request request) async {
    final directory = _webDirectory;
    final file = directory == null
        ? null
        : File('${directory.path}${Platform.pathSeparator}index.html');
    if (file != null && await file.exists()) {
      return Response.ok(
        await file.readAsString(),
        headers: const {'content-type': 'text/html; charset=utf-8'},
      );
    }
    return _json({'name': 'LanChat Control', 'status': 'ok'});
  }

  Response _health(Request request) => _json({'status': 'ok'});

  Future<Response> _verifyAccess(Request request) async {
    final body = await _readJson(request);
    final code = body['accessCode'];
    if (code is! String || !await store.verifyAccessCode(code)) {
      return _json({'error': 'invalid_access_code'}, status: 401);
    }
    final config = await store.config;
    return _json({
      'serverName': serverName,
      'encryptionMode': config.encryptionMode,
      'maxImageBytes': config.maxImageBytes,
      'retentionDays': config.retentionDays,
    });
  }

  Future<Response> _authorizeAccess(Request request) async {
    final code = request.headers['x-lanchat-access-code'];
    if (code == null || !await store.verifyAccessCode(code)) {
      return Response.forbidden('Invalid LanChat access code.');
    }
    return Response.ok('ok');
  }

  Future<Response> _recordMessage(Request request) async {
    final code = request.headers['x-lanchat-access-code'];
    if (code == null || !await store.verifyAccessCode(code)) {
      return _json({'error': 'invalid_access_code'}, status: 401);
    }
    final body = await _readJson(request);
    final userId = body['userId'];
    final imageBytes = body['imageBytes'] ?? 0;
    if (userId is! String || imageBytes is! int || imageBytes < 0) {
      return _json({'error': 'invalid_usage'}, status: 400);
    }
    if (imageBytes > 0 && !store.allowImage(userId, imageBytes)) {
      return _json({'error': 'image_quota_exceeded'}, status: 429);
    }
    store.recordMessage(userId: userId);
    return _json({'ok': true});
  }

  Future<Response> _adminLogin(Request request) async {
    final body = await _readJson(request);
    final password = body['password'];
    if (password is! String || !await store.verifyAdminPassword(password)) {
      return _json({'error': 'invalid_admin_password'}, status: 401);
    }
    final token = base64UrlEncode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    _adminSessions[token] = DateTime.now().add(const Duration(hours: 12));
    return _json({'token': token, 'expiresInSeconds': 12 * 60 * 60});
  }

  Future<Response?> _requireAdmin(Request request) async {
    final header = request.headers['authorization'];
    final token = header != null && header.startsWith('Bearer ')
        ? header.substring(7)
        : null;
    final expiresAt = token == null ? null : _adminSessions[token];
    if (expiresAt == null || expiresAt.isBefore(DateTime.now())) {
      if (token != null) _adminSessions.remove(token);
      return _json({'error': 'admin_login_required'}, status: 401);
    }
    return null;
  }

  Future<Response> _adminConfig(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final config = await store.config;
    return _json({
      'serverName': serverName,
      'encryptionMode': config.encryptionMode,
      'maxImageBytes': config.maxImageBytes,
      'retentionDays': config.retentionDays,
      'perUserDailyImageBytes': config.perUserDailyImageBytes,
      'globalDailyImageBytes': config.globalDailyImageBytes,
      'synapseConfigured': synapseUrl != null && synapseAdminToken != null,
    });
  }

  Future<Response> _updateConfig(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final body = await _readJson(request);
    try {
      await store.update(
        encryptionMode: body['encryptionMode'] is String
            ? body['encryptionMode'] as String
            : null,
        maxImageBytes: _optionalInt(body['maxImageBytes']),
        retentionDays: _optionalInt(body['retentionDays']),
        perUserDailyImageBytes: _optionalInt(body['perUserDailyImageBytes']),
        globalDailyImageBytes: _optionalInt(body['globalDailyImageBytes']),
      );
      return await _adminConfig(request);
    } catch (error) {
      return _json({'error': '$error'}, status: 400);
    }
  }

  Future<Response> _changePassword(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final body = await _readJson(request);
    final password = body['password'];
    if (password is! String) {
      return _json({'error': 'invalid_password'}, status: 400);
    }
    try {
      await store.changeAdminPassword(password);
      return _json({'ok': true});
    } catch (error) {
      return _json({'error': '$error'}, status: 400);
    }
  }

  Future<Response> _rotateAccessCode(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final body = await _readJson(request);
    final code = body['accessCode'];
    if (code is! String) {
      return _json({'error': 'invalid_access_code'}, status: 400);
    }
    try {
      await store.rotateAccessCode(code);
      return _json({'ok': true});
    } catch (error) {
      return _json({'error': '$error'}, status: 400);
    }
  }

  Future<Response> _adminStats(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    return _json(store.stats());
  }

  Future<Response> _listUsers(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final admin = _synapseAdmin;
    if (admin == null) return _json({'users': [], 'configured': false});
    try {
      return _json({'users': await admin.listUsers(), 'configured': true});
    } catch (error) {
      return _json({'error': '$error'}, status: 502);
    }
  }

  Future<Response> _createUser(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final admin = _synapseAdmin;
    if (admin == null) {
      return _json({'error': 'synapse_not_configured'}, status: 503);
    }
    final body = await _readJson(request);
    final username = body['username'];
    final password = body['password'];
    final displayName = body['displayName'];
    if (username is! String || password is! String) {
      return _json({'error': 'invalid_user'}, status: 400);
    }
    try {
      await admin.createUser(
        username,
        password,
        displayName is String ? displayName : null,
      );
      return _json({'ok': true});
    } catch (error) {
      return _json({'error': '$error'}, status: 502);
    }
  }

  Future<Response> _deactivateUser(Request request, String userId) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final admin = _synapseAdmin;
    if (admin == null) {
      return _json({'error': 'synapse_not_configured'}, status: 503);
    }
    try {
      await admin.deactivateUser(Uri.decodeComponent(userId));
      return _json({'ok': true});
    } catch (error) {
      return _json({'error': '$error'}, status: 502);
    }
  }

  Future<Response> _resetUserPassword(Request request, String userId) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final admin = _synapseAdmin;
    if (admin == null) {
      return _json({'error': 'synapse_not_configured'}, status: 503);
    }
    final body = await _readJson(request);
    final password = body['password'];
    if (password is! String) {
      return _json({'error': 'invalid_password'}, status: 400);
    }
    try {
      await admin.resetUserPassword(Uri.decodeComponent(userId), password);
      return _json({'ok': true});
    } catch (error) {
      return _json({'error': '$error'}, status: 502);
    }
  }

  Future<Response> _listUserDevices(Request request, String userId) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final admin = _synapseAdmin;
    if (admin == null) {
      return _json({'error': 'synapse_not_configured'}, status: 503);
    }
    try {
      return _json({
        'devices': await admin.listDevices(Uri.decodeComponent(userId)),
      });
    } catch (error) {
      return _json({'error': '$error'}, status: 502);
    }
  }

  Future<Response> _revokeDevice(
    Request request,
    String userId,
    String deviceId,
  ) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final admin = _synapseAdmin;
    if (admin == null) {
      return _json({'error': 'synapse_not_configured'}, status: 503);
    }
    try {
      await admin.revokeDevice(
        Uri.decodeComponent(userId),
        Uri.decodeComponent(deviceId),
      );
      return _json({'ok': true});
    } catch (error) {
      return _json({'error': '$error'}, status: 502);
    }
  }

  SynapseAdminClient? get _synapseAdmin {
    final baseUrl = synapseUrl;
    final token = synapseAdminToken;
    if (baseUrl == null || token == null || token.isEmpty) return null;
    return SynapseAdminClient(
      baseUrl: Uri.parse(baseUrl),
      accessToken: token,
      serverName: serverName,
    );
  }

  Future<Map<String, dynamic>> _readJson(Request request) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in request.read()) {
      length += chunk.length;
      if (length > 64 * 1024) throw const FormatException('Request too large.');
      builder.add(chunk);
    }
    final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    if (decoded is! Map) throw const FormatException('JSON object required.');
    return Map<String, dynamic>.from(decoded);
  }

  Response _json(Object body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  int? _optionalInt(Object? value) => value is int ? value : null;
}

class SynapseAdminClient {
  SynapseAdminClient({
    required this.baseUrl,
    required this.accessToken,
    required this.serverName,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String accessToken;
  final String serverName;
  final http.Client _client;

  Future<List<Map<String, dynamic>>> listUsers() async {
    final response = await _client.get(
      baseUrl.resolve('/_synapse/admin/v2/users?from=0&limit=100'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception('Synapse users: ${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    if (body is! List) return [];
    return body
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<void> createUser(
    String username,
    String password,
    String? displayName,
  ) async {
    if (!RegExp(r'^[a-z0-9._=-]{1,64}$').hasMatch(username)) {
      throw ArgumentError.value(username, 'username');
    }
    if (password.length < 8) {
      throw ArgumentError('Password must contain 8 characters.');
    }
    final userId = '@$username:$serverName';
    final response = await _client.put(
      baseUrl.resolve(
        '/_synapse/admin/v2/users/${Uri.encodeComponent(userId)}',
      ),
      headers: {..._headers, 'content-type': 'application/json'},
      body: jsonEncode({
        'password': password,
        'displayname': displayName ?? username,
        'deactivated': false,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Synapse create user: ${response.statusCode}');
    }
  }

  Future<void> resetUserPassword(String userId, String password) async {
    if (userId.trim().isEmpty) throw ArgumentError.value(userId, 'userId');
    if (password.length < 8) {
      throw ArgumentError('Password must contain 8 characters.');
    }
    final response = await _client.put(
      baseUrl.resolve(
        '/_synapse/admin/v2/users/${Uri.encodeComponent(userId)}',
      ),
      headers: {..._headers, 'content-type': 'application/json'},
      body: jsonEncode({'password': password}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Synapse reset password: ${response.statusCode}');
    }
  }

  Future<List<Map<String, dynamic>>> listDevices(String userId) async {
    final response = await _client.get(
      baseUrl.resolve(
        '/_synapse/admin/v2/users/${Uri.encodeComponent(userId)}/devices',
      ),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception('Synapse devices: ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    final rows = decoded is List
        ? decoded
        : decoded is Map && decoded['devices'] is List
        ? decoded['devices'] as List
        : const [];
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<void> revokeDevice(String userId, String deviceId) async {
    if (userId.trim().isEmpty || deviceId.trim().isEmpty) {
      throw ArgumentError('User and device identifiers are required.');
    }
    final response = await _client.delete(
      baseUrl.resolve(
        '/_synapse/admin/v2/users/${Uri.encodeComponent(userId)}/devices/${Uri.encodeComponent(deviceId)}',
      ),
      headers: _headers,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Synapse revoke device: ${response.statusCode}');
    }
  }

  Future<void> deactivateUser(String userId) async {
    final response = await _client.post(
      baseUrl.resolve(
        '/_synapse/admin/v2/users/${Uri.encodeComponent(userId)}/deactivate',
      ),
      headers: {..._headers, 'content-type': 'application/json'},
      body: jsonEncode({'erase': false}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Synapse deactivate user: ${response.statusCode}');
    }
  }

  Map<String, String> get _headers => {'authorization': 'Bearer $accessToken'};
}
