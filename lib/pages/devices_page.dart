import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/app_state.dart';
import '../services/db_service.dart';
import '../services/secure_transport_service.dart';
import '../widgets/chat_theme.dart';
import 'add_device_page.dart';
import 'chat_page.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _refreshing = false;
  StreamSubscription<PairingRequest>? _pairingSub;
  StreamSubscription<IncomingFileOffer>? _fileOfferSub;

  @override
  void initState() {
    super.initState();
    final app = AppStateScope.of(context);
    unawaited(app.init().catchError((_) {}));
    _pairingSub = app.onPairingRequest.listen(_showPairingRequest);
    _fileOfferSub = app.onFileOffer.listen(_showFileOffer);
  }

  @override
  void dispose() {
    _pairingSub?.cancel();
    _fileOfferSub?.cancel();
    super.dispose();
  }

  Future<void> _showPairingRequest(PairingRequest request) async {
    final app = AppStateScope.of(context);
    if (!mounted) {
      await app.decidePairing(request.requestId, false);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('「${request.peerName}」请求配对'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('来源：${request.peerIp}'),
            const SizedBox(height: 8),
            const Text('请和对方核对两台设备显示的六位数字'),
            const SizedBox(height: 12),
            Text(
              request.verificationCode,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('一致，配对'),
          ),
        ],
      ),
    );
    await app.decidePairing(request.requestId, accepted == true);
  }

  Future<void> _showFileOffer(IncomingFileOffer offer) async {
    final app = AppStateScope.of(context);
    if (!mounted) {
      await app.decideFileOffer(offer.transferId, false);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(offer.isImage ? '接收图片？' : '接收文件？'),
        content: Text(
          '${app.devices[offer.peerId]?.name ?? '对方'} 想发送：\n'
          '${offer.fileName}\n'
          '${_formatBytes(offer.size)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('接收'),
          ),
        ],
      ),
    );
    await app.decideFileOffer(offer.transferId, accepted == true);
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await AppStateScope.of(context).refreshDevices();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _confirmDeleteDevice(AppState app, Device device) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除「${device.name}」？'),
        content: const Text('将删除该设备、聊天记录和已收到的文件'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (accepted == true) await app.deleteDevice(device.id);
  }

  Future<void> _startPairing(AppState app, Device device) async {
    if (device.ip.isEmpty || device.port <= 0) {
      _toast('还没有找到这个设备的可达地址');
      return;
    }
    try {
      final attempt = await app.requestPairing(
        device.ip,
        device.port,
        expectedPeerId: device.id,
      );
      if (!mounted) {
        await attempt.reject();
        return;
      }
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Text('与「${attempt.peerName}」配对？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('请核对两台设备显示的六位数字是否一致'),
              const SizedBox(height: 12),
              Text(
                attempt.verificationCode,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 6,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('不一致'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('一致，配对'),
            ),
          ],
        ),
      );
      if (accepted == true) {
        await attempt.confirm();
        _toast('已配对，可以开始聊天');
      } else {
        await attempt.reject();
      }
    } catch (error) {
      _toast('配对失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final devices = app.devices.values.toList()
      ..sort((a, b) {
        final onlineOrder = (app.isOnline(a) ? 0 : 1).compareTo(
          app.isOnline(b) ? 0 : 1,
        );
        if (onlineOrder != 0) return onlineOrder;
        return b.lastSeen.compareTo(a.lastSeen);
      });
    final paired = devices.where((device) => device.isPaired).toList();
    final nearby = devices.where((device) => !device.isPaired).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('LanChat', style: TextStyle(fontWeight: FontWeight.w700)),
            Text(
              '局域网私密聊天',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新附近设备',
            onPressed: _refresh,
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '我的二维码',
            onPressed: () => _showMyQr(context, app),
            icon: const Icon(Icons.qr_code_2),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.pushNamed(context, '/settings'),
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AddDevicePage()),
        ),
        icon: const Icon(Icons.add_link),
        label: const Text('添加设备'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final content = devices.isEmpty && app.initializationError == null
              ? _emptyState()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 100),
                  children: [
                    if (app.initializationError != null) ...[
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: ListTile(
                          leading: Icon(
                            Icons.warning_amber_rounded,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          title: const Text('初始化失败'),
                          subtitle: Text('${app.initializationError}'),
                          trailing: TextButton(
                            onPressed: () =>
                                unawaited(app.init().catchError((_) {})),
                            child: const Text('重试'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (paired.isNotEmpty) ...[
                      _sectionTitle('已配对联系人', Icons.verified_user_outlined),
                      const SizedBox(height: 8),
                      ...paired.map((device) => _deviceCard(app, device)),
                    ],
                    if (nearby.isNotEmpty) ...[
                      if (paired.isNotEmpty) const SizedBox(height: 24),
                      _sectionTitle('附近设备', Icons.wifi_find),
                      const SizedBox(height: 4),
                      Text(
                        '附近设备只能看到昵称，配对并核对数字后才能聊天。',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...nearby.map((device) => _deviceCard(app, device)),
                    ],
                  ],
                );
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth > 760 ? 760 : double.infinity,
              ),
              child: AnimatedSwitcher(
                duration: MediaQuery.of(context).disableAnimations
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                child: content,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: LanChatTheme.jade, size: 18),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _deviceCard(AppState app, Device device) {
    final online = app.isOnline(device);
    final latest = app.latestMsgs[device.id];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: device.isPaired
              ? () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatPage(deviceId: device.id),
                  ),
                )
              : () => _startPairing(app, device),
          onLongPress: () => _confirmDeleteDevice(app, device),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                _avatar(device),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: online ? null : Colors.grey.shade600,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        !device.isPaired
                            ? '待配对 · ${device.ip}:${device.port}'
                            : (latest != null
                                  ? _preview(latest)
                                  : '${device.ip}:${device.port}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _statusPill(device.isPaired, online),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusPill(bool paired, bool online) {
    final color = paired && online ? LanChatTheme.jade : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        paired ? (online ? '在线' : '离线') : '待配对',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: LanChatTheme.mint,
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(
                Icons.wifi_find,
                size: 42,
                color: LanChatTheme.jade,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '正在寻找局域网设备',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '确保对方打开 LanChat。热点环境下找不到时，\n可以使用“添加设备”输入 IP 和端口。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _preview(Message message) {
    switch (message.type) {
      case 'text':
        return message.content;
      case 'image':
        return '[图片]';
      default:
        return '[文件] ${message.content}';
    }
  }

  Widget _avatar(Device device) {
    if (device.avatarPath != null && File(device.avatarPath!).existsSync()) {
      return CircleAvatar(backgroundImage: FileImage(File(device.avatarPath!)));
    }
    return CircleAvatar(
      backgroundColor: LanChatTheme.mint,
      foregroundColor: LanChatTheme.jadeDark,
      child: Text(device.name.isNotEmpty ? device.name.characters.first : '?'),
    );
  }

  void _showMyQr(BuildContext context, AppState app) {
    final ips = app.selfIps.isNotEmpty ? app.selfIps : <String>[];
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('我的二维码'),
        content: app.tcpPort == 0 || ips.isEmpty
            ? const Text('初始化中，请稍后再试')
            : SizedBox(
                width: 280,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      app.selfName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    ...ips.map(
                      (ip) => Text(
                        '$ip:${app.tcpPort}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 12),
                    QrImageView(data: app.buildQr(), size: 220),
                    const SizedBox(height: 8),
                    const Text(
                      '扫码后仍需核对六位数字，确认后才会建立加密联系人。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}
