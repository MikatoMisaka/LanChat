import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_service.dart';
import 'server_profile.dart';

class ServerProfileStore {
  ServerProfileStore({IdentityKeyStore? keyStore})
    : _keyStore = keyStore ?? MethodChannelIdentityKeyStore();

  static const _profilesKey = 'server.profiles';
  static const _credentialPrefix = 'server.credential.';

  final IdentityKeyStore _keyStore;

  Future<List<ServerProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final profiles = <ServerProfile>[];
      for (final value in decoded) {
        try {
          profiles.add(ServerProfile.fromMap(value));
        } on FormatException {
          // Ignore a corrupted profile instead of blocking all other servers.
        } on ArgumentError {
          // Ignore a profile that no longer satisfies current validation.
        }
      }
      return profiles;
    } catch (_) {
      return [];
    }
  }

  Future<void> save(
    ServerProfile profile, {
    required String password,
    String? accessCode,
    String? inviteCode,
    String? sessionToken,
  }) async {
    if (password.isEmpty) {
      throw ArgumentError('Server password cannot be empty.');
    }
    final prefs = await SharedPreferences.getInstance();
    final profiles = await load();
    final next = [profile, ...profiles.where((item) => item.id != profile.id)];
    await prefs.setString(
      _profilesKey,
      jsonEncode(next.map((item) => item.toMap()).toList()),
    );
    await _keyStore.write(_credentialKey(profile.id, 'password'), password);
    await _writeOrDelete(profile.id, 'access-code', accessCode);
    await _writeOrDelete(profile.id, 'invite-code', inviteCode);
    await _writeOrDelete(profile.id, 'session-token', sessionToken);
  }

  Future<String?> passwordFor(String profileId) =>
      _keyStore.read(_credentialKey(profileId, 'password'));

  Future<String?> accessCodeFor(String profileId) =>
      _keyStore.read(_credentialKey(profileId, 'access-code'));

  Future<String?> inviteCodeFor(String profileId) =>
      _keyStore.read(_credentialKey(profileId, 'invite-code'));

  Future<String?> sessionTokenFor(String profileId) =>
      _keyStore.read(_credentialKey(profileId, 'session-token'));

  Future<void> remove(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = await load();
    await prefs.setString(
      _profilesKey,
      jsonEncode(
        profiles
            .where((profile) => profile.id != profileId)
            .map((profile) => profile.toMap())
            .toList(),
      ),
    );
    await _keyStore.delete(_credentialKey(profileId, 'password'));
    await _keyStore.delete(_credentialKey(profileId, 'access-code'));
    await _keyStore.delete(_credentialKey(profileId, 'invite-code'));
    await _keyStore.delete(_credentialKey(profileId, 'session-token'));
  }

  Future<void> _writeOrDelete(
    String profileId,
    String kind,
    String? value,
  ) async {
    final key = _credentialKey(profileId, kind);
    if (value == null || value.isEmpty) {
      await _keyStore.delete(key);
    } else {
      await _keyStore.write(key, value);
    }
  }

  String _credentialKey(String profileId, String kind) {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(profileId)) {
      throw ArgumentError.value(profileId, 'profileId');
    }
    return '$_credentialPrefix$profileId.$kind';
  }
}
