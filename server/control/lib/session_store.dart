import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class SessionRecord {
  const SessionRecord({
    required this.userId,
    required this.deviceId,
    required this.tokenHash,
    required this.createdAt,
    required this.expiresAt,
    required this.lastSeenAt,
  });

  final String userId;
  final String deviceId;
  final String tokenHash;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime lastSeenAt;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'deviceId': deviceId,
    'tokenHash': tokenHash,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
  };

  static SessionRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final userId = value['userId'];
    final deviceId = value['deviceId'];
    final tokenHash = value['tokenHash'];
    final createdAt = DateTime.tryParse('${value['createdAt']}');
    final expiresAt = DateTime.tryParse('${value['expiresAt']}');
    final lastSeenAt = DateTime.tryParse('${value['lastSeenAt']}');
    if (userId is! String ||
        deviceId is! String ||
        tokenHash is! String ||
        createdAt == null ||
        expiresAt == null ||
        lastSeenAt == null) {
      return null;
    }
    return SessionRecord(
      userId: userId,
      deviceId: deviceId,
      tokenHash: tokenHash,
      createdAt: createdAt,
      expiresAt: expiresAt,
      lastSeenAt: lastSeenAt,
    );
  }

  SessionRecord copyWith({required DateTime lastSeenAt}) => SessionRecord(
    userId: userId,
    deviceId: deviceId,
    tokenHash: tokenHash,
    createdAt: createdAt,
    expiresAt: expiresAt,
    lastSeenAt: lastSeenAt,
  );
}

class SessionStore {
  SessionStore(this.file);

  final File file;
  final _random = Random.secure();

  Future<String> create({
    required String userId,
    required String deviceId,
    Duration lifetime = const Duration(days: 30),
  }) async {
    _validate(userId, 'userId');
    _validate(deviceId, 'deviceId');
    final now = DateTime.now().toUtc();
    final token = base64UrlEncode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    final records = await _load();
    records.removeWhere((record) => record.expiresAt.isBefore(now));
    records.add(
      SessionRecord(
        userId: userId,
        deviceId: deviceId,
        tokenHash: await _hash(token),
        createdAt: now,
        expiresAt: now.add(lifetime),
        lastSeenAt: now,
      ),
    );
    await _save(records);
    return token;
  }

  Future<SessionRecord?> lookup(String token) async {
    if (token.trim().isEmpty) return null;
    final records = await _load();
    final hash = await _hash(token);
    final now = DateTime.now().toUtc();
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      if (record.expiresAt.isBefore(now)) continue;
      if (!_constantTimeEquals(record.tokenHash, hash)) continue;
      final next = record.copyWith(lastSeenAt: now);
      records[i] = next;
      await _save(records);
      return next;
    }
    return null;
  }

  Future<void> revokeDevice({
    required String userId,
    required String deviceId,
  }) async {
    final records = await _load();
    records.removeWhere(
      (record) => record.userId == userId && record.deviceId == deviceId,
    );
    await _save(records);
  }

  Future<void> revokeToken(String token) async {
    if (token.trim().isEmpty) return;
    final hash = await _hash(token);
    final records = await _load();
    records.removeWhere(
      (record) => _constantTimeEquals(record.tokenHash, hash),
    );
    await _save(records);
  }

  Future<void> revokeUser(String userId) async {
    final records = await _load();
    records.removeWhere((record) => record.userId == userId);
    await _save(records);
  }

  Future<List<SessionRecord>> sessionsForUser(String userId) async =>
      (await _load()).where((record) => record.userId == userId).toList();

  Future<List<SessionRecord>> activeSessions() async {
    final now = DateTime.now().toUtc();
    final records = await _load();
    return records
        .where((record) => record.expiresAt.isAfter(now))
        .toList(growable: false);
  }

  Future<List<SessionRecord>> _load() async {
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return [];
      return decoded
          .map(SessionRecord.fromJson)
          .whereType<SessionRecord>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<SessionRecord> records) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode(records.map((record) => record.toJson()).toList()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  Future<String> _hash(String value) async {
    final digest = await Sha256().hash(utf8.encode(value));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  bool _constantTimeEquals(String left, String right) {
    var difference = left.length ^ right.length;
    final length = min(left.length, right.length);
    for (var i = 0; i < length; i++) {
      difference |= left.codeUnitAt(i) ^ right.codeUnitAt(i);
    }
    return difference == 0;
  }

  void _validate(String value, String field) {
    if (value.trim().isEmpty || value.length > 256) {
      throw ArgumentError.value(value, field);
    }
  }
}
