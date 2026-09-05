// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:win_toast/win_toast.dart';

class LocalNotice {
  const LocalNotice({required this.senderName});

  final String senderName;

  String get body => '发来新消息';
}

abstract interface class LocalNotificationPlatform {
  Future<void> initialize();

  Future<void> show({required String title, required String body});

  Future<void> dispose();
}

class NoopLocalNotificationPlatform implements LocalNotificationPlatform {
  const NoopLocalNotificationPlatform();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> show({required String title, required String body}) async {}

  @override
  Future<void> dispose() async {}
}

class AndroidLocalNotificationPlatform implements LocalNotificationPlatform {
  AndroidLocalNotificationPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('lanchat/local_notifications');

  final MethodChannel _channel;

  @override
  Future<void> initialize() => _channel.invokeMethod('initialize');

  @override
  Future<void> show({required String title, required String body}) {
    return _channel.invokeMethod('show', {'title': title, 'body': body});
  }

  @override
  Future<void> dispose() async {}
}

class WindowsLocalNotificationPlatform implements LocalNotificationPlatform {
  WindowsLocalNotificationPlatform({WinToast? toast})
    : _toast = toast ?? WinToast.instance();

  static const _aumId = 'com.example.lanchat';
  static const _clsid = 'e06d3d99-5e4d-4f24-8e54-0a3be2fb0d39';
  final WinToast _toast;

  @override
  Future<void> initialize() async {
    final supported = await _toast.initialize(
      aumId: _aumId,
      displayName: 'LanChat',
      iconPath: '',
      clsid: _clsid,
    );
    if (!supported) throw StateError('Windows notifications are unavailable.');
  }

  @override
  Future<void> show({required String title, required String body}) {
    return _toast.showCustomToast(
      xml:
          '<toast><visual><binding template="ToastGeneric">'
          '<text>${_escapeXml(title)}</text>'
          '<text>${_escapeXml(body)}</text>'
          '</binding></visual></toast>',
    );
  }

  @override
  Future<void> dispose() async {}

  String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

class LocalNotificationService {
  LocalNotificationService({required LocalNotificationPlatform platform})
    : _platform = platform;

  final LocalNotificationPlatform _platform;
  final _notices = StreamController<LocalNotice>.broadcast();
  Stream<LocalNotice> get onNotice => _notices.stream;

  bool _initialized = false;
  bool _available = false;
  bool _appInBackground = false;

  bool get appInBackground => _appInBackground;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _platform.initialize();
      _available = true;
    } catch (_) {
      // Chat remains usable when the platform notification backend is absent.
      _available = false;
    }
  }

  void setAppInBackground(bool value) {
    _appInBackground = value;
  }

  Future<void> showMessage(String senderName) async {
    final name = senderName.trim();
    if (name.isEmpty || name.length > 128) return;
    final notice = LocalNotice(senderName: name);
    if (!_notices.isClosed) _notices.add(notice);
    if (!_appInBackground || !_available) return;
    try {
      await _platform.show(title: name, body: notice.body);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _platform.dispose();
    await _notices.close();
  }
}
