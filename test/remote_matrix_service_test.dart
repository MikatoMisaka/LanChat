import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:lanchat/services/remote_matrix_service.dart';
import 'package:lanchat/services/remote_message_adapter.dart';

void main() {
  test('remote server limits allow text and images within the contract', () {
    expect(() => RemoteServerLimits.validateText('hello'), returnsNormally);
    expect(
      () => RemoteServerLimits.validateImageSize(20 * 1024 * 1024),
      returnsNormally,
    );
  });

  test('remote server limits reject oversized remote content', () {
    expect(
      () => RemoteServerLimits.validateText(
        'a' * (RemoteServerLimits.maxTextBytes + 1),
      ),
      throwsA(isA<RemoteServerException>()),
    );
    expect(
      () => RemoteServerLimits.validateImageSize(
        RemoteServerLimits.maxImageBytes + 1,
      ),
      throwsA(isA<RemoteServerException>()),
    );
  });

  test('remote server limits reject blank text messages', () {
    expect(
      () => RemoteServerLimits.validateText('   '),
      throwsA(isA<RemoteServerException>()),
    );
  });

  test('remote server capabilities preserve the server encryption mode', () {
    final capabilities = RemoteServerCapabilities.fromMap({
      'serverName': 'Home',
      'encryptionMode': 'readable',
      'maxImageBytes': 1024,
      'retentionDays': 7,
      'maxFileBytes': 100 * 1024 * 1024,
    });

    expect(capabilities.serverName, 'Home');
    expect(capabilities.encryptionMode, 'readable');
    expect(capabilities.e2ee, isFalse);
    expect(capabilities.maxImageBytes, 1024);
    expect(capabilities.retentionDays, 7);
    expect(capabilities.maxFileBytes, 100 * 1024 * 1024);
  });

  test('remote server capabilities default to safe bounded values', () {
    final capabilities = RemoteServerCapabilities.fromMap(const {});

    expect(capabilities.e2ee, isTrue);
    expect(capabilities.maxImageBytes, RemoteServerLimits.maxImageBytes);
    expect(capabilities.retentionDays, 30);
    expect(capabilities.maxFileBytes, RemoteServerLimits.maxFileBytes);
  });

  test('remote limits accept small files and reject oversized files', () {
    expect(
      () => RemoteServerLimits.validateFileSize(100 * 1024 * 1024),
      returnsNormally,
    );
    expect(
      () => RemoteServerLimits.validateFileSize(100 * 1024 * 1024 + 1),
      throwsA(isA<RemoteServerException>()),
    );
    expect(
      () => RemoteServerLimits.validateFileSize(
        500 * 1024 * 1024,
        maxBytes: RemoteServerLimits.maxFileBytesLimit,
      ),
      returnsNormally,
    );
  });

  test('remote file messages expose attachment metadata', () {
    final message = RemoteMessageAdapter.file(
      id: 'event-1',
      roomId: '!room:example',
      senderId: '@alice:example',
      body: 'notes.pdf',
      fileSize: 1024,
      timestamp: DateTime(2026),
      isMine: true,
    );

    expect(message.isFile, isTrue);
    expect(message.fileName, 'notes.pdf');
    expect(message.fileSize, 1024);
  });

  test('remote message merging removes duplicate event ids', () {
    final first = RemoteMessageAdapter.text(
      id: 'event-1',
      roomId: '!room:example',
      senderId: '@alice:example',
      body: 'first',
      timestamp: DateTime(2026),
      isMine: false,
    );
    final second = RemoteMessageAdapter.text(
      id: 'event-2',
      roomId: '!room:example',
      senderId: '@bob:example',
      body: 'second',
      timestamp: DateTime(2026, 1, 1, 0, 1),
      isMine: false,
    );

    final merged = mergeRemoteMessages([first, first, second]);

    expect(merged.map((message) => message.id), ['event-1', 'event-2']);
  });

  test(
    'invite rooms remain actionable for accepting or rejecting requests',
    () {
      expect(
        RemoteMatrixService.canUseRoom(
          membership: Membership.invite,
          allowInvite: true,
          hasPendingMember: true,
        ),
        isTrue,
      );
      expect(
        RemoteMatrixService.canUseRoom(
          membership: Membership.join,
          allowInvite: false,
          hasPendingMember: true,
        ),
        isFalse,
      );
    },
  );
}
