import 'dart:io';

import 'package:flutter/material.dart';

import '../pages/devices_page.dart';
import '../pages/server_page.dart';
import '../pages/settings_page.dart';
import '../services/edition.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  List<Widget> get _pages => [
        const DevicesPage(),
        if (serverEdition) const ServerPage(),
        const SettingsPage(),
      ];

  List<NavigationDestination> get _destinations => [
        const NavigationDestination(
          icon: Icon(Icons.lan_outlined),
          selectedIcon: Icon(Icons.lan),
          label: '局域网',
        ),
        if (serverEdition)
          const NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            selectedIcon: Icon(Icons.cloud),
            label: '服务器',
          ),
        const NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: '个人',
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return Scaffold(
      body: Row(
        children: [
          if (desktop)
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (index) => setState(() => _index = index),
              labelType: NavigationRailLabelType.all,
              destinations: [
                const NavigationRailDestination(
                  icon: Icon(Icons.lan_outlined),
                  selectedIcon: Icon(Icons.lan),
                  label: Text('局域网'),
                ),
                if (serverEdition)
                  const NavigationRailDestination(
                    icon: Icon(Icons.cloud_outlined),
                    selectedIcon: Icon(Icons.cloud),
                    label: Text('服务器'),
                  ),
                const NavigationRailDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: Text('个人'),
                ),
              ],
            ),
          Expanded(child: IndexedStack(index: _index, children: pages)),
        ],
      ),
      bottomNavigationBar: desktop
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (index) => setState(() => _index = index),
              destinations: _destinations,
            ),
    );
  }
}
