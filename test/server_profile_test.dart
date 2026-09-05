import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/identity_service.dart';
import 'package:lanchat/services/server_profile.dart';
import 'package:lanchat/services/server_profile_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store implements IdentityKeyStore {
  final values = <String, String>{};

  @override
  final Object lockScope = Object();

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('normalizes secure server URLs and rejects unsafe variants', () {
    final profile = ServerProfile(
      id: 'family',
      name: '家庭服务器',
      baseUrl: 'https://chat.example.com///',
      username: 'alice',
    );

    expect(profile.uri.toString(), 'https://chat.example.com/');
    expect(
      () => ServerProfile(
        id: 'unsafe',
        name: 'Unsafe',
        baseUrl: 'http://chat.example.com',
        username: 'alice',
      ),
      throwsArgumentError,
    );
    expect(
      () => ServerProfile(
        id: 'query',
        name: 'Query',
        baseUrl: 'https://chat.example.com/?token=secret',
        username: 'alice',
      ),
      throwsArgumentError,
    );
  });

  test('stores server credentials outside SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    final keyStore = _Store();
    final store = ServerProfileStore(keyStore: keyStore);
    final profile = ServerProfile(
      id: 'family',
      name: '家庭服务器',
      baseUrl: 'https://chat.example.com',
      username: 'alice',
    );

    await store.save(
      profile,
      password: 'user-password',
      accessCode: 'server-code',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('server.family.password'), isNull);
    expect(prefs.getString('server.family.accessCode'), isNull);
    expect(await store.passwordFor('family'), 'user-password');
    expect(await store.accessCodeFor('family'), 'server-code');
    expect((await store.load()).single, profile);
  });
}
