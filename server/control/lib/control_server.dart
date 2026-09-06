import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'config_store.dart';
import 'join_store.dart';
import 'session_store.dart';

class MatrixLogin {
  const MatrixLogin({
    required this.accessToken,
    required this.userId,
    required this.deviceId,
  });

  final String accessToken;
  final String userId;
  final String deviceId;
}

abstract interface class MatrixGateway {
  Future<void> createUser(String username, String password, String displayName);

  Future<MatrixLogin> loginUser(String username, String password);

  Future<void> revokeUserDevice(String username, String matrixDeviceId);

  Future<void> updatePassword(String username, String password);

  Future<void> setUserDisabled({
    required String username,
    required bool disabled,
    required String matrixPassword,
    required String displayName,
  });
}

class MatrixGatewayException implements Exception {
  MatrixGatewayException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ControlServer {
  ControlServer({
    required this.store,
    required this.serverName,
    JoinStore? joinStore,
    SessionStore? sessionStore,
    this.matrixGateway,
    this.matrixProxyUrl,
    http.Client? proxyClient,
    this.webDirectory,
  }) : joinStore =
           joinStore ??
           JoinStore(
             File(
               '${store.file.parent.path}${Platform.pathSeparator}joins.json',
             ),
             config: store,
           ),
       sessionStore =
           sessionStore ??
           SessionStore(
             File(
               '${store.file.parent.path}${Platform.pathSeparator}sessions.json',
             ),
           ),
       _proxyClient = proxyClient ?? http.Client();

  final ConfigStore store;
  final String serverName;
  final JoinStore joinStore;
  final SessionStore sessionStore;
  final MatrixGateway? matrixGateway;
  final Uri? matrixProxyUrl;
  final Directory? webDirectory;
  final http.Client _proxyClient;
  final Map<String, DateTime> _adminSessions = {};
  final _random = Random.secure();
  HttpServer? _server;

  Handler get handler {
    final router = Router()
      ..get('/', _index)
      ..get(
        '/styles.css',
        (request) => _asset(request, 'styles.css', 'text/css; charset=utf-8'),
      )
      ..get(
        '/app.js',
        (request) =>
            _asset(request, 'app.js', 'text/javascript; charset=utf-8'),
      )
      ..get('/healthz', _health)
      ..post('/_lanchat/v1/access/verify', _verifyAccess)
      ..get('/_lanchat/v1/access/authorize', _authorizeAccess)
      ..post('/api/v1/usage/message', _recordMessage)
      ..get('/api/v1/server/info', _serverInfo)
      ..post('/api/v1/auth/join', _submitJoin)
      ..get('/api/v1/auth/join/<requestId>', _joinStatus)
      ..post('/api/v1/auth/login', _userLogin)
      ..post('/api/v1/auth/logout', _userLogout)
      ..get('/api/v1/me', _me)
      ..post('/api/v1/admin/setup', _adminSetup)
      ..post('/api/v1/admin/login', _adminLogin)
      ..get('/api/v1/admin/config', _adminConfig)
      ..put('/api/v1/admin/config', _updateConfig)
      ..post('/api/v1/admin/password', _changePassword)
      ..post('/api/v1/admin/access-code/rotate', _rotateAccessCode)
      ..get('/api/v1/admin/stats', _adminStats)
      ..get('/api/v1/admin/requests', _listRequests)
      ..post('/api/v1/admin/requests/<requestId>/approve', _approveJoin)
      ..post('/api/v1/admin/requests/<requestId>/reject', _rejectJoin)
      ..post('/api/v1/admin/invitations', _createInvitation)
      ..get('/api/v1/admin/devices/pending', _pendingDevices)
      ..get('/api/v1/admin/users', _listUsers)
      ..post('/api/v1/admin/users/<userId>/password', _resetUserPassword)
      ..post('/api/v1/admin/users/<userId>/disable', _disableUser)
      ..get('/api/v1/admin/users/<userId>/devices', _listUserDevices)
      ..post(
        '/api/v1/admin/users/<userId>/devices/<deviceId>/approve',
        _approveDevice,
      )
      ..delete(
        '/api/v1/admin/users/<userId>/devices/<deviceId>',
        _revokeDevice,
      );
    final routed = const Pipeline().addHandler(router.call);
    return (request) async {
      final response = await routed(request);
      if (response.statusCode != 404 || matrixProxyUrl == null) {
        return response;
      }
      return _proxyToMatrix(request);
    };
  }

  Future<HttpServer> start({String host = '0.0.0.0', int port = 8080}) async {
    _server = await shelf_io.serve(handler, host, port);
    return _server!;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _proxyClient.close();
  }

  Future<Response> _proxyToMatrix(Request request) async {
    final target = matrixProxyUrl!.resolve(
      request.url.path + (request.url.hasQuery ? '?${request.url.query}' : ''),
    );
    final body = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      body.add(chunk);
    }
    final outbound = http.Request(request.method, target)
      ..headers.addAll(_proxyHeaders(request.headers))
      ..bodyBytes = body.takeBytes();
    try {
      final upstream = await _proxyClient.send(outbound);
      final bytes = await upstream.stream.toBytes();
      final headers = <String, String>{};
      for (final entry in upstream.headers.entries) {
        if (entry.key == 'content-length' ||
            entry.key == 'transfer-encoding' ||
            entry.key == 'connection') {
          continue;
        }
        headers[entry.key] = entry.value;
      }
      return Response(upstream.statusCode, body: bytes, headers: headers);
    } on http.ClientException catch (error) {
      return _json({
        'error': 'matrix_unavailable',
        'detail': '$error',
      }, status: 502);
    } on SocketException catch (error) {
      return _json({
        'error': 'matrix_unavailable',
        'detail': '$error',
      }, status: 502);
    }
  }

  Map<String, String> _proxyHeaders(Map<String, String> source) {
    const skipped = {
      'host',
      'content-length',
      'transfer-encoding',
      'connection',
    };
    return Map.fromEntries(
      source.entries.where((entry) => !skipped.contains(entry.key)),
    );
  }

  Future<Response> _index(Request request) async {
    final directory = webDirectory;
    final file = directory == null
        ? null
        : File('${directory.path}${Platform.pathSeparator}index.html');
    if (file != null && await file.exists()) {
      return Response.ok(
        await file.readAsString(),
        headers: const {
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'no-cache',
        },
      );
    }
    return _json({'name': 'LanChat Control', 'status': 'ok'});
  }

  Future<Response> _asset(
    Request request,
    String name,
    String contentType,
  ) async {
    final directory = webDirectory;
    final file = directory == null
        ? null
        : File('${directory.path}${Platform.pathSeparator}$name');
    if (file == null || !await file.exists()) {
      return Response.notFound('Not found.');
    }
    return Response.ok(
      await file.readAsString(),
      headers: {'content-type': contentType, 'cache-control': 'no-cache'},
    );
  }

  Future<Response> _health(Request request) async =>
      _json({'status': 'ok', 'setupRequired': await store.setupRequired});

  Future<Response> _serverInfo(Request request) async {
    final config = await store.config;
    return _json({
      'serverName': serverName,
      'setupRequired': config.setupRequired,
      'encryptionMode': config.encryptionMode,
      'maxImageBytes': config.maxImageBytes,
      'retentionDays': config.retentionDays,
    });
  }

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

  Future<Response> _submitJoin(Request request) async {
    final body = await _readJson(request);
    try {
      final join = await joinStore.submit(
        inviteCode: body['inviteCode'] is String
            ? body['inviteCode'] as String
            : '',
        username: body['username'] is String ? body['username'] as String : '',
        password: body['password'] is String ? body['password'] as String : '',
        displayName: body['displayName'] is String
            ? body['displayName'] as String
            : '',
        deviceId: body['deviceId'] is String ? body['deviceId'] as String : '',
      );
      return _json({
        'requestId': join.id,
        'status': join.status.name,
      }, status: 202);
    } on JoinStoreException catch (error) {
      return _json({'error': error.message}, status: 400);
    }
  }

  Future<Response> _joinStatus(Request request, String requestId) async {
    final join = await joinStore.requestById(Uri.decodeComponent(requestId));
    if (join == null) {
      return _json({'error': 'join_request_not_found'}, status: 404);
    }
    return _json({
      'requestId': join.id,
      'status': join.status.name,
      'username': join.username,
      'displayName': join.displayName,
      'deviceId': join.deviceId,
      'createdAt': join.createdAt.toUtc().toIso8601String(),
      'reviewedAt': join.reviewedAt?.toUtc().toIso8601String(),
    });
  }

  Future<Response> _userLogin(Request request) async {
    final body = await _readJson(request);
    final result = await joinStore.authenticate(
      username: body['username'] is String ? body['username'] as String : '',
      password: body['password'] is String ? body['password'] as String : '',
      deviceId: body['deviceId'] is String ? body['deviceId'] as String : '',
    );
    final user = result.user;
    final device = result.device;
    switch (result.status) {
      case UserLoginStatus.invalidCredentials:
        return _json({'error': 'invalid_credentials'}, status: 401);
      case UserLoginStatus.disabled:
        return _json({'error': 'user_disabled'}, status: 403);
      case UserLoginStatus.devicePending:
        return _json({
          'status': 'device_pending',
          'user': user?.toPublicJson(),
          'device': device?.toPublicJson(),
        }, status: 202);
      case UserLoginStatus.deviceRevoked:
        return _json({'error': 'device_revoked'}, status: 403);
      case UserLoginStatus.authenticated:
        if (user == null || device == null) {
          return _json({'error': 'session_unavailable'}, status: 500);
        }
        MatrixLogin? matrixLogin;
        final gateway = matrixGateway;
        if (gateway != null) {
          try {
            matrixLogin = await gateway.loginUser(
              user.username,
              await store.matrixPasswordFor(user.passwordHash),
            );
            await joinStore.setMatrixDeviceId(
              userId: user.username,
              deviceId: device.deviceId,
              matrixDeviceId: matrixLogin.deviceId,
            );
          } catch (_) {
            return _json({'error': 'chat_backend_unavailable'}, status: 503);
          }
        }
        final token = await sessionStore.create(
          userId: user.username,
          deviceId: device.deviceId,
        );
        final response = <String, dynamic>{
          'status': 'authenticated',
          'token': token,
          'expiresInSeconds': 30 * 24 * 60 * 60,
          'user': user.toPublicJson(),
          'device': device.toPublicJson(),
        };
        if (matrixLogin != null) {
          response['matrixAccessToken'] = matrixLogin.accessToken;
          response['matrixUserId'] = matrixLogin.userId;
          response['matrixDeviceId'] = matrixLogin.deviceId;
        }
        return _json(response);
    }
  }

  Future<Response> _userLogout(Request request) async {
    final token = _bearerToken(request);
    if (token != null) await sessionStore.revokeToken(token);
    return Response(204);
  }

  Future<Response> _me(Request request) async {
    final context = await _userContext(request);
    if (context == null) return _json({'error': 'login_required'}, status: 401);
    return _json({
      'user': context.user.toPublicJson(),
      'device': context.device.toPublicJson(),
    });
  }

  Future<Response> _adminSetup(Request request) async {
    final body = await _readJson(request);
    final bootstrapCode = body['bootstrapCode'];
    final password = body['password'];
    if (bootstrapCode is! String || password is! String) {
      return _json({'error': 'invalid_setup'}, status: 400);
    }
    try {
      await store.completeSetup(
        bootstrapCode: bootstrapCode,
        adminPassword: password,
      );
      return _adminSessionResponse();
    } on StateError catch (error) {
      return _json({'error': '$error'}, status: 409);
    } on ArgumentError {
      return _json({'error': 'invalid_setup'}, status: 400);
    }
  }

  Future<Response> _adminLogin(Request request) async {
    if (await store.setupRequired) {
      return _json({'error': 'admin_setup_required'}, status: 428);
    }
    final body = await _readJson(request);
    final password = body['password'];
    if (password is! String || !await store.verifyAdminPassword(password)) {
      return _json({'error': 'invalid_admin_password'}, status: 401);
    }
    return _adminSessionResponse();
  }

  Response _adminSessionResponse() {
    final token = base64UrlEncode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    _adminSessions[token] = DateTime.now().add(const Duration(hours: 12));
    return _json({'token': token, 'expiresInSeconds': 12 * 60 * 60});
  }

  Future<Response?> _requireAdmin(Request request) async {
    final token = _bearerToken(request);
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
      'setupRequired': config.setupRequired,
      'encryptionMode': config.encryptionMode,
      'maxImageBytes': config.maxImageBytes,
      'retentionDays': config.retentionDays,
      'perUserDailyImageBytes': config.perUserDailyImageBytes,
      'globalDailyImageBytes': config.globalDailyImageBytes,
      'groupInviteConfigured': config.accessCodeHash != null,
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
    final supplied = body['accessCode'];
    if (supplied != null && supplied is! String) {
      return _json({'error': 'invalid_access_code'}, status: 400);
    }
    final code = supplied is String && supplied.trim().isNotEmpty
        ? supplied.trim()
        : _newCode();
    try {
      await store.rotateAccessCode(code);
      return _json({'ok': true, 'accessCode': code});
    } catch (error) {
      return _json({'error': '$error'}, status: 400);
    }
  }

  Future<Response> _adminStats(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final users = await joinStore.users();
    final requests = await joinStore.pendingRequests();
    final devices = await joinStore.allDevices();
    final sessions = await sessionStore.activeSessions();
    final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    return _json({
      ...store.stats(),
      'userCount': users.length,
      'deviceCount': devices.length,
      'onlineDevices': sessions
          .where((session) => session.lastSeenAt.isAfter(cutoff))
          .length,
      'pendingRequests': requests.length,
      'pendingDevices': devices
          .where((device) => device.status == DeviceStatus.pending)
          .length,
    });
  }

  Future<Response> _listRequests(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final requests = await joinStore.pendingRequests();
    return _json({
      'requests': requests.map((request) => request.toPublicJson()).toList(),
    });
  }

  Future<Response> _approveJoin(Request request, String requestId) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    try {
      final decodedRequestId = Uri.decodeComponent(requestId);
      final pending = await joinStore.requestById(decodedRequestId);
      if (pending == null) {
        return _json({'error': 'join_request_not_found'}, status: 404);
      }
      final gateway = matrixGateway;
      if (gateway != null && pending.status == JoinRequestStatus.pending) {
        await gateway.createUser(
          pending.username,
          await store.matrixPasswordFor(pending.passwordHash),
          pending.displayName,
        );
      }
      final user = await joinStore.approve(decodedRequestId);
      return _json({'ok': true, 'user': user.toPublicJson()});
    } on MatrixGatewayException catch (error) {
      return _json({'error': error.message}, status: 502);
    } on JoinStoreException catch (error) {
      return _json({'error': error.message}, status: 400);
    } catch (error) {
      return _json({
        'error': 'chat_backend_unavailable',
        'detail': '$error',
      }, status: 502);
    }
  }

  Future<Response> _rejectJoin(Request request, String requestId) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    try {
      await joinStore.reject(Uri.decodeComponent(requestId));
      return _json({'ok': true});
    } on JoinStoreException catch (error) {
      return _json({'error': error.message}, status: 400);
    }
  }

  Future<Response> _createInvitation(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final body = await _readJson(request);
    final singleUse = body['singleUse'] != false;
    final rawLifetime = body['lifetimeDays'];
    Duration? lifetime = const Duration(days: 7);
    if (rawLifetime is int) {
      if (rawLifetime == 0) {
        lifetime = null;
      } else if (rawLifetime < 1 || rawLifetime > 365) {
        return _json({'error': 'invalid_lifetime'}, status: 400);
      } else {
        lifetime = Duration(days: rawLifetime);
      }
    }
    try {
      final code = await joinStore.issueInvitation(
        singleUse: singleUse,
        lifetime: lifetime,
      );
      return _json({
        'code': code,
        'singleUse': singleUse,
        'lifetimeDays': rawLifetime == 0 ? null : lifetime?.inDays,
      });
    } on JoinStoreException catch (error) {
      return _json({'error': error.message}, status: 400);
    }
  }

  Future<Response> _pendingDevices(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final devices = await joinStore.pendingDevices();
    return _json({
      'devices': devices.map((device) => device.toPublicJson()).toList(),
    });
  }

  Future<Response> _listUsers(Request request) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final users = await joinStore.users();
    final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final result = <Map<String, dynamic>>[];
    for (final user in users) {
      final devices = await joinStore.devicesForUser(user.username);
      final sessions = await sessionStore.sessionsForUser(user.username);
      final onlineIds = sessions
          .where((session) => session.lastSeenAt.isAfter(cutoff))
          .map((session) => session.deviceId)
          .toSet();
      result.add({
        ...user.toPublicJson(),
        'online': onlineIds.isNotEmpty,
        'devices': devices
            .map(
              (device) =>
                  _deviceJson(device, onlineIds.contains(device.deviceId)),
            )
            .toList(),
      });
    }
    return _json({'users': result});
  }

  Future<Response> _resetUserPassword(Request request, String userId) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final body = await _readJson(request);
    final password = body['password'];
    if (password is! String) {
      return _json({'error': 'invalid_password'}, status: 400);
    }
    try {
      final decodedUserId = Uri.decodeComponent(userId);
      await joinStore.changeUserPassword(decodedUserId, password);
      final user = await joinStore.findUser(decodedUserId);
      final gateway = matrixGateway;
      if (gateway != null && user != null) {
        await gateway.updatePassword(
          decodedUserId,
          await store.matrixPasswordFor(user.passwordHash),
        );
      }
      await sessionStore.revokeUser(decodedUserId);
      return _json({'ok': true});
    } on JoinStoreException catch (error) {
      return _json({'error': error.message}, status: 400);
    }
  }

  Future<Response> _disableUser(Request request, String userId) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final body = await _readJson(request);
    final disabled = body['disabled'] != false;
    try {
      final decodedUserId = Uri.decodeComponent(userId);
      final user = await joinStore.findUser(decodedUserId);
      if (user == null) {
        return _json({'error': 'user_not_found'}, status: 404);
      }
      final gateway = matrixGateway;
      if (gateway != null) {
        await gateway.setUserDisabled(
          username: decodedUserId,
          disabled: disabled,
          matrixPassword: await store.matrixPasswordFor(user.passwordHash),
          displayName: user.displayName,
        );
      }
      await joinStore.setUserDisabled(decodedUserId, disabled);
      if (disabled) await sessionStore.revokeUser(decodedUserId);
      return _json({'ok': true, 'disabled': disabled});
    } on JoinStoreException catch (error) {
      return _json({'error': error.message}, status: 400);
    }
  }

  Future<Response> _listUserDevices(Request request, String userId) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final decodedUserId = Uri.decodeComponent(userId);
    if (await joinStore.findUser(decodedUserId) == null) {
      return _json({'error': 'user_not_found'}, status: 404);
    }
    final sessions = await sessionStore.sessionsForUser(decodedUserId);
    final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final onlineIds = sessions
        .where((session) => session.lastSeenAt.isAfter(cutoff))
        .map((session) => session.deviceId)
        .toSet();
    final devices = await joinStore.devicesForUser(decodedUserId);
    return _json({
      'devices': devices
          .map(
            (device) =>
                _deviceJson(device, onlineIds.contains(device.deviceId)),
          )
          .toList(),
    });
  }

  Future<Response> _approveDevice(
    Request request,
    String userId,
    String deviceId,
  ) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    try {
      await joinStore.approveDevice(
        userId: Uri.decodeComponent(userId),
        deviceId: Uri.decodeComponent(deviceId),
      );
      return _json({'ok': true});
    } on JoinStoreException catch (error) {
      return _json({'error': error.message}, status: 400);
    }
  }

  Future<Response> _revokeDevice(
    Request request,
    String userId,
    String deviceId,
  ) async {
    final denied = await _requireAdmin(request);
    if (denied != null) return denied;
    final decodedUserId = Uri.decodeComponent(userId);
    final decodedDeviceId = Uri.decodeComponent(deviceId);
    try {
      final localDevice = (await joinStore.devicesForUser(decodedUserId))
          .where((device) => device.deviceId == decodedDeviceId)
          .firstOrNull;
      if (localDevice == null) {
        return _json({'error': 'device_not_found'}, status: 404);
      }
      final gateway = matrixGateway;
      if (gateway != null && localDevice.matrixDeviceId != null) {
        await gateway.revokeUserDevice(
          decodedUserId,
          localDevice.matrixDeviceId!,
        );
      }
      await joinStore.revokeDevice(
        userId: decodedUserId,
        deviceId: decodedDeviceId,
      );
      await sessionStore.revokeDevice(
        userId: decodedUserId,
        deviceId: decodedDeviceId,
      );
      return _json({'ok': true});
    } on JoinStoreException catch (error) {
      return _json({'error': error.message}, status: 400);
    }
  }

  Future<_UserContext?> _userContext(Request request) async {
    final token = _bearerToken(request);
    if (token == null) return null;
    final session = await sessionStore.lookup(token);
    if (session == null) return null;
    final user = await joinStore.findUser(session.userId);
    if (user == null || user.disabled) return null;
    final device = (await joinStore.devicesForUser(user.username))
        .where((candidate) => candidate.deviceId == session.deviceId)
        .firstOrNull;
    if (device == null || device.status != DeviceStatus.approved) return null;
    return _UserContext(user: user, device: device);
  }

  Map<String, dynamic> _deviceJson(ServerDevice device, bool online) => {
    ...device.toPublicJson(),
    'online': online,
  };

  String? _bearerToken(Request request) {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) return null;
    final token = header.substring(7).trim();
    return token.isEmpty ? null : token;
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
    headers: const {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  );

  String _newCode() =>
      base64UrlEncode(List<int>.generate(18, (_) => _random.nextInt(256)))
          .replaceAll('=', '');

  int? _optionalInt(Object? value) => value is int ? value : null;
}

class _UserContext {
  const _UserContext({required this.user, required this.device});

  final ServerUser user;
  final ServerDevice device;
}

class SynapseAdminClient implements MatrixGateway {
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

  @override
  Future<MatrixLogin> loginUser(String username, String password) async {
    final response = await _client.post(
      baseUrl.resolve('/_matrix/client/v3/login'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'type': 'm.login.password',
        'identifier': {'type': 'm.id.user', 'user': username},
        'password': password,
        'initial_device_display_name': 'LanChat',
      }),
    );
    if (response.statusCode != 200) {
      throw MatrixGatewayException(
        'Synapse user login failed: ${response.statusCode}',
      );
    }
    final body = jsonDecode(response.body);
    if (body is! Map ||
        body['access_token'] is! String ||
        body['user_id'] is! String ||
        body['device_id'] is! String) {
      throw MatrixGatewayException('Synapse returned an invalid login.');
    }
    return MatrixLogin(
      accessToken: body['access_token'] as String,
      userId: body['user_id'] as String,
      deviceId: body['device_id'] as String,
    );
  }

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

  @override
  Future<void> createUser(
    String username,
    String password,
    String displayName,
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
        'displayname': displayName,
        'deactivated': false,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Synapse create user: ${response.statusCode}');
    }
  }

  @override
  Future<void> revokeUserDevice(String username, String matrixDeviceId) async {
    await revokeDevice('@$username:$serverName', matrixDeviceId);
  }

  @override
  Future<void> updatePassword(String username, String password) async {
    await resetUserPassword('@$username:$serverName', password);
  }

  @override
  Future<void> setUserDisabled({
    required String username,
    required bool disabled,
    required String matrixPassword,
    required String displayName,
  }) async {
    if (disabled) {
      await deactivateUser('@$username:$serverName');
    } else {
      await createUser(username, matrixPassword, displayName);
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
