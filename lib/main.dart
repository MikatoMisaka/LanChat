import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pages/settings_page.dart';
import 'services/app_state.dart';
import 'services/notification_service.dart';
import 'services/notification_service_factory.dart';
import 'widgets/chat_theme.dart';
import 'widgets/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await vod.init();
  } catch (_) {
    // The basic LAN edition does not need Matrix crypto. The server edition
    // reports an explicit error if E2EE cannot be initialized.
  }
  // 桌面平台（Windows/Linux）没有 sqflite 原生实现，切到 FFI 版 SQLite
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const LanChatApp());
}

class LanChatApp extends StatefulWidget {
  const LanChatApp({super.key});

  @override
  State<LanChatApp> createState() => _LanChatAppState();
}

class _LanChatAppState extends State<LanChatApp> with WidgetsBindingObserver {
  final _notificationService = createDefaultLocalNotificationService();
  late final AppState _appState = AppState(
    notificationService: _notificationService,
  );
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<LocalNotice>? _noticeSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _noticeSubscription = _notificationService.onNotice.listen((notice) {
      if (!mounted || _notificationService.appInBackground) return;
      _scaffoldMessengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('${notice.senderName}${notice.body}')),
        );
    });
    unawaited(_notificationService.initialize());
    unawaited(_appState.init().catchError((_) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _notificationService.setAppInBackground(
      state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _noticeSubscription?.cancel();
    _appState.dispose();
    unawaited(_notificationService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: _appState,
      child: MaterialApp(
        title: 'LanChat',
        scaffoldMessengerKey: _scaffoldMessengerKey,
        debugShowCheckedModeBanner: false,
        theme: LanChatTheme.light(),
        routes: {
          '/': (context) => const AppShell(),
          '/settings': (context) => const SettingsPage(),
        },
      ),
    );
  }
}
