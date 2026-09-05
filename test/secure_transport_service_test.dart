import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/identity_service.dart';
import 'package:lanchat/services/secure_protocol.dart';
import 'package:lanchat/services/secure_transport_service.dart';

class _Store implements IdentityKeyStore {
  final Map<String, String> values = {};

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
  test('sends an encrypted text event between paired transports', () async {
    final aliceIdentity = IdentityService(store: _Store());
    final bobIdentity = IdentityService(store: _Store());
    final alicePublicKey = await aliceIdentity.publicKey();
    final bobPublicKey = await bobIdentity.publicKey();
    final received = Completer<String>();

    final alice = SecureTransportService(
      selfId: () => 'alice',
      selfName: () => 'Alice',
      selfPublicKey: aliceIdentity.publicKey,
      sharedSecretForPublicKey: aliceIdentity.sharedSecretWith,
      peerPublicKey: (id) async => id == 'bob' ? bobPublicKey : null,
      savePeerPublicKey: (_, _) async {},
      onSecureEvent: (_, _) async {},
    );
    final bob = SecureTransportService(
      selfId: () => 'bob',
      selfName: () => 'Bob',
      selfPublicKey: bobIdentity.publicKey,
      sharedSecretForPublicKey: bobIdentity.sharedSecretWith,
      peerPublicKey: (id) async => id == 'alice' ? alicePublicKey : null,
      savePeerPublicKey: (_, _) async {},
      onSecureEvent: (_, event) async {
        if (event.kind == 'text') {
          received.complete(event.fields['text'] as String);
        }
      },
    );

    await alice.start(port: 0);
    await bob.start(port: 0);
    addTearDown(() async {
      await alice.stop();
      await bob.stop();
    });

    await alice.sendText(
      '127.0.0.1',
      bob.listenPort,
      'hello securely',
      peerId: 'bob',
    );

    expect(
      await received.future.timeout(const Duration(seconds: 2)),
      'hello securely',
    );
  });

  test('requires a pairing confirmation before saving peer keys', () async {
    final aliceIdentity = IdentityService(store: _Store());
    final bobIdentity = IdentityService(store: _Store());
    final alicePublicKey = await aliceIdentity.publicKey();
    final bobPublicKey = await bobIdentity.publicKey();
    final requests = <PairingRequest>[];
    final savedByAlice = <String, String>{};
    final savedByBob = <String, String>{};

    final alice = SecureTransportService(
      selfId: () => 'alice',
      selfName: () => 'Alice',
      selfPublicKey: aliceIdentity.publicKey,
      sharedSecretForPublicKey: aliceIdentity.sharedSecretWith,
      peerPublicKey: (id) async => savedByAlice[id],
      savePeerPublicKey: (id, key) async => savedByAlice[id] = key,
      onSecureEvent: (_, _) async {},
      onPairingComplete: (_, _, _, _) async {},
    );
    final bob = SecureTransportService(
      selfId: () => 'bob',
      selfName: () => 'Bob',
      selfPublicKey: bobIdentity.publicKey,
      sharedSecretForPublicKey: bobIdentity.sharedSecretWith,
      peerPublicKey: (id) async => savedByBob[id],
      savePeerPublicKey: (id, key) async => savedByBob[id] = key,
      onSecureEvent: (_, _) async {},
      onPairingRequest: (request) async {
        requests.add(request);
        return true;
      },
      onPairingComplete: (_, _, _, _) async {},
    );

    await alice.start(port: 0);
    await bob.start(port: 0);
    addTearDown(() async {
      await alice.stop();
      await bob.stop();
    });

    final attempt = await alice.requestPairing(
      '127.0.0.1',
      bob.listenPort,
      expectedPeerId: 'bob',
    );

    expect(requests, hasLength(1));
    expect(attempt.verificationCode, requests.single.verificationCode);
    expect(savedByAlice, isEmpty);
    expect(savedByBob, isEmpty);

    await attempt.confirm();

    expect(savedByAlice['bob'], bobPublicKey);
    expect(savedByBob['alice'], alicePublicKey);
  });

  test(
    'asks before receiving a streamed file and confirms completion',
    () async {
      final aliceIdentity = IdentityService(store: _Store());
      final bobIdentity = IdentityService(store: _Store());
      final alicePublicKey = await aliceIdentity.publicKey();
      final bobPublicKey = await bobIdentity.publicKey();
      final file = await File('${Directory.systemTemp.path}/lanchat-send.bin')
          .writeAsBytes(List<int>.generate(150000, (index) => index & 0xff));
      final received = BytesBuilder(copy: false);
      final offerSeen = Completer<void>();
      final completeSeen = Completer<void>();

      final alice = SecureTransportService(
        selfId: () => 'alice',
        selfName: () => 'Alice',
        selfPublicKey: aliceIdentity.publicKey,
        sharedSecretForPublicKey: aliceIdentity.sharedSecretWith,
        peerPublicKey: (id) async => id == 'bob' ? bobPublicKey : null,
        savePeerPublicKey: (_, _) async {},
        onSecureEvent: (_, _) async {},
      );
      final bob = SecureTransportService(
        selfId: () => 'bob',
        selfName: () => 'Bob',
        selfPublicKey: bobIdentity.publicKey,
        sharedSecretForPublicKey: bobIdentity.sharedSecretWith,
        peerPublicKey: (id) async => id == 'alice' ? alicePublicKey : null,
        savePeerPublicKey: (_, _) async {},
        onSecureEvent: (_, _) async {},
        onFileOffer: (_, event) async {
          offerSeen.complete();
          return const FileOfferDecision.accept();
        },
        onFileChunk: (_, event) async => received.add(event.bytes),
        onFileComplete: (_, _) async {
          completeSeen.complete();
          return true;
        },
      );

      await alice.start(port: 0);
      await bob.start(port: 0);
      addTearDown(() async {
        await alice.stop();
        await bob.stop();
        await file.delete();
      });

      await alice.sendFile(
        ip: '127.0.0.1',
        port: bob.listenPort,
        filePath: file.path,
        fileName: 'payload.bin',
        isImage: false,
        peerId: 'bob',
      );

      await offerSeen.future.timeout(const Duration(seconds: 2));
      await completeSeen.future.timeout(const Duration(seconds: 2));
      expect(received.takeBytes(), await file.readAsBytes());
    },
  );

  test('rejects secure messages from an unpaired identity', () async {
    final aliceIdentity = IdentityService(store: _Store());
    final bobIdentity = IdentityService(store: _Store());
    final received = <SecureEvent>[];
    final alice = SecureTransportService(
      selfId: () => 'alice',
      selfName: () => 'Alice',
      selfPublicKey: aliceIdentity.publicKey,
      sharedSecretForPublicKey: aliceIdentity.sharedSecretWith,
      peerPublicKey: (_) async => null,
      savePeerPublicKey: (_, _) async {},
      onSecureEvent: (_, event) async => received.add(event),
    );
    final bob = SecureTransportService(
      selfId: () => 'bob',
      selfName: () => 'Bob',
      selfPublicKey: bobIdentity.publicKey,
      sharedSecretForPublicKey: bobIdentity.sharedSecretWith,
      peerPublicKey: (_) async => null,
      savePeerPublicKey: (_, _) async {},
      onSecureEvent: (_, event) async => received.add(event),
    );

    await alice.start(port: 0);
    await bob.start(port: 0);
    addTearDown(() async {
      await alice.stop();
      await bob.stop();
    });

    await expectLater(
      alice.sendText('127.0.0.1', bob.listenPort, 'blocked', peerId: 'bob'),
      throwsA(isA<SecureTransportException>()),
    );
    expect(received, isEmpty);
  });
}
