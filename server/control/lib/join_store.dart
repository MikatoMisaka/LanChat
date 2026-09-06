import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'config_store.dart';

enum JoinRequestStatus { pending, approved, rejected }

enum DeviceStatus { pending, approved, revoked }

enum UserLoginStatus {
  invalidCredentials,
  disabled,
  devicePending,
  deviceRevoked,
  authenticated,
}

class JoinStoreException implements Exception {
  JoinStoreException(this.message);

  final String message;

  @override
  String toString() => 'JoinStoreException: $message';
}

void _validateUserFields(String username, String displayName, String deviceId) {
  if (!RegExp(r'^[a-z0-9][a-z0-9_-]{2,31}$').hasMatch(username)) {
    throw JoinStoreException(
      'Username must contain 3-32 lowercase letters, numbers, _ or -.',
    );
  }
  if (displayName.trim().isEmpty || displayName.trim().length > 64) {
    throw JoinStoreException('Display name must contain 1-64 characters.');
  }
  if (deviceId.trim().isEmpty || deviceId.length > 128) {
    throw JoinStoreException('Device identifier is invalid.');
  }
}

class JoinRequest {
  const JoinRequest({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.displayName,
    required this.deviceId,
    required this.createdAt,
    this.status = JoinRequestStatus.pending,
    this.reviewedAt,
  });

  final String id;
  final String username;
  final PasswordHash passwordHash;
  final String displayName;
  final String deviceId;
  final DateTime createdAt;
  final JoinRequestStatus status;
  final DateTime? reviewedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'passwordHash': passwordHash.toJson(),
    'displayName': displayName,
    'deviceId': deviceId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'status': status.name,
    'reviewedAt': reviewedAt?.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toPublicJson() => {
    'id': id,
    'username': username,
    'displayName': displayName,
    'deviceId': deviceId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'status': status.name,
    'reviewedAt': reviewedAt?.toUtc().toIso8601String(),
  };

  JoinRequest copyWith({JoinRequestStatus? status, DateTime? reviewedAt}) =>
      JoinRequest(
        id: id,
        username: username,
        passwordHash: passwordHash,
        displayName: displayName,
        deviceId: deviceId,
        createdAt: createdAt,
        status: status ?? this.status,
        reviewedAt: reviewedAt ?? this.reviewedAt,
      );

  static JoinRequest? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final username = value['username'];
    final displayName = value['displayName'];
    final deviceId = value['deviceId'];
    final createdAt = DateTime.tryParse('${value['createdAt']}');
    final status = JoinRequestStatus.values
        .where((item) => item.name == value['status'])
        .firstOrNull;
    final rawHash = value['passwordHash'];
    if (id is! String ||
        username is! String ||
        displayName is! String ||
        deviceId is! String ||
        createdAt == null ||
        status == null ||
        rawHash is! Map) {
      return null;
    }
    try {
      _validateUserFields(username, displayName, deviceId);
      return JoinRequest(
        id: id,
        username: username,
        passwordHash: PasswordHash.fromJson(Map<String, dynamic>.from(rawHash)),
        displayName: displayName,
        deviceId: deviceId,
        createdAt: createdAt,
        status: status,
        reviewedAt: DateTime.tryParse('${value['reviewedAt']}'),
      );
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
}

class ServerDevice {
  const ServerDevice({
    required this.userId,
    required this.deviceId,
    required this.createdAt,
    this.status = DeviceStatus.pending,
    this.matrixDeviceId,
    this.approvedAt,
    this.lastSeenAt,
  });

  final String userId;
  final String deviceId;
  final DateTime createdAt;
  final DeviceStatus status;
  final String? matrixDeviceId;
  final DateTime? approvedAt;
  final DateTime? lastSeenAt;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'deviceId': deviceId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'status': status.name,
    'matrixDeviceId': matrixDeviceId,
    'approvedAt': approvedAt?.toUtc().toIso8601String(),
    'lastSeenAt': lastSeenAt?.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toPublicJson() => {
    'userId': userId,
    'deviceId': deviceId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'status': status.name,
    'approvedAt': approvedAt?.toUtc().toIso8601String(),
    'lastSeenAt': lastSeenAt?.toUtc().toIso8601String(),
  };

  ServerDevice copyWith({
    DeviceStatus? status,
    String? matrixDeviceId,
    DateTime? approvedAt,
    DateTime? lastSeenAt,
  }) => ServerDevice(
    userId: userId,
    deviceId: deviceId,
    createdAt: createdAt,
    status: status ?? this.status,
    matrixDeviceId: matrixDeviceId ?? this.matrixDeviceId,
    approvedAt: approvedAt ?? this.approvedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );

  ServerDevice reopenForApproval() => ServerDevice(
    userId: userId,
    deviceId: deviceId,
    createdAt: DateTime.now().toUtc(),
  );

  static ServerDevice? fromJson(Object? value) {
    if (value is! Map) return null;
    final userId = value['userId'];
    final deviceId = value['deviceId'];
    final createdAt = DateTime.tryParse('${value['createdAt']}');
    final status = DeviceStatus.values
        .where((item) => item.name == value['status'])
        .firstOrNull;
    if (userId is! String ||
        deviceId is! String ||
        createdAt == null ||
        status == null ||
        userId.trim().isEmpty ||
        deviceId.trim().isEmpty) {
      return null;
    }
    return ServerDevice(
      userId: userId,
      deviceId: deviceId,
      createdAt: createdAt,
      status: status,
      matrixDeviceId: value['matrixDeviceId'] is String
          ? value['matrixDeviceId'] as String
          : null,
      approvedAt: DateTime.tryParse('${value['approvedAt']}'),
      lastSeenAt: DateTime.tryParse('${value['lastSeenAt']}'),
    );
  }
}

class ServerUser {
  const ServerUser({
    required this.username,
    required this.passwordHash,
    required this.displayName,
    required this.createdAt,
    this.disabled = false,
  });

  final String username;
  final PasswordHash passwordHash;
  final String displayName;
  final DateTime createdAt;
  final bool disabled;

  Map<String, dynamic> toJson() => {
    'username': username,
    'passwordHash': passwordHash.toJson(),
    'displayName': displayName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'disabled': disabled,
  };

  Map<String, dynamic> toPublicJson() => {
    'username': username,
    'displayName': displayName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'disabled': disabled,
  };

  ServerUser copyWith({PasswordHash? passwordHash, bool? disabled}) =>
      ServerUser(
        username: username,
        passwordHash: passwordHash ?? this.passwordHash,
        displayName: displayName,
        createdAt: createdAt,
        disabled: disabled ?? this.disabled,
      );

  static ServerUser? fromJson(Object? value) {
    if (value is! Map) return null;
    final username = value['username'];
    final displayName = value['displayName'];
    final createdAt = DateTime.tryParse('${value['createdAt']}');
    final rawHash = value['passwordHash'];
    if (username is! String ||
        displayName is! String ||
        createdAt == null ||
        rawHash is! Map) {
      return null;
    }
    try {
      _validateUserFields(username, displayName, 'stored-device');
      return ServerUser(
        username: username,
        passwordHash: PasswordHash.fromJson(Map<String, dynamic>.from(rawHash)),
        displayName: displayName,
        createdAt: createdAt,
        disabled: value['disabled'] == true,
      );
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
}

class UserLoginResult {
  const UserLoginResult({required this.status, this.user, this.device});

  final UserLoginStatus status;
  final ServerUser? user;
  final ServerDevice? device;
}

class ServerInvitation {
  const ServerInvitation({
    required this.id,
    required this.singleUse,
    required this.used,
    required this.createdAt,
    this.expiresAt,
    this.revoked = false,
  });

  final String id;
  final bool singleUse;
  final int used;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final bool revoked;

  Map<String, dynamic> toPublicJson() => {
    'id': id,
    'singleUse': singleUse,
    'used': used,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'revoked': revoked,
  };
}

class _Invitation {
  const _Invitation({
    required this.id,
    required this.passwordHash,
    required this.singleUse,
    required this.used,
    required this.createdAt,
    this.expiresAt,
    this.revoked = false,
  });

  final String id;
  final PasswordHash passwordHash;
  final bool singleUse;
  final int used;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final bool revoked;

  Map<String, dynamic> toJson() => {
    'id': id,
    'passwordHash': passwordHash.toJson(),
    'singleUse': singleUse,
    'used': used,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'revoked': revoked,
  };

  ServerInvitation toPublicJson() => ServerInvitation(
    id: id,
    singleUse: singleUse,
    used: used,
    createdAt: createdAt,
    expiresAt: expiresAt,
    revoked: revoked,
  );

  static _Invitation? fromJson(Object? value) {
    if (value is! Map || value['passwordHash'] is! Map) return null;
    final createdAt = DateTime.tryParse('${value['createdAt']}');
    if (createdAt == null || value['used'] is! int) return null;
    try {
      return _Invitation(
        id: value['id'] is String && (value['id'] as String).isNotEmpty
            ? value['id'] as String
            : 'legacy-${createdAt.microsecondsSinceEpoch}',
        passwordHash: PasswordHash.fromJson(
          Map<String, dynamic>.from(value['passwordHash'] as Map),
        ),
        singleUse: value['singleUse'] != false,
        used: value['used'] as int,
        createdAt: createdAt,
        expiresAt: DateTime.tryParse('${value['expiresAt']}'),
        revoked: value['revoked'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  _Invitation copyWith({int? used, bool? revoked}) => _Invitation(
    id: id,
    passwordHash: passwordHash,
    singleUse: singleUse,
    used: used ?? this.used,
    createdAt: createdAt,
    expiresAt: expiresAt,
    revoked: revoked ?? this.revoked,
  );
}

class JoinStore {
  JoinStore(this.file, {required this.config});

  final File file;
  final ConfigStore config;
  final _uuid = const Uuid();
  final _random = Random.secure();

  Future<JoinRequest> submit({
    required String inviteCode,
    required String username,
    required String password,
    required String displayName,
    required String deviceId,
  }) async {
    final normalizedUsername = username.trim().toLowerCase();
    final normalizedDisplayName = displayName.trim();
    final normalizedDeviceId = deviceId.trim();
    _validateUserFields(
      normalizedUsername,
      normalizedDisplayName,
      normalizedDeviceId,
    );
    if (password.length < 8 || password.length > 128) {
      throw JoinStoreException('Password must contain 8-128 characters.');
    }

    final data = await _load();
    final inviteIndex = await _consumeInvite(data, inviteCode);
    if (data.users.any((user) => user.username == normalizedUsername)) {
      throw JoinStoreException('Username is already in use.');
    }
    if (data.requests.any(
      (request) =>
          request.username == normalizedUsername &&
          request.status == JoinRequestStatus.pending,
    )) {
      throw JoinStoreException('A request for this username is pending.');
    }
    final request = JoinRequest(
      id: _uuid.v4(),
      username: normalizedUsername,
      passwordHash: await PasswordHash.create(password),
      displayName: normalizedDisplayName,
      deviceId: normalizedDeviceId,
      createdAt: DateTime.now().toUtc(),
    );
    data.requests.add(request);
    if (inviteIndex != null) {
      data.invitations[inviteIndex] = data.invitations[inviteIndex].copyWith(
        used: data.invitations[inviteIndex].used + 1,
      );
    }
    await _save(data);
    return request;
  }

  Future<ServerUser> approve(String requestId) async {
    final data = await _load();
    final index = data.requests.indexWhere(
      (request) => request.id == requestId,
    );
    if (index < 0) throw JoinStoreException('Join request was not found.');
    final request = data.requests[index];
    final existing = data.users.where(
      (user) => user.username == request.username,
    );
    if (request.status == JoinRequestStatus.rejected) {
      throw JoinStoreException('A rejected request cannot be approved.');
    }
    if (existing.isNotEmpty) return existing.first;

    final user = ServerUser(
      username: request.username,
      passwordHash: request.passwordHash,
      displayName: request.displayName,
      createdAt: DateTime.now().toUtc(),
    );
    data.users.add(user);
    data.devices.add(
      ServerDevice(
        userId: user.username,
        deviceId: request.deviceId,
        createdAt: request.createdAt,
        status: DeviceStatus.approved,
        approvedAt: DateTime.now().toUtc(),
      ),
    );
    data.requests[index] = request.copyWith(
      status: JoinRequestStatus.approved,
      reviewedAt: DateTime.now().toUtc(),
    );
    await _save(data);
    return user;
  }

  Future<void> reject(String requestId) async {
    final data = await _load();
    final index = data.requests.indexWhere(
      (request) => request.id == requestId,
    );
    if (index < 0) throw JoinStoreException('Join request was not found.');
    final request = data.requests[index];
    if (request.status == JoinRequestStatus.approved) {
      throw JoinStoreException('An approved request cannot be rejected.');
    }
    data.requests[index] = request.copyWith(
      status: JoinRequestStatus.rejected,
      reviewedAt: DateTime.now().toUtc(),
    );
    await _save(data);
  }

  Future<JoinRequest?> requestById(String requestId) async => (await _load())
      .requests
      .where((request) => request.id == requestId)
      .firstOrNull;

  Future<List<JoinRequest>> pendingRequests() async => (await _load()).requests
      .where((request) => request.status == JoinRequestStatus.pending)
      .toList(growable: false);

  Future<List<ServerUser>> users() async =>
      (await _load()).users.toList(growable: false);

  Future<ServerUser?> findUser(String username) async {
    final normalized = username.trim().toLowerCase();
    return (await _load()).users
        .where((user) => user.username == normalized)
        .firstOrNull;
  }

  Future<UserLoginResult> authenticate({
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final normalizedUsername = username.trim().toLowerCase();
    final normalizedDeviceId = deviceId.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{2,31}$').hasMatch(normalizedUsername) ||
        normalizedDeviceId.isEmpty ||
        normalizedDeviceId.length > 128) {
      return const UserLoginResult(status: UserLoginStatus.invalidCredentials);
    }

    final data = await _load();
    final user = data.users
        .where((candidate) => candidate.username == normalizedUsername)
        .firstOrNull;
    if (user == null || !await user.passwordHash.verify(password)) {
      return const UserLoginResult(status: UserLoginStatus.invalidCredentials);
    }
    if (user.disabled) {
      return UserLoginResult(status: UserLoginStatus.disabled, user: user);
    }

    final deviceIndex = data.devices.indexWhere(
      (device) =>
          device.userId == user.username &&
          device.deviceId == normalizedDeviceId,
    );
    if (deviceIndex < 0) {
      final device = ServerDevice(
        userId: user.username,
        deviceId: normalizedDeviceId,
        createdAt: DateTime.now().toUtc(),
      );
      data.devices.add(device);
      await _save(data);
      return UserLoginResult(
        status: UserLoginStatus.devicePending,
        user: user,
        device: device,
      );
    }

    final device = data.devices[deviceIndex];
    if (device.status == DeviceStatus.pending) {
      return UserLoginResult(
        status: UserLoginStatus.devicePending,
        user: user,
        device: device,
      );
    }
    if (device.status == DeviceStatus.revoked) {
      final reopened = device.reopenForApproval();
      data.devices[deviceIndex] = reopened;
      await _save(data);
      return UserLoginResult(
        status: UserLoginStatus.devicePending,
        user: user,
        device: reopened,
      );
    }

    final seen = device.copyWith(lastSeenAt: DateTime.now().toUtc());
    data.devices[deviceIndex] = seen;
    await _save(data);
    return UserLoginResult(
      status: UserLoginStatus.authenticated,
      user: user,
      device: seen,
    );
  }

  Future<List<ServerDevice>> pendingDevices() async => (await _load()).devices
      .where((device) => device.status == DeviceStatus.pending)
      .toList(growable: false);

  Future<List<ServerDevice>> devicesForUser(String userId) async =>
      (await _load()).devices
          .where((device) => device.userId == userId)
          .toList(growable: false);

  Future<List<ServerDevice>> allDevices() async =>
      (await _load()).devices.toList(growable: false);

  Future<List<ServerInvitation>> invitations() async => (await _load())
      .invitations
      .map((invitation) => invitation.toPublicJson())
      .toList(growable: false);

  Future<void> revokeInvitation(String invitationId) async {
    final data = await _load();
    final index = data.invitations.indexWhere(
      (invitation) => invitation.id == invitationId,
    );
    if (index < 0) throw JoinStoreException('Invitation was not found.');
    data.invitations[index] = data.invitations[index].copyWith(revoked: true);
    await _save(data);
  }

  Future<void> approveDevice({
    required String userId,
    required String deviceId,
  }) async {
    final data = await _load();
    final index = data.devices.indexWhere(
      (device) => device.userId == userId && device.deviceId == deviceId,
    );
    if (index < 0) throw JoinStoreException('Device was not found.');
    data.devices[index] = data.devices[index].copyWith(
      status: DeviceStatus.approved,
      approvedAt: DateTime.now().toUtc(),
    );
    await _save(data);
  }

  Future<void> setMatrixDeviceId({
    required String userId,
    required String deviceId,
    required String matrixDeviceId,
  }) async {
    final data = await _load();
    final index = data.devices.indexWhere(
      (device) => device.userId == userId && device.deviceId == deviceId,
    );
    if (index < 0) throw JoinStoreException('Device was not found.');
    data.devices[index] = data.devices[index].copyWith(
      matrixDeviceId: matrixDeviceId,
    );
    await _save(data);
  }

  Future<void> revokeDevice({
    required String userId,
    required String deviceId,
  }) async {
    final data = await _load();
    final index = data.devices.indexWhere(
      (device) => device.userId == userId && device.deviceId == deviceId,
    );
    if (index < 0) throw JoinStoreException('Device was not found.');
    data.devices[index] = data.devices[index].copyWith(
      status: DeviceStatus.revoked,
    );
    await _save(data);
  }

  Future<void> setUserDisabled(String username, bool disabled) async {
    final data = await _load();
    final normalized = username.trim().toLowerCase();
    final index = data.users.indexWhere((user) => user.username == normalized);
    if (index < 0) throw JoinStoreException('User was not found.');
    data.users[index] = data.users[index].copyWith(disabled: disabled);
    await _save(data);
  }

  Future<void> changeUserPassword(String username, String password) async {
    if (password.length < 8 || password.length > 128) {
      throw JoinStoreException('Password must contain 8-128 characters.');
    }
    final data = await _load();
    final normalized = username.trim().toLowerCase();
    final index = data.users.indexWhere((user) => user.username == normalized);
    if (index < 0) throw JoinStoreException('User was not found.');
    data.users[index] = data.users[index].copyWith(
      passwordHash: await PasswordHash.create(password),
    );
    await _save(data);
  }

  Future<String> issueInvitation({
    bool singleUse = true,
    Duration? lifetime = const Duration(days: 7),
  }) async {
    final data = await _load();
    final code = base64UrlEncode(
      List<int>.generate(18, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    final now = DateTime.now().toUtc();
    data.invitations.add(
      _Invitation(
        id: _uuid.v4(),
        passwordHash: await PasswordHash.create(code),
        singleUse: singleUse,
        used: 0,
        createdAt: now,
        expiresAt: lifetime == null ? null : now.add(lifetime),
      ),
    );
    await _save(data);
    return code;
  }

  Future<int?> _consumeInvite(_JoinData data, String rawCode) async {
    final code = rawCode.trim();
    if (code.isEmpty) throw JoinStoreException('Invite code is required.');
    if (await config.verifyAccessCode(code)) return null;
    final now = DateTime.now().toUtc();
    for (var i = 0; i < data.invitations.length; i++) {
      final invite = data.invitations[i];
      if (invite.revoked) continue;
      if (invite.expiresAt != null && invite.expiresAt!.isBefore(now)) continue;
      if (invite.singleUse && invite.used > 0) continue;
      if (await invite.passwordHash.verify(code)) return i;
    }
    throw JoinStoreException('Invite code is invalid or expired.');
  }

  Future<_JoinData> _load() async {
    if (!await file.exists()) return _JoinData.empty();
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) throw const FormatException('Invalid join store.');
      return _JoinData(
        requests:
            (decoded['requests'] is List ? decoded['requests'] as List : [])
                .map(JoinRequest.fromJson)
                .whereType<JoinRequest>()
                .toList(),
        users: (decoded['users'] is List ? decoded['users'] as List : [])
            .map(ServerUser.fromJson)
            .whereType<ServerUser>()
            .toList(),
        devices: (decoded['devices'] is List ? decoded['devices'] as List : [])
            .map(ServerDevice.fromJson)
            .whereType<ServerDevice>()
            .toList(),
        invitations:
            (decoded['invitations'] is List
                    ? decoded['invitations'] as List
                    : [])
                .map(_Invitation.fromJson)
                .whereType<_Invitation>()
                .toList(),
      );
    } catch (error) {
      throw JoinStoreException('Join store cannot be read: $error');
    }
  }

  Future<void> _save(_JoinData data) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'requests': data.requests.map((request) => request.toJson()).toList(),
        'users': data.users.map((user) => user.toJson()).toList(),
        'devices': data.devices.map((device) => device.toJson()).toList(),
        'invitations': data.invitations
            .map((invitation) => invitation.toJson())
            .toList(),
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }
}

class _JoinData {
  _JoinData({
    required this.requests,
    required this.users,
    required this.devices,
    required this.invitations,
  });

  _JoinData.empty() : requests = [], users = [], devices = [], invitations = [];

  final List<JoinRequest> requests;
  final List<ServerUser> users;
  final List<ServerDevice> devices;
  final List<_Invitation> invitations;
}
