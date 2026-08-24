import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/app_state.dart';
import '../services/db_service.dart';
import 'add_device_page.dart';
import 'chat_page.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    final app = AppStateScope.of(context);
    app.init();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await AppStateScope.of(context).refreshDevices();
    } finally {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _confirmDeleteDevice(AppState app, Device d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除「${d.name}」？'),
        content: const Text('将删除该设备、全部聊天记录和收到的文件'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await app.deleteDevice(d.id);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final devices = app.devices.values.toList()
      ..sort((a, b) {
        final ao = app.isOnline(a) ? 0 : 1;
        final bo = app.isOnline(b) ? 0 : 1;
        if (ao != bo) return ao - bo;
        return b.lastSeen.compareTo(a.lastSeen);
      });
    return Scaffold(
      appBar: AppBar(
        title: const Text('LanChat'),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: '刷新设备',
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: '我的二维码',
            onPressed: () => _showMyQr(context, app),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AddDevicePage()),
        ),
        child: const Icon(Icons.add),
      ),
      body: devices.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_find, size: 64, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text('正在扫描局域网设备…'),
                  const SizedBox(height: 4),
                  const Text('确保对方也打开了 LanChat\n没搜到可点右上角刷新，或用 + 手动添加',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            )
          : ListView.builder(
              itemCount: devices.length,
              itemBuilder: (_, i) {
                final d = devices[i];
                final online = app.isOnline(d);
                final last = app.latestMsgs[d.id];
                return ListTile(
                  leading: _avatar(d),
                  title: Text(d.name,
                      style: TextStyle(
                          color: online ? null : Colors.grey)),
                  subtitle: Text(
                    last != null ? _preview(last) : '${d.ip}:${d.port}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: online ? null : Colors.grey),
                  ),
                  trailing: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: online ? Colors.green : Colors.grey,
                    ),
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ChatPage(deviceId: d.id)),
                  ),
                  onLongPress: () => _confirmDeleteDevice(app, d),
                );
              },
            ),
    );
  }

  String _preview(Message m) {
    switch (m.type) {
      case 'text':
        return m.content;
      case 'image':
        return '[图片]';
      default:
        return '[文件] ${m.content}';
    }
  }

  Widget _avatar(Device d) {
    if (d.avatarPath != null && File(d.avatarPath!).existsSync()) {
      return CircleAvatar(
        backgroundImage: FileImage(File(d.avatarPath!)),
      );
    }
    return CircleAvatar(
      child: Text(d.name.isNotEmpty ? d.name.characters.first : '?'),
    );
  }

  void _showMyQr(BuildContext context, AppState app) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('我的二维码'),
        content: app.tcpPort == 0 || app.selfIp.isEmpty
            ? const Text('初始化中，请稍后再试')
            : SizedBox(
                width: 280,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${app.selfName}  ${app.selfIp}:${app.tcpPort}'),
                    const SizedBox(height: 12),
                    QrImageView(data: app.buildQr(), size: 220),
                    const SizedBox(height: 8),
                    Text('对方扫码即可添加你',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                  ],
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
