import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

abstract interface class IdentityKeyStore {
  Object get lockScope;

  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class IdentityStorageException implements Exception {
  IdentityStorageException(this.message);

  final String message;

  @override
  String toString() => 'IdentityStorageException: $message';
}

class IdentityStorageUnsupportedException extends IdentityStorageException {
  IdentityStorageUnsupportedException(super.message);
}

class IdentityStorageRecoveryException extends IdentityStorageException {
  IdentityStorageRecoveryException(super.message);
}

class MethodChannelIdentityKeyStore implements IdentityKeyStore {
  MethodChannelIdentityKeyStore({MethodChannel? channel, Object? lockScope})
    : _channel = channel ?? _defaultChannel,
      _lockScope = lockScope ?? _defaultLockScope;

  static const _channelName = 'lanchat/identity_storage';
  static const MethodChannel _defaultChannel = MethodChannel(_channelName);
  static final Object _defaultLockScope = Object();

  final MethodChannel _channel;
  final Object _lockScope;

  @override
  Object get lockScope => _lockScope;

  @override
  Future<String?> read(String key) => _invoke<String>('read', {'key': key});

  @override
  Future<void> write(String key, String value) =>
      _invoke<void>('write', {'key': key, 'value': value});

  @override
  Future<void> delete(String key) => _invoke<void>('delete', {'key': key});

  Future<T?> _invoke<T>(String method, Map<String, String> arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      if (error.code == 'UNSUPPORTED_STORAGE') {
        throw IdentityStorageUnsupportedException(
          error.message ?? 'Secure identity storage is unsupported.',
        );
      }
      if (error.code == 'IDENTITY_KEY_UNRECOVERABLE') {
        throw IdentityStorageRecoveryException(
          error.message ??
              'Secure identity storage cannot be decrypted. Remove secure '
                  'identity storage before creating a new identity.',
        );
      }
      throw IdentityStorageException(
        'Secure identity storage $method failed: ${error.message ?? error.code}',
      );
    } on MissingPluginException {
      throw IdentityStorageUnsupportedException(
        'Secure identity storage is unsupported on this platform.',
      );
    }
  }
}

class IdentityService {
  IdentityService({IdentityKeyStore? store}) : _store = store ?? _defaultStore;

  static const _privateKeyStorageKey = 'identity.x25519.private_key';
  static const _peerPublicKeyPrefix = 'identity.x25519.peer.';
  static final IdentityKeyStore _defaultStore = MethodChannelIdentityKeyStore();
  static final _sharedKeyPairFutures = Expando<_KeyPairFuture>();

  final IdentityKeyStore _store;
  final X25519 _algorithm = X25519();

  Future<String> publicKey() async {
    final keyPair = await _keyPair();
    final publicKey = await keyPair.extractPublicKey();
    return base64UrlEncode(publicKey.bytes).replaceAll('=', '');
  }

  Future<List<int>> sharedSecretWith(String encodedPublicKey) async {
    final remotePublicKey = SimplePublicKey(
      _decodeX25519Key(encodedPublicKey, description: 'Peer X25519 public key'),
      type: KeyPairType.x25519,
    );
    final sharedSecret = await _algorithm.sharedSecretKey(
      keyPair: await _keyPair(),
      remotePublicKey: remotePublicKey,
    );
    return sharedSecret.extractBytes();
  }

  Future<void> savePeerPublicKey(String peerId, String encodedPublicKey) {
    final storageKey = _peerStorageKey(peerId);
    final publicKey = _decodeX25519Key(
      encodedPublicKey,
      description: 'Peer X25519 public key',
    );
    return _store.write(storageKey, _base64Url(publicKey));
  }

  Future<String?> readPeerPublicKey(String peerId) async {
    final encodedPublicKey = await _store.read(_peerStorageKey(peerId));
    if (encodedPublicKey == null) return null;
    final publicKey = _decodeX25519Key(
      encodedPublicKey,
      description: 'Stored peer X25519 public key',
      stored: true,
    );
    return _base64Url(publicKey);
  }

  Future<void> removePeerPublicKey(String peerId) =>
      _store.delete(_peerStorageKey(peerId));

  Future<SimpleKeyPair> _keyPair() {
    final scope = _store.lockScope;
    final existing = _sharedKeyPairFutures[scope];
    if (existing != null) return existing.value;

    final future = _loadKeyPair();
    final entry = _KeyPairFuture(future);
    _sharedKeyPairFutures[scope] = entry;
    future.then<void>(
      (_) {},
      onError: (_, _) {
        if (identical(_sharedKeyPairFutures[scope], entry)) {
          _sharedKeyPairFutures[scope] = null;
        }
      },
    );
    return future;
  }

  Future<SimpleKeyPair> _loadKeyPair() async {
    final encodedPrivateKey = await _store.read(_privateKeyStorageKey);
    if (encodedPrivateKey != null) {
      return _algorithm.newKeyPairFromSeed(
        _decodePrivateKey(encodedPrivateKey),
      );
    }

    final keyPair = await _algorithm.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    await _store.write(_privateKeyStorageKey, base64UrlEncode(privateKey));
    return keyPair;
  }

  List<int> _decodePrivateKey(String encodedPrivateKey) {
    return _decodeX25519Key(
      encodedPrivateKey,
      description: 'Stored X25519 private key',
      stored: true,
    );
  }

  List<int> _decodeX25519Key(
    String encodedKey, {
    required String description,
    bool stored = false,
  }) {
    final List<int> privateKey;
    try {
      privateKey = base64Url.decode(base64Url.normalize(encodedKey));
    } on FormatException {
      throw _keyError('$description is not valid base64url.', stored);
    }
    if (privateKey.length != 32) {
      throw _keyError('$description must be exactly 32 bytes.', stored);
    }
    return privateKey;
  }

  Object _keyError(String message, bool stored) => stored
      ? IdentityStorageException(message)
      : ArgumentError.value(message, 'encodedPublicKey');

  String _peerStorageKey(String peerId) {
    if (peerId.isEmpty || peerId.length > 128) {
      throw ArgumentError.value(peerId, 'peerId');
    }
    return '$_peerPublicKeyPrefix${_base64Url(utf8.encode(peerId))}';
  }

  String _base64Url(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}

class _KeyPairFuture {
  _KeyPairFuture(this.value);

  final Future<SimpleKeyPair> value;
}

Future<String> verificationCode(List<int> sharedSecret) async {
  final hash = await Sha256().hash(sharedSecret);
  final value =
      (hash.bytes[0] << 24) |
      (hash.bytes[1] << 16) |
      (hash.bytes[2] << 8) |
      hash.bytes[3];
  return (value % 1000000).toString().padLeft(6, '0');
}
