import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/notification_service.dart';

void main() {
  test(
    'shows a local system notification only while the app is backgrounded',
    () async {
      final platform = FakeLocalNotificationPlatform();
      final service = LocalNotificationService(platform: platform);
      final notices = <LocalNotice>[];
      final subscription = service.onNotice.listen(notices.add);

      await service.initialize();
      await service.showMessage('Alice');
      expect(platform.shown, isEmpty);
      expect(notices.single.body, '发来新消息');

      service.setAppInBackground(true);
      await service.showMessage('Bob');
      expect(platform.shown, hasLength(1));
      expect(platform.shown.single.title, 'Bob');
      expect(platform.shown.single.body, '发来新消息');
      await subscription.cancel();
      await service.dispose();
    },
  );

  test('does not require a remote provider or account', () async {
    final platform = FakeLocalNotificationPlatform();
    final service = LocalNotificationService(platform: platform);

    await service.initialize();
    await service.showMessage('Alice');

    expect(platform.initialized, isTrue);
    expect(platform.shown, isEmpty);
    await service.dispose();
  });
}

class FakeLocalNotificationPlatform implements LocalNotificationPlatform {
  bool initialized = false;
  final shown = <LocalNotificationCall>[];

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<void> show({required String title, required String body}) async {
    shown.add(LocalNotificationCall(title: title, body: body));
  }

  @override
  Future<void> dispose() async {}
}

class LocalNotificationCall {
  const LocalNotificationCall({required this.title, required this.body});

  final String title;
  final String body;
}
