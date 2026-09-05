import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/remote_matrix_service.dart';

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

  test('remote server capabilities preserve the server encryption mode', () {
    final capabilities = RemoteServerCapabilities.fromMap({
      'serverName': 'Home',
      'encryptionMode': 'readable',
      'maxImageBytes': 1024,
      'retentionDays': 7,
    });

    expect(capabilities.serverName, 'Home');
    expect(capabilities.encryptionMode, 'readable');
    expect(capabilities.e2ee, isFalse);
    expect(capabilities.maxImageBytes, 1024);
    expect(capabilities.retentionDays, 7);
  });

  test('remote server capabilities default to safe bounded values', () {
    final capabilities = RemoteServerCapabilities.fromMap(const {});

    expect(capabilities.e2ee, isTrue);
    expect(capabilities.maxImageBytes, RemoteServerLimits.maxImageBytes);
    expect(capabilities.retentionDays, 30);
  });
}
