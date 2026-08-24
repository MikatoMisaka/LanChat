import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'db_service.dart';
import 'discovery_service.dart';
import 'transport_service.dart';

/// 全局应用状态：串联发现层/传输层/数据库
class AppState extends ChangeNotifier {
  static const _channel = MethodChannel('lanchat/multicast');

  final DbService db = DbService();
  DiscoveryService? _discovery;
  DiscoveryService? get discovery => _discovery;
  late final TransportService transport;

  String selfId = '';
  String selfName = '';
  String? selfAvatar;
  String selfAvatarB64 = '';
  String selfIp = '';
  List<String> _selfIps = [];
  /// 全部可用本机 IPv4（多网卡/多网段场景，发现层按网段广播）
  List<String> get selfIps => List.unmodifiable(_selfIps);
  int tcpPort = 0;
  bool _inited = false;
  Timer? _pruneTimer;

  final Map<String, Device> _devices = {};
  Map<String, Device> get devices => Map.unmodifiable(_devices);

  final Map<String, Message> _latestMsgs = {};
  Map<String, Message> get latestMsgs => _latestMsgs;

  final _msgController = StreamController<String>.broadcast();
  Stream<String> get onNewMessage => _msgController.stream;

  final _mergeController = StreamController<(String, String)>.broadcast();

  /// 设备合并事件 (旧id, 新id)：打开中的聊天页跟随切换，避免失联
  Stream<(String, String)> get onDeviceMerged => _mergeController.stream;

  final _fileProgressController = StreamController<FileReceivingEvent>.broadcast();

  /// 接收文件进度事件流（接收方聊天页显示「正在接收」气泡+进度条）
  Stream<FileReceivingEvent> get onFileReceiving =>
      _fileProgressController.stream;

  /// 正在接收中的文件 msgId 集合（用于前台服务的启停）
  final Set<String> _activeTransfers = {};
  bool _serviceRunning = false;

  AppState() {
    transport = TransportService(
      selfName: () => selfName,
      selfId: () => selfId,
      onFrame: _onFrame,
      onDisconnect: (_) {},
      openFileSink: _openFileSink,
      onFileDone: _onFileDone,
      onFileProgress: _onFileProgress,
      onFileAbort: _onFileAbort,
    );
  }

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    final prefs = await SharedPreferences.getInstance();
    selfId = prefs.getString('selfId') ?? '';
    if (selfId.isEmpty) {
      selfId = const Uuid().v4();
      await prefs.setString('selfId', selfId);
    }
    selfName = prefs.getString('selfName') ?? '用户${selfId.hashCode.abs() % 10000}';
    selfAvatar = prefs.getString('selfAvatar');
    selfAvatarB64 = prefs.getString('selfAvatarB64') ?? '';
    _filesBase = prefs.getString('filesDir');
    notifyListeners();

    tcpPort = await transport.start();
    selfIp = await _lookupSelfIp();
    _selfIps = await _lookupSelfIps();
    notifyListeners();

    for (final dev in await db.getAllDevices()) {
      _devices[dev.id] = dev;
    }
    _latestMsgs.addAll(await db.latestMessagePerDevice());
    notifyListeners();

    _discovery = DiscoveryService(
      selfId: selfId,
      selfName: () => selfName,
      selfTcpPort: () => tcpPort,
      selfIp: () => selfIp,
      selfIps: () => _selfIps,
      selfAvatarB64: () => selfAvatarB64,
      onPeer: _onPeer,
    );

    await _acquireMulticastLock();
    await _discovery!.start();

    _pruneTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _pruneOffline());
  }

  Future<String> _lookupSelfIp() async {
    final ips = await _lookupSelfIps();
    return ips.isEmpty ? '' : ips.first;
  }

  /// 收集所有可用于通信的本机 IPv4（过滤虚拟网卡），按优先级排序。
  /// 多接口场景（USB 共享 + 热点同时开）下广播/探测需要覆盖全部网段。
  Future<List<String>> _lookupSelfIps() async {
    final ranked = <int, List<String>>{};
    try {
      final list = await NetworkInterface.list();
      for (final iface in list) {
        final score = _ifaceScore(iface.name);
        if (score < 0) continue; // 虚拟网卡
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              !addr.address.startsWith('169.254.')) {
            ranked.putIfAbsent(score, () => []).add(addr.address);
          }
        }
      }
    } catch (_) {}
    final ips = <String>[];
    final scores = ranked.keys.toList()..sort();
    for (final s in scores) {
      ips.addAll(ranked[s]!);
    }
    return ips;
  }

  /// 接口优先级：返回 -1 表示虚拟网卡直接跳过。
  /// Android: wlan0/swlan0(WiFi/热点) > ap0(热点) > usb0/rndis0(USB共享) > 其他(rmnet 蜂窝等)
  /// Windows/Linux: 按名字过滤 VMware/VirtualBox/Hyper-V/WSL/Docker 等虚拟网卡
  static int _ifaceScore(String rawName) {
    final n = rawName.toLowerCase();
    // 虚拟网卡（Windows 常见 VMware/VTAP；Linux 常见 veth/docker/tap）
    if (n.contains('vmware') ||
        n.contains('vmnet') ||
        n.contains('virtualbox') ||
        n.contains('vethernet') ||
        n.contains('docker') ||
        n.contains('veth') ||
        n.contains('wsl') ||
        n.contains('tap') ||
        n.contains('tunnel') ||
        n.contains('loopback') ||
        n.contains('bluetooth') ||
        n.contains('bt-pan')) {
      return -1;
    }
    if (n.startsWith('wlan') || n.startsWith('wifi')) return 0;
    if (n.startsWith('ap')) return 1;
    if (n.startsWith('usb') || n.startsWith('rndis')) return 2;
    if (n.startsWith('rmnet') || n.startsWith('ccmni')) return 4; // 蜂窝，最后
    return 3; // Windows "以太网"/WLAN、Linux eth0 等常规接口
  }

  Future<void> _acquireMulticastLock() async {
    try {
      await _channel.invokeMethod('acquire');
    } catch (_) {}
  }

  /// 打开系统设置页（相机权限被拒绝时引导）
  Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod('openSettings');
    } catch (_) {}
  }

  /// 按 IP 找已有设备（手动/自动/TCP 学习都查）
  Device? _findByIp(String ip) {
    for (final d in _devices.values) {
      if (d.ip == ip && ip.isNotEmpty) return d;
    }
    return null;
  }

  void _onPeer(DiscoveryPayload payload, String fromIp) {
    final ip = fromIp.isNotEmpty ? fromIp : payload.ip;
    var existing = _devices[payload.id];
    // 同 IP 但 id 不同的旧条目（手动添加/TCP 学习）：合并到真实 id
    if (ip.isNotEmpty) {
      final dups = _devices.values
          .where((d) => d.ip == ip && d.id != payload.id)
          .toList();
      for (final dup in dups) {
        _devices.remove(dup.id);
        if (_latestMsgs.remove(dup.id) case final m?) {
          _latestMsgs[payload.id] = m;
        }
        db.mergeDeviceId(dup.id, payload.id);
        _mergeController.add((dup.id, payload.id));
        existing ??= Device(
          id: payload.id,
          name: dup.name,
          ip: ip,
          port: dup.port,
          avatarPath: dup.avatarPath,
          lastSeen: dup.lastSeen,
          isManual: dup.isManual,
        );
      }
    }
    final dev = Device(
      id: payload.id,
      name: payload.name.isNotEmpty
          ? payload.name
          : (existing?.name ?? payload.name),
      ip: ip,
      port: payload.tcpPort,
      avatarPath: existing?.avatarPath,
      lastSeen: DateTime.now(),
      isManual: existing?.isManual ?? false,
    );
    _devices[payload.id] = dev;
    db.upsertDevice(dev);
    notifyListeners();
    // 收到对方头像（base64 缩略图），变化时写盘展示
    if (payload.avatar.isNotEmpty &&
        _peerAvatarVer[payload.id] != payload.avatar) {
      _peerAvatarVer[payload.id] = payload.avatar;
      _savePeerAvatar(payload.id, payload.avatar);
    }
  }

  /// 已收到的对方头像 base64（避免重复写盘）
  final Map<String, String> _peerAvatarVer = {};

  Future<void> _savePeerAvatar(String id, String b64) async {
    try {
      final bytes = base64Decode(b64);
      if (_filesBase == null) {
        final doc = await getApplicationDocumentsDirectory();
        _filesBase = doc.path;
      }
      final dir = Directory(p.join(_filesBase!, 'avatars'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final path = p.join(dir.path, '$id.jpg');
      await File(path).writeAsBytes(bytes, flush: true);
      final d = _devices[id];
      if (d == null) return;
      _devices[id] = Device(
        id: d.id,
        name: d.name,
        ip: d.ip,
        port: d.port,
        avatarPath: path,
        lastSeen: d.lastSeen,
        isManual: d.isManual,
      );
      await db.upsertDevice(_devices[id]!);
      notifyListeners();
    } catch (_) {}
  }

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _pruneOffline() async {
    // 定期重查本机 IP：切换 WiFi/热点后 IP 变化，二维码/广播兜底需要最新值
    final ip = await _lookupSelfIp();
    if (ip.isNotEmpty && ip != selfIp) {
      selfIp = ip;
      notifyListeners();
    }
    // 多网卡场景（USB 共享 + 热点等）：网段集合变化时刷新，广播需要覆盖新网段
    final ips = await _lookupSelfIps();
    if (!_listEq(ips, _selfIps)) {
      _selfIps = ips;
      if (ips.isNotEmpty && selfIp.isEmpty) selfIp = ips.first;
      notifyListeners();
    }
    final now = DateTime.now();
    var changed = false;
    for (final dev in _devices.values) {
      if (now.difference(dev.lastSeen) > DiscoveryService.offlineAfter) {
        if (dev.isManual) continue;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  bool isOnline(Device d) =>
      DateTime.now().difference(d.lastSeen) <= DiscoveryService.offlineAfter;

  Future<void> _onFrame(
      String peerIp, MessageHeader header, Uint8List payload) async {
    switch (header.type) {
      case FrameType.text:
        final dev = await _findOrCreateDeviceByIp(
            peerIp, header.fromPort, header.fromName, header.fromId);
        if (dev == null) return;
        final m = Message(
          id: header.msgId,
          deviceId: dev.id,
          direction: 0,
          type: 'text',
          content: utf8.decode(payload, allowMalformed: true),
          status: 1,
          createdAt: DateTime.fromMillisecondsSinceEpoch(header.ts),
        );
        await db.insertMessage(m);
        _latestMsgs[dev.id] = m;
        _msgController.add(dev.id);
        notifyListeners();
      case FrameType.file:
      case FrameType.image:
        final dev =
            await _findOrCreateDeviceByIp(peerIp, header.fromPort, header.fromName);
        if (dev == null) return;
        final dir = await filesDir(dev.id);
        final path = p.join(dir, _receivedFileName(header));
        await File(path).writeAsBytes(payload, flush: true);
        final m = Message(
          id: header.msgId,
          deviceId: dev.id,
          direction: 0,
          type: header.type == FrameType.image ? 'image' : 'file',
          content: _sanitizeFileName(header.fileName ?? 'file'),
          filePath: path,
          fileSize: header.size ?? payload.length,
          status: 1,
          createdAt: DateTime.fromMillisecondsSinceEpoch(header.ts),
        );
        await db.insertMessage(m);
        _latestMsgs[dev.id] = m;
        _msgController.add(dev.id);
        notifyListeners();
      case FrameType.receipt:
        break;
    }
  }

  /// 通过 TCP 消息找/建设备。多重校验：
  /// 1) header 带 fromId（uuid）则按 uuid 找 —— IP 变了也命中同一设备并更新 IP（愈合）
  /// 2) 否则按源 IP 找；都没有则用 'ip-{ip}' 占位 id 新建
  /// 同时刷新 lastSeen（收到任何帧都算对方在线）。
  Future<Device?> _findOrCreateDeviceByIp(String ip,
      [int? learnPort, String? learnName, String? learnId]) async {
    // uuid 优先：IP 漂移场景下仍命中同一设备
    if (learnId != null && learnId.isNotEmpty) {
      final byId = _devices[learnId];
      if (byId != null) {
        var changed = false;
        if (byId.ip != ip && ip.isNotEmpty) {
          byId.ip = ip;
          changed = true;
        }
        if (learnPort != null && learnPort > 0 && byId.port != learnPort) {
          byId.port = learnPort;
          changed = true;
        }
        if (learnName != null &&
            learnName.isNotEmpty &&
            learnName != byId.name) {
          byId.name = learnName;
          changed = true;
        }
        byId.lastSeen = DateTime.now();
        if (changed) {
          db.upsertDevice(byId);
          notifyListeners();
        }
        return byId;
      }
    }
    // 回退按 IP 找
    for (final d in _devices.values) {
      if (d.ip == ip) {
        var changed = false;
        if (learnPort != null && learnPort > 0 && d.port != learnPort) {
          d.port = learnPort;
          changed = true;
        }
        if (learnName != null &&
            learnName.isNotEmpty &&
            learnName != d.name) {
          d.name = learnName;
          changed = true;
        }
        d.lastSeen = DateTime.now();
        if (changed) {
          db.upsertDevice(d);
          notifyListeners();
        }
        return d;
      }
    }
    final dev = Device(
      id: (learnId != null && learnId.isNotEmpty) ? learnId : 'ip-$ip',
      name: (learnName != null && learnName.isNotEmpty)
          ? learnName
          : '未知设备($ip)',
      ip: ip,
      port: learnPort ?? 0,
      lastSeen: DateTime.now(),
    );
    _devices[dev.id] = dev;
    await db.upsertDevice(dev);
    notifyListeners();
    return dev;
  }

  String? _filesBase;
  /// 当前接收文件保存根目录（供设置页展示）
  String get filesBase => _filesBase ?? '';
  Future<String> filesDir(String deviceId) async {
    if (_filesBase == null || _filesBase!.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      _filesBase = prefs.getString('filesDir');
      if (_filesBase == null || _filesBase!.isEmpty) {
        final doc = await getApplicationDocumentsDirectory();
        _filesBase = doc.path;
      }
    }
    final d = Directory(p.join(_filesBase!, 'files', deviceId));
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  /// 设置接收文件保存根目录（空串恢复默认 app 文档目录）
  Future<void> setFilesDir(String? dir) async {
    final prefs = await SharedPreferences.getInstance();
    if (dir == null || dir.isEmpty) {
      await prefs.remove('filesDir');
      _filesBase = null;
      final doc = await getApplicationDocumentsDirectory();
      _filesBase = doc.path;
    } else {
      _filesBase = dir;
      await prefs.setString('filesDir', dir);
    }
    notifyListeners();
  }

  /// 接收文件的落盘文件名（fileId 前缀防重名，全部做安全过滤）
  String _receivedFileName(MessageHeader header) {
    final safe = _sanitizeFileName(header.fileName ?? 'file');
    final fid = _sanitizeFileName(header.fileId ?? '');
    return fid.isEmpty ? safe : '${fid}_$safe';
  }

  /// 过滤文件名：去路径分隔符、Windows 非法字符与控制字符，防路径穿越
  String _sanitizeFileName(String name) {
    var n = name.trim().split(RegExp(r'[/\\]')).last;
    n = n.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    if (n.isEmpty || n == '.' || n == '..') n = 'file';
    if (n.length > 100) n = n.substring(n.length - 100);
    return n;
  }

  /// 文件/图片帧开始：开磁盘流，payload 由传输层流式写入
  Future<FrameFileSink?> _openFileSink(
      String peerIp, MessageHeader header) async {
    final dev = await _findOrCreateDeviceByIp(
        peerIp, header.fromPort, header.fromName, header.fromId);
    if (dev == null) return null;
    final dir = await filesDir(dev.id);
    final path = p.join(dir, _receivedFileName(header));
    // 通知 UI 开始接收 + 拉起前台服务防断链
    _activeTransfers.add(header.msgId);
    _fileProgressController.add(FileReceivingEvent(
      deviceId: dev.id,
      msgId: header.msgId,
      fileName: _sanitizeFileName(header.fileName ?? 'file'),
      total: header.size ?? 0,
      received: 0,
    ));
    _ensureTransferService();
    return FrameFileSink(File(path).openWrite(), path);
  }

  void _onFileProgress(
      String peerIp, MessageHeader header, int received, int total) {
    final devId = _deviceIdOf(peerIp, header);
    if (devId == null) return;
    _fileProgressController.add(FileReceivingEvent(
      deviceId: devId,
      msgId: header.msgId,
      fileName: _sanitizeFileName(header.fileName ?? 'file'),
      total: total,
      received: received,
    ));
  }

  void _onFileAbort(String peerIp, MessageHeader header) {
    _activeTransfers.remove(header.msgId);
    final devId = _deviceIdOf(peerIp, header);
    if (devId != null) {
      _fileProgressController.add(FileReceivingEvent(
        deviceId: devId,
        msgId: header.msgId,
        fileName: _sanitizeFileName(header.fileName ?? 'file'),
        total: header.size ?? 0,
        received: 0,
        done: true,
        failed: true,
      ));
    }
    _maybeStopTransferService();
  }

  /// 按消息头 fromId / 源 IP 查设备 id（不创建）
  String? _deviceIdOf(String peerIp, MessageHeader header) {
    final fid = header.fromId;
    if (fid != null && fid.isNotEmpty) {
      final d = _devices[fid];
      if (d != null) return d.id;
    }
    for (final d in _devices.values) {
      if (d.ip == peerIp) return d.id;
    }
    return null;
  }

  /// Android 接收文件期间拉起前台服务（通知栏常驻 + WakeLock），防止进程休眠断链
  Future<void> _ensureTransferService() async {
    if (!Platform.isAndroid || _serviceRunning) return;
    _serviceRunning = true;
    try {
      await _channel.invokeMethod('startTransferService');
    } catch (_) {
      _serviceRunning = false;
    }
  }

  Future<void> _maybeStopTransferService() async {
    if (_activeTransfers.isNotEmpty || !_serviceRunning) return;
    _serviceRunning = false;
    try {
      await _channel.invokeMethod('stopTransferService');
    } catch (_) {}
  }

  /// 文件/图片帧落盘完成：插消息、刷新预览/通知
  Future<void> _onFileDone(
      String peerIp, MessageHeader header, String path, int bytesWritten) async {
    final dev = await _findOrCreateDeviceByIp(
        peerIp, header.fromPort, header.fromName, header.fromId);
    if (dev == null) return;
    final m = Message(
      id: header.msgId,
      deviceId: dev.id,
      direction: 0,
      type: header.type == FrameType.image ? 'image' : 'file',
      content: _sanitizeFileName(header.fileName ?? 'file'),
      filePath: path,
      fileSize: header.size ?? bytesWritten,
      status: 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(header.ts),
    );
    await db.insertMessage(m);
    _latestMsgs[dev.id] = m;
    _msgController.add(dev.id);
    notifyListeners();
    // 接收完成：通知 UI 收起进度气泡，无进行中传输时停掉前台服务
    _activeTransfers.remove(header.msgId);
    _fileProgressController.add(FileReceivingEvent(
      deviceId: dev.id,
      msgId: header.msgId,
      fileName: m.content,
      total: m.fileSize ?? 0,
      received: m.fileSize ?? 0,
      done: true,
    ));
    _maybeStopTransferService();
  }

  /// 手动刷新设备列表（组播 + 子网探测）
  Future<void> refreshDevices() async {
    await _discovery?.refresh();
  }

  /// 删除设备及其全部消息与收到的文件
  Future<void> deleteDevice(String id) async {
    _devices.remove(id);
    _latestMsgs.remove(id);
    await db.deleteDevice(id);
    await _deleteFilesDir(id);
    notifyListeners();
  }

  /// 删除单条消息（received 文件一并删除）
  Future<void> deleteMessage(Message m) async {
    await db.deleteMessage(m.id);
    final latest = await db.latestMessageForDevice(m.deviceId);
    if (latest != null) {
      _latestMsgs[m.deviceId] = latest;
    } else {
      _latestMsgs.remove(m.deviceId);
    }
    if (m.direction == 0 && m.filePath != null) {
      try {
        final f = File(m.filePath!);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// 记录本机发出的消息，刷新设备列表预览/排序
  void recordSentMessage(Message m) {
    _latestMsgs[m.deviceId] = m;
    notifyListeners();
  }

  /// 发送文本失败时的愈合重试：
  /// 先单播 UDP 探测让对方应答（拿到对方新 IP/端口），再用新地址重发一次。
  /// 仍失败则返回 false（由调用方置发送失败）。
  Future<bool> retrySendText(String deviceId, String text) async {
    final dev = _devices[deviceId];
    if (dev == null) return false;
    // 触发一次探测：广播 + 子网探测，对方应答后 _onPeer 会更新 dev.ip/port
    await _discovery?.refresh();
    // 给应答一点时间到达（UDP 局域网通常 <200ms，留 800ms 兜底）
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final d2 = _devices[deviceId];
    if (d2 == null || d2.ip.isEmpty || d2.port <= 0) return false;
    if (d2.ip == dev.ip && d2.port == dev.port) return false; // 地址没变，不重试
    try {
      await transport.sendText(d2.ip, d2.port, text);
      // 成功：把愈合后的地址持久化
      dev.ip = d2.ip;
      dev.port = d2.port;
      dev.lastSeen = DateTime.now();
      await db.upsertDevice(dev);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 发送文件失败时的愈合重试（同 retrySendText 思路）
  Future<bool> retrySendFile(String deviceId,
      {required String filePath,
      required String fileName,
      required bool isImage,
      void Function(double)? onProgress}) async {
    final dev = _devices[deviceId];
    if (dev == null) return false;
    await _discovery?.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final d2 = _devices[deviceId];
    if (d2 == null || d2.ip.isEmpty || d2.port <= 0) return false;
    if (d2.ip == dev.ip && d2.port == dev.port) return false;
    try {
      await transport.sendFile(
        ip: d2.ip,
        port: d2.port,
        filePath: filePath,
        fileName: fileName,
        isImage: isImage,
        onProgress: onProgress,
      );
      dev.ip = d2.ip;
      dev.port = d2.port;
      dev.lastSeen = DateTime.now();
      await db.upsertDevice(dev);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清空与某设备的聊天记录与文件
  Future<void> clearMessages(String deviceId) async {
    await db.deleteMessagesForDevice(deviceId);
    _latestMsgs.remove(deviceId);
    await _deleteFilesDir(deviceId);
    notifyListeners();
  }

  Future<void> _deleteFilesDir(String deviceId) async {
    try {
      if (_filesBase != null) {
        final d = Directory(p.join(_filesBase!, 'files', deviceId));
        if (await d.exists()) await d.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> setSelfName(String name) async {
    selfName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selfName', name);
    notifyListeners();
  }

  Future<void> setSelfAvatar(String path) async {
    selfAvatar = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selfAvatar', path);
    try {
      final bytes = await File(path).readAsBytes();
      // 控制在单个 UDP 包安全范围内，超大的（如 Windows 未压缩原图）不参与同步
      selfAvatarB64 = bytes.length < 32000 ? base64Encode(bytes) : '';
    } catch (_) {
      selfAvatarB64 = '';
    }
    await prefs.setString('selfAvatarB64', selfAvatarB64);
    notifyListeners();
  }

  /// 手动添加设备（IP 方式，端口必填）；同 IP 已有条目则直接更新复用
  Future<void> addManualDevice(String ip, int port) async {
    final existing = _findByIp(ip);
    if (existing != null) {
      existing.port = port;
      existing.lastSeen = DateTime.now();
      existing.isManual = true;
      await db.upsertDevice(existing);
      notifyListeners();
      return;
    }
    final dev = Device(
      id: 'manual-$ip-$port',
      name: '手动设备($ip)',
      ip: ip,
      port: port,
      lastSeen: DateTime.now(),
      isManual: true,
    );
    _devices[dev.id] = dev;
    await db.upsertDevice(dev);
    notifyListeners();
  }

  /// 扫码添加设备；已存在则只补全有效字段（不清空已知 ip/头像），
  /// 同 IP 的旧条目（TCP 学习等）合并到扫码得到的真实 id
  Future<void> addManualDeviceById(String id, String name, int port,
      {String? ip}) async {
    final existing = _devices[id];
    if (existing != null) {
      var changed = false;
      if (ip != null && ip.isNotEmpty && existing.ip != ip) {
        existing.ip = ip;
        changed = true;
      }
      if (port > 0 && existing.port != port) {
        existing.port = port;
        changed = true;
      }
      if (name.isNotEmpty && existing.name != name) {
        existing.name = name;
        changed = true;
      }
      existing.lastSeen = DateTime.now();
      await db.upsertDevice(existing);
      if (changed) notifyListeners();
      return;
    }
    if (ip != null && ip.isNotEmpty) {
      final dups =
          _devices.values.where((d) => d.ip == ip && d.id != id).toList();
      for (final dup in dups) {
        _devices.remove(dup.id);
        if (_latestMsgs.remove(dup.id) case final m?) {
          _latestMsgs[id] = m;
        }
        await db.mergeDeviceId(dup.id, id);
        _mergeController.add((dup.id, id));
      }
    }
    final dev = Device(
      id: id,
      name: name.isNotEmpty ? name : '设备',
      ip: ip ?? '',
      port: port,
      lastSeen: DateTime.now(),
      isManual: true,
    );
    _devices[dev.id] = dev;
    await db.upsertDevice(dev);
    notifyListeners();
  }

  /// 从二维码解析：返回 (id, name, port)
  static (String, String, int)? parseQr(String raw) {
    if (!raw.startsWith('lanchat://')) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final id = uri.host;
    final name = uri.queryParameters['name'] ?? '设备';
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    if (id.isEmpty || port == null) return null;
    return (id, name, port);
  }

  /// 生成二维码内容：编码全部可达 IP（逗号分隔），对方扫码任选可达的一个连接
  String buildQr() {
    final ips = _selfIps.isNotEmpty ? _selfIps : (selfIp.isEmpty ? <String>[] : [selfIp]);
    final ipParam = ips.isEmpty ? '' : '&ip=${Uri.encodeComponent(ips.join(','))}';
    return 'lanchat://$selfId?name=${Uri.encodeComponent(selfName)}&port=$tcpPort$ipParam';
  }

  @override
  void dispose() {
    _pruneTimer?.cancel();
    _msgController.close();
    _mergeController.close();
    _fileProgressController.close();
    _discovery?.stop();
    transport.stop();
    super.dispose();
  }
}

/// 顶层 InheritedWidget 共享 AppState
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope(
      {super.key, required AppState notifier, required super.child})
      : super(notifier: notifier);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStateScope>()!.notifier!;
}

/// 接收文件的进度事件（接收方聊天页「正在接收」气泡用）
class FileReceivingEvent {
  final String deviceId;
  final String msgId;
  final String fileName;
  final int total;
  final int received;
  final bool done; // true = 结束（失败时 failed 也为 true）
  final bool failed;

  const FileReceivingEvent({
    required this.deviceId,
    required this.msgId,
    required this.fileName,
    required this.total,
    required this.received,
    this.done = false,
    this.failed = false,
  });
}
