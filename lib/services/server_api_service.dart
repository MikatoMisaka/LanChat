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

class ServerInfo {
  const ServerInfo({
    required this.serverName,
    required this.setupRequired,
    required this.encryptionMode,
    required this.maxImageBytes,
    required this.retentionDays,
  });

  final String serverName;
  final bool setupRequired;
  final String encryptionMode;
  final int maxImageBytes;
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
    final requestBody = body == null ? null : jsonEncode(body);
    final uri = profile.uri.resolve(path);
    final response = switch (method) {
      'GET' => await _client.get(uri, headers: headers),
      'POST' => await _client.post(uri, headers: headers, body: requestBody),
      _ => throw ArgumentError.value(method, 'method'),
    };
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

  String _messageForError(Object? error) => switch (error) {
    'invalid_credentials' => '用户名或密码不正确。',
    'user_disabled' => '这个账号已被管理员禁用。',
    'device_revoked' => '这台设备已被管理员撤销。',
    'chat_backend_unavailable' => '服务器聊天引擎暂时不可用。',
    'admin_setup_required' => '服务器尚未完成首次设置。',
    _ => '服务器请求失败。',
  };
}

class _ApiResponse {
  const _ApiResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, dynamic> body;
}
