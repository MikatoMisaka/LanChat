import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/secure_session.dart';

void main() {
  final sharedSecret = List<int>.generate(32, (index) => index + 1);
  final sessionNonce = List<int>.generate(16, (index) => 240 - index);

  test('encrypts in one direction and decrypts in the other', () async {
    final initiator = await SecureSession.fromSharedSecret(
      sharedSecret: sharedSecret,
      sessionNonce: sessionNonce,
      initiator: true,
    );
    final responder = await SecureSession.fromSharedSecret(
      sharedSecret: sharedSecret,
      sessionNonce: sessionNonce,
      initiator: false,
    );

    final wire = await initiator.seal(utf8.encode('hello'));

    expect(await responder.open(wire), utf8.encode('hello'));
  });

  test('rejects tampering and replayed sequence numbers', () async {
    final initiator = await SecureSession.fromSharedSecret(
      sharedSecret: sharedSecret,
      sessionNonce: sessionNonce,
      initiator: true,
    );
    final responder = await SecureSession.fromSharedSecret(
      sharedSecret: sharedSecret,
      sessionNonce: sessionNonce,
      initiator: false,
    );

    final wire = await initiator.seal(utf8.encode('one'));
    final tampered = [...wire]..[wire.length - 1] ^= 1;

    await expectLater(
      responder.open(tampered),
      throwsA(isA<SecureProtocolException>()),
    );
    expect(await responder.open(wire), utf8.encode('one'));
    await expectLater(
      responder.open(wire),
      throwsA(isA<SecureProtocolException>()),
    );
  });

  test('rejects plaintext larger than the secure frame limit', () async {
    final session = await SecureSession.fromSharedSecret(
      sharedSecret: sharedSecret,
      sessionNonce: sessionNonce,
      initiator: true,
    );

    await expectLater(
      session.seal(List<int>.filled(SecureSession.maxPlaintextBytes + 1, 1)),
      throwsA(isA<SecureProtocolException>()),
    );
  });
}
