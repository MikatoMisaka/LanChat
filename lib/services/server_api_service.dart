import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_profile.dart';

class ServerApiException implements Exception {
  ServerApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => message;
}

enum ServerProbeState { online, offline }

class ServerProbeResult {
  const ServerProbeResult({
    required this.state,
    required this.checkedAt,
    this.message,
    this.info,
  });

  final ServerProbeState state;
  final DateTime checkedAt;
  final String? message;
  final ServerInfo? info;
}

class ServerInfo {
  const ServerInfo({
    required this.serverName,
    required this.setupRequired,
    required this.encryptionMode,
    required this.maxImageBytes,
    required this.maxFileBytes,
    required this.retentionDays,
  });

  final String serverName;
  final bool setupRequired;
  final String encryptionMode;
  final int maxImageBytes;
  final int maxFileBytes;
  final int retentionDays;

  bool get e2ee => encryptionMode == 'e2ee';

  factory ServerInfo.fromMap(Object? value) {
    final data = value is Map ? value : const <Object?, Object?>{};
    final rawName = data['serverName'];
    final name = rawName is String ? rawName.trim() : '';
    return ServerInfo(
      serverName: name.isEmpty ? 'LanChat Server' : name,
      setupRequired: data['setupRequired'] == true,
      encryptionMode: data['encryptionMode'] == 'readable'
          ? 'readable'
          : 'e2ee',
      maxImageBytes: _boundedInt(
        data['maxImageBytes'],
        20 * 1024 * 1024,
        1,
        20 * 1024 * 1024,
      ),
      maxFileBytes: _boundedInt(
        data['maxFileBytes'],
        100 * 1024 * 1024,
        1,
        500 * 1024 * 1024,
      ),
      retentionDays: _boundedInt(data['retentionDays'], 30, 1, 365),
    );
  }

  static int _boundedInt(Object? value, int fallback, int min, int max) {
    if (value is! int) return fallback;
    return value.clamp(min, max).toInt();
  }
}

class ServerJoinResult {
  const ServerJoinResult({required this.requestId, required this.status});

  final String requestId;
  final String status;

  factory ServerJoinResult.fromMap(Object? value) {
    final data = value is Map ? value : const <Object?, Object?>{};
    final requestId = data['requestId'];
    final status = data['status'];
    if (requestId is! String || status is! String || requestId.isEmpty) {
      throw const FormatException('Invalid join response.');
    }
    return ServerJoinResult(requestId: requestId, status: status);
  }
}

class ServerDirectoryUser {
  const ServerDirectoryUser({
    required this.userId,
    required this.username,
    required this.displayName,
    this.isOnline = false,
    this.lastSeen,
  });

  final String userId;
  final String username;
  final String displayName;
  final bool isOnline;
  final DateTime? lastSeen;

  factory ServerDirectoryUser.fromMap(Object? value) {
    if (value is! Map ||
        value['userId'] is! String ||
        value['username'] is! String ||
        value['displayName'] is! String) {
      throw const FormatException('Invalid directory user.');
    }
    final userId = value['userId'] as String;
    if (!ServerApiService.isCompleteMatrixUserId(userId)) {
      throw const FormatException('Invalid Matrix user id.');
    }
    return ServerDirectoryUser(
      userId: userId,
      username: value['username'] as String,
      displayName: value['displayName'] as String,
      isOnline: value['isOnline'] == true,
      lastSeen: DateTime.tryParse('${value['lastSeen']}'),
    );
  }
}

enum ServerLoginStatus {
  authenticated,
  devicePending,
  deviceRevoked,
  disabled,
  invalidCredentials,
}

class ServerLoginResult {
  const ServerLoginResult({
    required this.status,
    this.token,
    this.matrixAccessToken,
    this.matrixUserId,
    this.matrixDeviceId,
    this.user,
    this.device,
  });

  final ServerLoginStatus status;
  final String? token;
  final String? matrixAccessToken;
  final String? matrixUserId;
  final String? matrixDeviceId;
  final Map<String, dynamic>? user;
  final Map<String, dynamic>? device;

  factory ServerLoginResult.fromMap(Object? value) {
    final data = value is Map ? Map<String, dynamic>.from(value) : {};
    final rawStatus = data['status'];
    final status = switch (rawStatus) {
      'authenticated' => ServerLoginStatus.authenticated,
      'device_pending' => ServerLoginStatus.devicePending,
      'device_revoked' => ServerLoginStatus.deviceRevoked,
      'disabled' => ServerLoginStatus.disabled,
      'invalid_credentials' => ServerLoginStatus.invalidCredentials,
      _ => throw const FormatException('Invalid login response.'),
    };
    return ServerLoginResult(
      status: status,
      token: data['token'] is String ? data['token'] as String : null,
      matrixAccessToken: data['matrixAccessToken'] is String
          ? data['matrixAccessToken'] as String
          : null,
      matrixUserId: data['matrixUserId'] is String
          ? data['matrixUserId'] as String
          : null,
      matrixDeviceId: data['matrixDeviceId'] is String
          ? data['matrixDeviceId'] as String
          : null,
      user: data['user'] is Map
          ? Map<String, dynamic>.from(data['user'] as Map)
          : null,
      device: data['device'] is Map
          ? Map<String, dynamic>.from(data['device'] as Map)
          : null,
    );
  }
}

class ServerApiService {
  static bool isCompleteMatrixUserId(String value) =>
      RegExp(r'^@[^\s:]+:[^\s]+$').hasMatch(value);

  ServerApiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<ServerInfo> fetchInfo(ServerProfile profile) async {
    final response = await _send(profile, 'GET', 'api/v1/server/info');
    try {
      return ServerInfo.fromMap(response.body);
    } catch (_) {
      throw ServerApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: '服务器返回了无效的能力信息。',
      );
    }
  }

  Future<ServerProbeResult> probe(ServerProfile profile) async {
    final checkedAt = DateTime.now();
    try {
      await _send(profile, 'GET', 'healthz');
      return ServerProbeResult(
        state: ServerProbeState.online,
        checkedAt: checkedAt,
      );
    } on ServerApiException catch (error) {
      return ServerProbeResult(
        state: ServerProbeState.offline,
        checkedAt: checkedAt,
        message: error.message,
      );
    } catch (error) {
      return ServerProbeResult(
        state: ServerProbeState.offline,
        checkedAt: checkedAt,
        message: '$error',
      );
    }
  }

  Future<List<ServerDirectoryUser>> fetchDirectory(
    ServerProfile profile, {
    required String sessionToken,
    String query = '',
  }) async {
    final term = query.trim();
    final path = term.isEmpty
        ? 'api/v1/directory/users'
        : 'api/v1/directory/users?q=${Uri.encodeQueryComponent(term)}';
    final response = await _send(profile, 'GET', path, token: sessionToken);
    final values = response.body['users'];
    if (values is! List) return const [];
    try {
      return values.map(ServerDirectoryUser.fromMap).toList();
    } on FormatException catch (error) {
      throw ServerApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: '服务器返回了无效的成员列表：${error.message}',
      );
    }
  }

  Future<ServerJoinResult> submitJoin(
    ServerProfile profile, {
    required String inviteCode,
    required String username,
    required String password,
    required String displayName,
    required String deviceId,
  }) async {
    final response = await _send(
      profile,
      'POST',
      'api/v1/auth/join',
      body: {
        'inviteCode': inviteCode,
        'username': username,
        'password': password,
        'displayName': displayName,
        'deviceId': deviceId,
      },
      acceptedStatuses: {202},
    );
    try {
      return ServerJoinResult.fromMap(response.body);
    } catch (_) {
      throw ServerApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: '服务器返回了无效的申请信息。',
      );
    }
  }

  Future<ServerJoinResult> joinStatus(
    ServerProfile profile,
    String requestId,
  ) async {
    final response = await _send(
      profile,
      'GET',
      'api/v1/auth/join/${Uri.encodeComponent(requestId)}',
    );
    try {
      return ServerJoinResult.fromMap(response.body);
    } catch (_) {
      throw ServerApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: '服务器返回了无效的申请状态。',
      );
    }
  }

  Future<ServerLoginResult> login(
    ServerProfile profile, {
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final response = await _send(
      profile,
      'POST',
      'api/v1/auth/login',
      body: {'username': username, 'password': password, 'deviceId': deviceId},
      acceptedStatuses: {200, 202},
    );
    try {
      return ServerLoginResult.fromMap(response.body);
    } on FormatException {
      throw ServerApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: '服务器返回了无效的登录信息。',
      );
    }
  }

  Future<void> logout(ServerProfile profile, String token) async {
    await _send(
      profile,
      'POST',
      'api/v1/auth/logout',
      token: token,
      acceptedStatuses: {204},
    );
  }

  Future<_ApiResponse> _send(
    ServerProfile profile,
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    Set<int> acceptedStatuses = const {200},
  }) async {
    final headers = <String, String>{'content-type': 'application/json'};
    if (token != null && token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    final uri = profile.uri.resolve(path);
    final requestBody = body == null ? null : jsonEncode(body);
    final response = await (switch (method) {
      'GET' => _client.get(uri, headers: headers),
      'POST' => _client.post(uri, headers: headers, body: requestBody),
      _ => throw ArgumentError.value(method, 'method'),
    }).timeout(const Duration(seconds: 10));
    final decoded = _decodeBody(response.body);
    if (!acceptedStatuses.contains(response.statusCode)) {
      final error = decoded['error'];
      throw ServerApiException(
        statusCode: response.statusCode,
        code: error is String ? error : 'request_failed',
        message: _messageForError(error),
      );
    }
    return _ApiResponse(statusCode: response.statusCode, body: decoded);
  }

  Map<String, dynamic> _decodeBody(String raw) {
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  String _messageForError(Object? error) {
    final raw = error is String ? error.trim() : '';
    return switch (raw) {
      'invalid_credentials' => '用户名或密码不正确。',
      'user_disabled' => '这个账号已被管理员禁用。',
      'device_revoked' => '这台设备已被管理员撤销。',
      'chat_backend_unavailable' => '服务器聊天引擎暂时不可用。',
      'upload_too_large' => '文件超过服务器允许的大小。',
      'daily_attachment_quota_exceeded' => '今天的附件流量额度已用完。',
      'file_quota_exceeded' => '今天的附件流量额度已用完。',
      'admin_setup_required' => '服务器尚未完成首次设置。',
      'matrix_server_name_invalid' => '服务器的 Matrix 域名配置无效，请检查 SYNAPSE_SERVER_NAME。',
      _ when raw.isNotEmpty => raw,
      _ => '服务器请求失败。',
    };
  }
}

class _ApiResponse {
  const _ApiResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, dynamic> body;
}
