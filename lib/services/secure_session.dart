import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SecureProtocolException implements Exception {
  SecureProtocolException(this.message);

  final String message;

  @override
  String toString() => 'SecureProtocolException: $message';
}

/// A bidirectional, ordered AEAD session derived from a trusted shared secret.
///
/// Each direction has a different key and nonce domain. Sequence numbers must
/// arrive in order, so a frame cannot be replayed or reordered inside a TCP
/// connection.
class SecureSession {
  static const maxPlaintextBytes = 64 * 1024;
  static const _sessionNonceBytes = 16;
  static const _sequenceBytes = 8;

  SecureSession._({
    required this._sendKey,
    required this._receiveKey,
    required List<int> sessionNonce,
    required List<int> sendLabel,
    required List<int> receiveLabel,
  }) : _sessionNonce = Uint8List.fromList(sessionNonce),
       _sendLabel = Uint8List.fromList(sendLabel),
       _receiveLabel = Uint8List.fromList(receiveLabel);

  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final Uint8List _sessionNonce;
  final Uint8List _sendLabel;
  final Uint8List _receiveLabel;
  final Cipher _cipher = Chacha20.poly1305Aead();
  int _sendSequence = 0;
  int _receiveSequence = 0;

  static Future<SecureSession> fromSharedSecret({
    required List<int> sharedSecret,
    required List<int> sessionNonce,
    required bool initiator,
  }) async {
    if (sharedSecret.length != 32) {
      throw SecureProtocolException('Shared secret must be 32 bytes.');
    }
    if (sessionNonce.length != _sessionNonceBytes) {
      throw SecureProtocolException('Session nonce must be 16 bytes.');
    }

    final initiatorToResponder = utf8.encode('lanchat-v1/i2r');
    final responderToInitiator = utf8.encode('lanchat-v1/r2i');
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final rootKey = SecretKeyData(sharedSecret);
    final initiatorKey = await hkdf.deriveKey(
      secretKey: rootKey,
      nonce: sessionNonce,
      info: initiatorToResponder,
    );
    final responderKey = await hkdf.deriveKey(
      secretKey: rootKey,
      nonce: sessionNonce,
      info: responderToInitiator,
    );

    return SecureSession._(
      sendKey: initiator ? initiatorKey : responderKey,
      receiveKey: initiator ? responderKey : initiatorKey,
      sessionNonce: sessionNonce,
      sendLabel: initiator ? initiatorToResponder : responderToInitiator,
      receiveLabel: initiator ? responderToInitiator : initiatorToResponder,
    );
  }

  Future<Uint8List> seal(List<int> plaintext) async {
    _checkPlaintextLength(plaintext.length);
    final sequence = _sendSequence;
    final nonce = await _nonce(sequence, _sendLabel);
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: _sendKey,
      nonce: nonce,
      aad: _aad(sequence, _sendLabel),
    );
    _sendSequence++;

    final encodedBox = box.concatenation();
    final wire = Uint8List(_sequenceBytes + encodedBox.length);
    wire.setAll(0, _sequence(sequence));
    wire.setAll(_sequenceBytes, encodedBox);
    return wire;
  }

  Future<Uint8List> open(List<int> wire) async {
    final minimum =
        _sequenceBytes + _cipher.nonceLength + _cipher.macAlgorithm.macLength;
    if (wire.length < minimum) {
      throw SecureProtocolException('Secure frame is truncated.');
    }

    final sequence = ByteData.sublistView(
      Uint8List.fromList(wire.sublist(0, _sequenceBytes)),
    ).getUint64(0, Endian.big);
    if (sequence != _receiveSequence) {
      throw SecureProtocolException('Unexpected secure frame sequence.');
    }

    final box = SecretBox.fromConcatenation(
      wire.sublist(_sequenceBytes),
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
      copy: false,
    );
    final expectedNonce = await _nonce(sequence, _receiveLabel);
    if (!_sameBytes(box.nonce, expectedNonce)) {
      throw SecureProtocolException('Secure frame nonce is invalid.');
    }

    try {
      final plaintext = await _cipher.decrypt(
        box,
        secretKey: _receiveKey,
        aad: _aad(sequence, _receiveLabel),
      );
      _checkPlaintextLength(plaintext.length);
      _receiveSequence++;
      return Uint8List.fromList(plaintext);
    } on SecureProtocolException {
      rethrow;
    } catch (_) {
      throw SecureProtocolException('Secure frame authentication failed.');
    }
  }

  void _checkPlaintextLength(int length) {
    if (length > maxPlaintextBytes) {
      throw SecureProtocolException('Secure plaintext exceeds the size limit.');
    }
  }

  Uint8List _sequence(int value) {
    return (ByteData(
      _sequenceBytes,
    )..setUint64(0, value, Endian.big)).buffer.asUint8List();
  }

  List<int> _aad(int sequence, List<int> label) => [
    ..._sessionNonce,
    ...label,
    ..._sequence(sequence),
  ];

  Future<Uint8List> _nonce(int sequence, List<int> label) async {
    final digest = await Sha256().hash([
      ..._sessionNonce,
      ...label,
      ..._sequence(sequence),
    ]);
    return Uint8List.fromList(digest.bytes.sublist(0, _cipher.nonceLength));
  }

  bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}
