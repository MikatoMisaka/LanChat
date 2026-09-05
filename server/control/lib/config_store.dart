import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class ControlConfig {
  ControlConfig({
    required this.adminPasswordHash,
    required this.accessCodeHash,
    this.encryptionMode = 'e2ee',
    this.maxImageBytes = 20 * 1024 * 1024,
    this.retentionDays = 30,
    this.perUserDailyImageBytes = 512 * 1024 * 1024,
    this.globalDailyImageBytes = 5 * 1024 * 1024 * 1024,
  });

  PasswordHash adminPasswordHash;
  PasswordHash accessCodeHash;
  String encryptionMode;
  int maxImageBytes;
  int retentionDays;
  int perUserDailyImageBytes;
  int globalDailyImageBytes;

  Map<String, dynamic> toJson() => {
    'adminPasswordHash': adminPasswordHash.toJson(),
    'accessCodeHash': accessCodeHash.toJson(),
    'encryptionMode': encryptionMode,
    'maxImageBytes': maxImageBytes,
    'retentionDays': retentionDays,
    'perUserDailyImageBytes': perUserDailyImageBytes,
    'globalDailyImageBytes': globalDailyImageBytes,
  };

  static ControlConfig fromJson(Map<String, dynamic> json) => ControlConfig(
    adminPasswordHash: PasswordHash.fromJson(
      Map<String, dynamic>.from(json['adminPasswordHash'] as Map),
    ),
    accessCodeHash: PasswordHash.fromJson(
      Map<String, dynamic>.from(json['accessCodeHash'] as Map),
    ),
    encryptionMode: json['encryptionMode'] == 'readable' ? 'readable' : 'e2ee',
    maxImageBytes: _boundedInt(
      json['maxImageBytes'],
      20 * 1024 * 1024,
      1,
      20 * 1024 * 1024,
    ),
    retentionDays: _boundedInt(json['retentionDays'], 30, 1, 365),
    perUserDailyImageBytes: _boundedInt(
      json['perUserDailyImageBytes'],
      512 * 1024 * 1024,
      1,
      5 * 1024 * 1024 * 1024,
    ),
    globalDailyImageBytes: _boundedInt(
      json['globalDailyImageBytes'],
      5 * 1024 * 1024 * 1024,
      1,
      100 * 1024 * 1024 * 1024,
    ),
  );

  static int _boundedInt(Object? value, int fallback, int min, int max) {
    if (value is! int) return fallback;
    return value.clamp(min, max);
  }
}

class PasswordHash {
  PasswordHash({required this.salt, required this.digest});

  final List<int> salt;
  final List<int> digest;

  static Future<PasswordHash> create(String password) async {
    if (password.length < 8) {
      throw ArgumentError('Credential must contain at least 8 characters.');
    }
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final digest = await _derive(password, salt);
    return PasswordHash(salt: salt, digest: digest);
  }

  Future<bool> verify(String password) async {
    final candidate = await _derive(password, salt);
    if (candidate.length != digest.length) return false;
    var difference = 0;
    for (var i = 0; i < digest.length; i++) {
      difference |= candidate[i] ^ digest[i];
    }
    return difference == 0;
  }

  Map<String, dynamic> toJson() => {
    'salt': base64UrlEncode(salt),
    'digest': base64UrlEncode(digest),
  };

  static PasswordHash fromJson(Map<String, dynamic> json) {
    final salt = base64Url.decode(base64Url.normalize(json['salt'] as String));
    final digest = base64Url.decode(
      base64Url.normalize(json['digest'] as String),
    );
    if (salt.length != 16 || digest.length != 32) {
      throw const FormatException('Invalid credential hash.');
    }
    return PasswordHash(salt: salt, digest: digest);
  }

  static Future<List<int>> _derive(String password, List<int> salt) async {
    final key = await Argon2id(
      memory: 10 * 1000,
      iterations: 2,
      parallelism: 2,
      hashLength: 32,
    ).deriveKeyFromPassword(password: password, nonce: salt);
    return key.extractBytes();
  }
}

class ConfigStore {
  ConfigStore(this.file);

  final File file;
  ControlConfig? _config;
  final Map<String, int> _dailyUserImageBytes = {};
  int _dailyImageBytes = 0;
  String _day = _today();

  Future<void> initialize({
    required String adminPassword,
    required String accessCode,
  }) async {
    if (await file.exists()) {
      await load();
      return;
    }
    _config = ControlConfig(
      adminPasswordHash: await PasswordHash.create(adminPassword),
      accessCodeHash: await PasswordHash.create(accessCode),
    );
    await save();
  }

  Future<ControlConfig> load() async {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('Invalid control config.');
    return _config = ControlConfig.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<ControlConfig> get config async => _config ?? load();

  Future<bool> verifyAdminPassword(String password) async =>
      (await config).adminPasswordHash.verify(password);

  Future<bool> verifyAccessCode(String accessCode) async =>
      (await config).accessCodeHash.verify(accessCode);

  Future<void> rotateAccessCode(String accessCode) async {
    (await config).accessCodeHash = await PasswordHash.create(accessCode);
    await save();
  }

  Future<void> changeAdminPassword(String password) async {
    (await config).adminPasswordHash = await PasswordHash.create(password);
    await save();
  }

  Future<void> update({
    String? encryptionMode,
    int? maxImageBytes,
    int? retentionDays,
    int? perUserDailyImageBytes,
    int? globalDailyImageBytes,
  }) async {
    final current = await config;
    if (encryptionMode != null) {
      if (encryptionMode != 'e2ee' && encryptionMode != 'readable') {
        throw ArgumentError.value(encryptionMode, 'encryptionMode');
      }
      current.encryptionMode = encryptionMode;
    }
    if (maxImageBytes != null) {
      current.maxImageBytes = maxImageBytes.clamp(1, 20 * 1024 * 1024);
    }
    if (retentionDays != null) {
      current.retentionDays = retentionDays.clamp(1, 365);
    }
    if (perUserDailyImageBytes != null) {
      current.perUserDailyImageBytes = perUserDailyImageBytes.clamp(
        1,
        5 * 1024 * 1024 * 1024,
      );
    }
    if (globalDailyImageBytes != null) {
      current.globalDailyImageBytes = globalDailyImageBytes.clamp(
        1,
        100 * 1024 * 1024 * 1024,
      );
    }
    await save();
  }

  bool allowImage(String userId, int bytes) {
    _rollDay();
    final current = _config;
    if (current == null || bytes <= 0 || bytes > current.maxImageBytes) {
      return false;
    }
    final userTotal = (_dailyUserImageBytes[userId] ?? 0) + bytes;
    if (userTotal > current.perUserDailyImageBytes ||
        _dailyImageBytes + bytes > current.globalDailyImageBytes) {
      return false;
    }
    _dailyUserImageBytes[userId] = userTotal;
    _dailyImageBytes += bytes;
    return true;
  }

  void recordMessage({required String userId, int imageBytes = 0}) {
    _rollDay();
    if (imageBytes > 0) {
      _dailyUserImageBytes[userId] =
          (_dailyUserImageBytes[userId] ?? 0) + imageBytes;
      _dailyImageBytes += imageBytes;
    }
  }

  Map<String, dynamic> stats() {
    _rollDay();
    return {
      'day': _day,
      'imageBytes': _dailyImageBytes,
      'users': _dailyUserImageBytes.length,
      'userImageBytes': Map<String, int>.from(_dailyUserImageBytes),
    };
  }

  Future<void> save() async {
    final current = _config;
    if (current == null) throw StateError('Control config is not initialized.');
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(current.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  void _rollDay() {
    final day = _today();
    if (day == _day) return;
    _day = day;
    _dailyUserImageBytes.clear();
    _dailyImageBytes = 0;
  }

  static String _today() =>
      DateTime.now().toUtc().toIso8601String().substring(0, 10);
}
