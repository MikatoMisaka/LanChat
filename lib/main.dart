import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pages/devices_page.dart';
import 'pages/settings_page.dart';
import 'services/app_state.dart';

void main() {
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

class _LanChatAppState extends State<LanChatApp> {
  final AppState _appState = AppState();

  @override
  void initState() {
    super.initState();
    _appState.init();
  }

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: _appState,
      child: MaterialApp(
        title: 'LanChat',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF07C160),
          ),
        ),
        routes: {
          '/': (context) => const DevicesPage(),
          '/settings': (context) => const SettingsPage(),
        },
      ),
    );
  }
}
