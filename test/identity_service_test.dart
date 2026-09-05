import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:lanchat/services/app_state.dart';
import 'package:lanchat/services/identity_service.dart';

class _MemoryIdentityKeyStore implements IdentityKeyStore {
  _MemoryIdentityKeyStore({
    Map<String, String>? values,
    Object? lockScope,
    this.remainingReadFailures = 0,
  }) : _values = values ?? {},
       lockScope = lockScope ?? Object();

  final Map<String, String> _values;
  @override
  final Object lockScope;
  int remainingReadFailures;
  int writeCount = 0;
  int deleteCount = 0;

  @override
  Future<String?> read(String key) async {
    if (remainingReadFailures > 0) {
      remainingReadFailures--;
      throw StateError('Temporary storage failure');
    }
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCount++;
    _values.remove(key);
  }
}

class _BlockingIdentityKeyStore implements IdentityKeyStore {
  final readStarted = Completer<void>();
  final readResult = Completer<String?>();

  @override
  final Object lockScope = Object();

  @override
  Future<String?> read(String key) {
    if (!readStarted.isCompleted) readStarted.complete();
    return readResult.future;
  }

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persists the X25519 public key across service instances', () async {
    final store = _MemoryIdentityKeyStore();

    final firstPublicKey = await IdentityService(store: store).publicKey();
    final secondPublicKey = await IdentityService(store: store).publicKey();

    expect(secondPublicKey, firstPublicKey);
    expect(
      base64Url.decode(base64Url.normalize(firstPublicKey)),
      hasLength(32),
    );
  });

  test(
    'app state initializes and exposes the persistent identity key',
    () async {
      final identity = IdentityService(store: _MemoryIdentityKeyStore());
      final appState = AppState(identityService: identity);

      await appState.initializeIdentity();

      expect(appState.identityPublicKey, await identity.publicKey());
    },
  );

  test(
    'app state retains an identity startup failure and permits retry',
    () async {
      final store = _MemoryIdentityKeyStore(remainingReadFailures: 1);
      final appState = AppState(identityService: IdentityService(store: store));

      await expectLater(appState.init(), throwsA(isA<StateError>()));

      expect(appState.isInitialized, isFalse);
      expect(appState.initializationError, isA<StateError>());

      await appState.initializeIdentity();

      expect(appState.identityPublicKey, isNotEmpty);
      expect(appState.initializationError, isNull);
    },
  );

  test(
    'app state aborts initialization when disposed during identity loading',
    () async {
      final store = _BlockingIdentityKeyStore();
      final appState = AppState(identityService: IdentityService(store: store));
      var notificationCount = 0;
      appState.addListener(() => notificationCount++);

      final initialization = appState.init();
      await store.readStarted.future;
      appState.dispose();
      store.readResult.complete(base64UrlEncode(List<int>.filled(32, 1)));

      await expectLater(
        initialization,
        throwsA(isA<AppStateDisposedException>()),
      );
      expect(appState.isInitialized, isFalse);
      expect(appState.discovery, isNull);
      expect(appState.tcpPort, 0);
      expect(notificationCount, 0);
    },
  );

  test(
    'concurrent first use creates and persists one X25519 key pair',
    () async {
      final store = _MemoryIdentityKeyStore();
      final service = IdentityService(store: store);

      final publicKeys = await Future.wait([
        service.publicKey(),
        service.publicKey(),
      ]);

      expect(publicKeys[1], publicKeys[0]);
      expect(store.writeCount, 1);
    },
  );

  test(
    'concurrent services sharing a store create one X25519 key pair',
    () async {
      final store = _MemoryIdentityKeyStore();

      final publicKeys = await Future.wait([
        IdentityService(store: store).publicKey(),
        IdentityService(store: store).publicKey(),
      ]);

      expect(publicKeys[1], publicKeys[0]);
      expect(store.writeCount, 1);
    },
  );

  test('adapters sharing a lock scope create one X25519 key pair', () async {
    final values = <String, String>{};
    final lockScope = Object();
    final firstStore = _MemoryIdentityKeyStore(
      values: values,
      lockScope: lockScope,
    );
    final secondStore = _MemoryIdentityKeyStore(
      values: values,
      lockScope: lockScope,
    );

    final publicKeys = await Future.wait([
      IdentityService(store: firstStore).publicKey(),
      IdentityService(store: secondStore).publicKey(),
    ]);

    expect(publicKeys[1], publicKeys[0]);
    expect(firstStore.writeCount + secondStore.writeCount, 1);
  });

  test(
    'retries identity initialization after a transient storage failure',
    () async {
      final store = _MemoryIdentityKeyStore(remainingReadFailures: 1);
      final service = IdentityService(store: store);

      await expectLater(service.publicKey(), throwsA(isA<StateError>()));
      final publicKey = await service.publicKey();

      expect(base64Url.decode(base64Url.normalize(publicKey)), hasLength(32));
      expect(store.writeCount, 1);
    },
  );

  test('default services share one channel-backed store', () async {
    const channel = MethodChannel('lanchat/identity_storage');
    final values = <String, String>{};
    var writeCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final key =
              (call.arguments as Map<Object?, Object?>)['key'] as String;
          switch (call.method) {
            case 'read':
              return values[key];
            case 'write':
              writeCount++;
              values[key] =
                  (call.arguments as Map<Object?, Object?>)['value'] as String;
              return null;
            case 'delete':
              values.remove(key);
              return null;
            default:
              throw PlatformException(code: 'UNEXPECTED_METHOD');
          }
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final publicKeys = await Future.wait([
      IdentityService().publicKey(),
      IdentityService().publicKey(),
    ]);

    expect(publicKeys[1], publicKeys[0]);
    expect(writeCount, 1);
  });

  test('channel store deletes with the expected method and key', () async {
    const channel = MethodChannel('lanchat/identity_storage/delete-test');
    MethodCall? request;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          request = call;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await MethodChannelIdentityKeyStore(channel: channel).delete('peer-key');

    expect(request?.method, 'delete');
    expect(request?.arguments, {'key': 'peer-key'});
  });

  test('channel store maps unsupported platform errors', () async {
    const channel = MethodChannel('lanchat/identity_storage/unsupported-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'UNSUPPORTED_STORAGE',
            message: 'Secure storage is unavailable.',
          );
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await expectLater(
      MethodChannelIdentityKeyStore(channel: channel).read('identity-key'),
      throwsA(isA<IdentityStorageUnsupportedException>()),
    );
  });

  test(
    'channel store maps unrecoverable key errors with recovery guidance',
    () async {
      const channel = MethodChannel('lanchat/identity_storage/recovery-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'IDENTITY_KEY_UNRECOVERABLE',
              message: 'Remove secure identity storage before creating a new identity.',
            );
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await expectLater(
        MethodChannelIdentityKeyStore(channel: channel).read('identity-key'),
        throwsA(
          isA<IdentityStorageRecoveryException>().having(
            (error) => error.message,
            'message',
            contains('Remove secure identity storage'),
          ),
        ),
      );
    },
  );

  test('channel store maps missing plugins to unsupported storage', () async {
    const channel = MethodChannel('lanchat/identity_storage/missing-test');

    await expectLater(
      MethodChannelIdentityKeyStore(channel: channel).read('identity-key'),
      throwsA(isA<IdentityStorageUnsupportedException>()),
    );
  });

  test(
    'channel store rejects requests when the native window is closing',
    () async {
      const channel = MethodChannel('lanchat/identity_storage/closing-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'WINDOW_CLOSING',
              message: 'Identity storage is closing.',
            );
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await expectLater(
        MethodChannelIdentityKeyStore(channel: channel).read('identity-key'),
        throwsA(
          isA<IdentityStorageException>().having(
            (error) => error.message,
            'message',
            contains('Identity storage is closing'),
          ),
        ),
      );
    },
  );

  test(
    'channel store rejects requests when the native activity is closing',
    () async {
      const channel = MethodChannel(
        'lanchat/identity_storage/activity-closing',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'ACTIVITY_CLOSING',
              message: 'Identity storage activity is closing.',
            );
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await expectLater(
        MethodChannelIdentityKeyStore(channel: channel).read('identity-key'),
        throwsA(
          isA<IdentityStorageException>().having(
            (error) => error.message,
            'message',
            contains('Identity storage activity is closing'),
          ),
        ),
      );
    },
  );

  test('channel store rejects requests when native dispatch fails', () async {
    const channel = MethodChannel('lanchat/identity_storage/dispatch-failed');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'DISPATCH_FAILED',
            message: 'Identity storage response dispatch failed.',
          );
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await expectLater(
      MethodChannelIdentityKeyStore(channel: channel).read('identity-key'),
      throwsA(
        isA<IdentityStorageException>().having(
          (error) => error.message,
          'message',
          contains('Identity storage response dispatch failed'),
        ),
      ),
    );
  });

  test('rejects malformed stored private-key data', () async {
    final store = _MemoryIdentityKeyStore();
    const storedValue = 'not valid base64url!';
    await store.write('identity.x25519.private_key', storedValue);
    final writeCount = store.writeCount;

    await expectLater(
      IdentityService(store: store).publicKey(),
      throwsA(
        isA<IdentityStorageException>().having(
          (error) => error.message,
          'message',
          contains('base64url'),
        ),
      ),
    );
    expect(store._values['identity.x25519.private_key'], storedValue);
    expect(store.writeCount, writeCount);
  });

  test('persists and removes validated peer public keys', () async {
    final store = _MemoryIdentityKeyStore();
    final publicKey = base64UrlEncode(
      List<int>.generate(32, (index) => index + 1),
    ).replaceAll('=', '');

    await IdentityService(store: store).savePeerPublicKey('peer-1', publicKey);

    final secondService = IdentityService(store: store);
    expect(await secondService.readPeerPublicKey('peer-1'), publicKey);
    await secondService.removePeerPublicKey('peer-1');
    expect(await secondService.readPeerPublicKey('peer-1'), isNull);
    expect(store.deleteCount, 1);
  });

  test('rejects invalid peer public keys', () async {
    final service = IdentityService(store: _MemoryIdentityKeyStore());

    expect(
      () => service.savePeerPublicKey('peer-1', 'not a public key'),
      throwsArgumentError,
    );
  });

  test('derives the same shared secret from two identity key pairs', () async {
    final alice = IdentityService(store: _MemoryIdentityKeyStore());
    final bob = IdentityService(store: _MemoryIdentityKeyStore());
    final alicePublicKey = await alice.publicKey();
    final bobPublicKey = await bob.publicKey();

    final aliceSecret = await alice.sharedSecretWith(bobPublicKey);
    final bobSecret = await bob.sharedSecretWith(alicePublicKey);

    expect(aliceSecret, bobSecret);
    expect(aliceSecret, hasLength(32));
  });

  test('rejects stored private keys that are not 32 bytes', () async {
    final store = _MemoryIdentityKeyStore();
    final storedValue = base64UrlEncode(List<int>.filled(31, 0));
    await store.write('identity.x25519.private_key', storedValue);
    final writeCount = store.writeCount;

    await expectLater(
      IdentityService(store: store).publicKey(),
      throwsA(
        isA<IdentityStorageException>().having(
          (error) => error.message,
          'message',
          contains('32 bytes'),
        ),
      ),
    );
    expect(store._values['identity.x25519.private_key'], storedValue);
    expect(store.writeCount, writeCount);
  });

  test(
    'verification code is deterministic and zero-padded to six digits',
    () async {
      final secret = List<int>.generate(32, (index) => index);

      final firstCode = await verificationCode(secret);
      final secondCode = await verificationCode(secret);

      expect(secondCode, firstCode);
      expect(firstCode, matches(RegExp(r'^\d{6}$')));
    },
  );

  test('verification code preserves a leading zero', () async {
    final secret = await _secretWithLeadingZeroCode();

    final code = await verificationCode(secret);

    expect(code, hasLength(6));
    expect(code, startsWith('0'));
  });
}

Future<List<int>> _secretWithLeadingZeroCode() async {
  for (var value = 0; value <= 0xffff; value++) {
    final secret = List<int>.filled(32, 0);
    secret[0] = value >> 8;
    secret[1] = value & 0xff;
    if ((await verificationCode(secret)).startsWith('0')) return secret;
  }
  throw StateError('No deterministic verification-code test vector found.');
}
