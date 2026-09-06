import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/remote_attachment_cache.dart';
import 'package:lanchat/services/remote_message_adapter.dart';

void main() {
  late Directory directory;
  late RemoteAttachmentCache cache;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lanchat-cache-test-');
    cache = RemoteAttachmentCache(directoryProvider: () async => directory);
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('automatically caches a small incoming image once', () async {
    final message = RemoteMessageAdapter.image(
      id: 'event-small',
      roomId: '!room:example.com',
      senderId: '@alice:example.com',
      body: 'small.png',
      fileSize: 1024,
      timestamp: DateTime(2026),
      isMine: false,
    );
    var downloads = 0;

    final path = await cache.autoReceiveImage(message, () async {
      downloads++;
      return Uint8List.fromList([1, 2, 3]);
    });
    final second = await cache.loadImage(message, () async {
      downloads++;
      return Uint8List.fromList([4, 5, 6]);
    });

    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), [1, 2, 3]);
    expect(second, [1, 2, 3]);
    expect(downloads, 1);
  });

  test('does not automatically cache images at or above 2 MiB', () async {
    final message = RemoteMessageAdapter.image(
      id: 'event-large',
      roomId: '!room:example.com',
      senderId: '@alice:example.com',
      body: 'large.png',
      fileSize: RemoteAttachmentCache.autoReceiveLimit,
      timestamp: DateTime(2026),
      isMine: false,
    );
    var downloads = 0;

    final path = await cache.autoReceiveImage(message, () async {
      downloads++;
      return Uint8List(1);
    });

    expect(path, isNull);
    expect(downloads, 0);
  });

  test(
    'does not keep an auto-received image whose actual bytes exceed limit',
    () async {
      final message = RemoteMessageAdapter.image(
        id: 'event-mismatch',
        roomId: '!room:example.com',
        senderId: '@alice:example.com',
        body: 'mismatch.png',
        fileSize: 1,
        timestamp: DateTime(2026),
        isMine: false,
      );

      final path = await cache.autoReceiveImage(message, () async {
        return Uint8List(RemoteAttachmentCache.autoReceiveLimit);
      });

      expect(path, isNull);
      expect(await cache.cachedPathFor(message), isNull);
    },
  );

  test('separates identical event ids from different servers', () async {
    final first = RemoteMessageAdapter.image(
      id: 'same-event',
      roomId: '!room:home.example.com',
      senderId: '@alice:home.example.com',
      body: 'home.png',
      fileSize: 3,
      timestamp: DateTime(2026),
      isMine: false,
    );
    final second = RemoteMessageAdapter.image(
      id: 'same-event',
      roomId: '!room:work.example.com',
      senderId: '@alice:work.example.com',
      body: 'work.png',
      fileSize: 3,
      timestamp: DateTime(2026),
      isMine: false,
    );

    await cache.autoReceiveImage(
      first,
      () async => Uint8List.fromList([1]),
      scope: 'home.example.com',
    );
    final path = await cache.autoReceiveImage(
      second,
      () async => Uint8List.fromList([2]),
      scope: 'work.example.com',
    );

    expect(File(path!).readAsBytesSync(), [2]);
  });
}
