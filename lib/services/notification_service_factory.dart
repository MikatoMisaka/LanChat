import 'dart:io';

import 'notification_service.dart';

LocalNotificationService createDefaultLocalNotificationService() {
  final platform = Platform.isAndroid
      ? AndroidLocalNotificationPlatform()
      : Platform.isWindows
      ? WindowsLocalNotificationPlatform()
      : const NoopLocalNotificationPlatform();
  return LocalNotificationService(platform: platform);
}
