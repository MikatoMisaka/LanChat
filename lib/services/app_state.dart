import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'db_service.dart';
import 'discovery_service.dart';
import 'file_digest.dart';
import 'identity_service.dart';
import 'notification_service.dart';
import 'secure_protocol.dart';
import 'secure_transport_service.dart';

class AppStateDisposedException implements Exception {
  @override
  String toString() => 'AppStateDisposedException';
}

/// 全局应用状态：串联发现层/传输层/数据库
class AppState extends ChangeNotifier {
  static const _channel = MethodChannel('lanchat/multicast');
  final MethodChannel _multicastChannel;
  late final Future<List<String>> Function()? _selfIpsLookup;
  bool _multicastLockHeld = false;

  final DbService db = DbService();
  final IdentityService identityService;
  final LocalNotificationService? notificationService;
  DiscoveryService? _discovery;
  DiscoveryService? get discovery => _discovery;
  late final SecureTransportService transport;

  String selfId = '';
  String selfName = '';
  String? selfAvatar;
  String selfAvatarB64 = '';
  String _identityPublicKey = '';
  String get identityPublicKey => _identityPublicKey;
  String selfIp = '';
  List<String> _selfIps = [];

  /// 全部可用本机 IPv4（多网卡/多网段场景，发现层按网段广播）
  List<String> get selfIps => List.unmodifiable(_selfIps);
  int tcpPort = 0;
  bool _inited = false;
  bool _disposed = false;
  Future<void>? _initializationFuture;
  Object? _initializationError;
  bool get isInitialized => _inited;
  Object? get initializationError => _initializationError;
  Timer? _pruneTimer;

  final Map<String, Device> _devices = {};
  Map<String, Device> get devices => Map.unmodifiable(_devices);

  final Map<String, Message> _latestMsgs = {};
  Map<String, Message> get latestMsgs => _latestMsgs;

  final _msgController = StreamController<String>.broadcast();
  Stream<String> get onNewMessage => _msgController.stream;

  final _pairingController = StreamController<PairingRequest>.broadcast();
  Stream<PairingRequest> get onPairingRequest => _pairingController.stream;

  final _fileOfferController = StreamController<IncomingFileOffer>.broadcast();
  Stream<IncomingFileOffer> get onFileOffer => _fileOfferController.stream;
  final Map<String, Completer<bool>> _pairingDecisions = {};
  final Map<String, Completer<FileOfferDecision>> _fileOfferDecisions = {};
  final Map<String, IncomingFileOffer> _pendingFileOffers = {};
  final Map<String, _IncomingFileTransfer> _incomingFiles = {};
  final Set<String> _outgoingTransfers = {};
  final Map<String, PairingRequest> _pendingPairingRequests = {};
  final _localUuid = const Uuid();

  final _mergeController = StreamController<(String, String)>.broadcast();

  /// 设备合并事件 (旧id, 新id)：打开中的聊天页跟随切换，避免失联
  Stream<(String, String)> get onDeviceMerged => _mergeController.stream;

  final _fileProgressController =
      StreamController<FileReceivingEvent>.broadcast();

  /// 接收文件进度事件流（接收方聊天页显示「正在接收」气泡+进度条）
  Stream<FileReceivingEvent> get onFileReceiving =>
      _fileProgressController.stream;

  /// 正在接收中的文件 msgId 集合（用于前台服务的启停）
  final Set<String> _activeTransfers = {};
  bool _serviceRunning = false;

  AppState({
    IdentityService? identityService,
    this.notificationService,
    MethodChannel? multicastChannel,
    Future<List<String>> Function()? selfIpsLookup,
  }) : identityService = identityService ?? IdentityService(),
       _multicastChannel = multicastChannel ?? _channel {
    _selfIpsLookup = selfIpsLookup;
    transport = SecureTransportService(
      selfName: () => selfName,
      selfId: () => selfId,
      selfPublicKey: this.identityService.publicKey,
      sharedSecretForPublicKey: this.identityService.sharedSecretWith,
      peerPublicKey: this.identityService.readPeerPublicKey,
      savePeerPublicKey: this.identityService.savePeerPublicKey,
      onSecureEvent: _onSecureEvent,
      onPairingRequest: _onPairingRequest,
      onPairingComplete: _onPairingComplete,
      onFileOffer: _onFileOffer,
      onFileChunk: _onFileChunk,
      onFileComplete: _onFileComplete,
      onDisconnect: _onDisconnect,
    );
  }

  Future<void> init() {
    if (_disposed) return Future.error(AppStateDisposedException());
    if (_inited) return Future.value();
    return _initializationFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await initializeIdentity();
      _throwIfDisposed();
      final prefs = await SharedPreferences.getInstance();
      _throwIfDisposed();
      final legacyFilesBase = prefs.getString('filesDir');
      selfId = prefs.getString('selfId') ?? '';
      if (selfId.isEmpty) {
        selfId = const Uuid().v4();
        await prefs.setString('selfId', selfId);
        _throwIfDisposed();
      }
      selfName =
          prefs.getString('selfName') ?? '用户${selfId.hashCode.abs() % 10000}';
      selfAvatar = prefs.getString('selfAvatar');
      selfAvatarB64 = prefs.getString('selfAvatarB64') ?? '';
      _filesBase = null;
      _notifyIfActive();

      tcpPort = await transport.start();
      _throwIfDisposed();
      selfIp = await _lookupSelfIp();
      _throwIfDisposed();
      _selfIps = await _lookupSelfIps();
      _throwIfDisposed();
      _notifyIfActive();

      final devices = await db.getAllDevices();
      _throwIfDisposed();
      for (final dev in devices) {
        _devices[dev.id] = dev;
      }
      final latestMessages = await db.latestMessagePerDevice();
      _throwIfDisposed();
      _latestMsgs.addAll(latestMessages);
      for (final transfer in await db.getTransfers()) {
        if (transfer.direction != 0) continue;
        final part = File(transfer.filePath);
        if (!await part.exists()) {
          await db.deleteTransfer(transfer.id);
          continue;
        }
        final received = await part.length();
        if (received > transfer.totalBytes) {
          await db.deleteTransfer(transfer.id);
          continue;
        }
        _incomingFiles[transfer.id] = _IncomingFileTransfer(
          transferId: transfer.id,
          deviceId: transfer.deviceId,
          fileName: transfer.fileName,
          total: transfer.totalBytes,
          isImage: transfer.type == 'image',
          partPath: transfer.filePath,
          finalDirectory: p.dirname(transfer.filePath),
          messageId: transfer.messageId ?? _localUuid.v4(),
          timestamp: transfer.updatedAt.millisecondsSinceEpoch,
          sink: null,
          received: received,
        );
      }
      if (db.didResetLegacyData) {
        await _clearLegacyFiles(legacyFilesBase);
        await prefs.remove('filesDir');
      }
      _throwIfDisposed();
      _notifyIfActive();

      _discovery = DiscoveryService(
        selfId: selfId,
        selfName: () => selfName,
        selfTcpPort: () => tcpPort,
        selfIp: () => selfIp,
        selfIps: () => _selfIps,
        selfPublicKey: () => _identityPublicKey,
        onPeer: _onPeer,
      );

      await _acquireMulticastLock();
      _throwIfDisposed();
      await _discovery!.start();
      _throwIfDisposed();

      _pruneTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _pruneOffline(),
      );
      _inited = true;
      _initializationError = null;
    } catch (error) {
      _inited = false;
      if (_disposed) {
        _stopInitializationResources();
      } else {
        _initializationError = error;
        notifyListeners();
      }
      rethrow;
    } finally {
      if (!_inited) _initializationFuture = null;
    }
  }

  Future<void> initializeIdentity() async {
    _throwIfDisposed();
    try {
      final publicKey = await identityService.publicKey();
      _throwIfDisposed();
      _identityPublicKey = publicKey;
      _initializationError = null;
    } catch (error) {
      if (!_disposed) {
        _initializationError = error;
        notifyListeners();
      }
      rethrow;
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw AppStateDisposedException();
  }

  void _notifyIfActive() {
    if (!_disposed) notifyListeners();
  }

  void _stopInitializationResources() {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _discovery?.stop();
    _discovery = null;
    transport.stop();
    tcpPort = 0;
    unawaited(_releaseMulticastLock());
  }

  Future<String> _lookupSelfIp() async {
    final ips = await _lookupSelfIps();
    return ips.isEmpty ? '' : ips.first;
  }

  /// 收集所有可用于通信的本机 IPv4（过滤虚拟网卡），按优先级排序。
  /// 多接口场景（USB 共享 + 热点同时开）下广播/探测需要覆盖全部网段。
  Future<List<String>> _lookupSelfIps() async {
    final lookup = _selfIpsLookup;
    if (lookup != null) return lookup();

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
      await _multicastChannel.invokeMethod('acquire');
      _multicastLockHeld = true;
      if (_disposed) await _releaseMulticastLock();
    } catch (_) {}
  }

  Future<void> _releaseMulticastLock() async {
    if (!_multicastLockHeld) return;
    _multicastLockHeld = false;
    try {
      await _multicastChannel.invokeMethod('release');
    } catch (_) {}
  }

  @visibleForTesting
  Future<void> acquireMulticastLockForTesting() => _acquireMulticastLock();

  @visibleForTesting
  Future<void> pruneOfflineForTesting() => _pruneOffline();

  /// 打开系统设置页（相机权限被拒绝时引导）
  Future<void> openAppSettings() async {
    try {
      await _multicastChannel.invokeMethod('openSettings');
    } catch (_) {}
  }

  void _onPeer(DiscoveryPayload payload, String fromIp) {
    final ip = fromIp.isNotEmpty ? fromIp : payload.ip;
    final existing = _devices[payload.id];
    // Discovery is unauthenticated. It may create a temporary candidate, but
    // it must never overwrite an already paired endpoint or profile.
    if (existing?.isPaired == true) {
      unawaited(_refreshPairedEndpoint(payload, ip));
      return;
    }
    if (existing == null &&
        _devices.values.where((device) => !device.isPaired).length >= 128) {
      return;
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
      isPaired: false,
    );
    _devices[payload.id] = dev;
    _notifyIfActive();
  }

  Future<void> _refreshPairedEndpoint(
    DiscoveryPayload payload,
    String ip,
  ) async {
    if (payload.publicKey.isEmpty) return;
    try {
      final trusted = await identityService.readPeerPublicKey(payload.id);
      if (_disposed || trusted != payload.publicKey) return;
      final device = _devices[payload.id];
      if (device == null || !device.isPaired) return;
      var changed = false;
      if (ip.isNotEmpty && device.ip != ip) {
        device.ip = ip;
        changed = true;
      }
      if (device.port != payload.tcpPort) {
        device.port = payload.tcpPort;
        changed = true;
      }
      device.lastSeen = DateTime.now();
      if (changed) await db.upsertDevice(device);
      _notifyIfActive();
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
    if (_disposed) return;
    if (ip.isNotEmpty && ip != selfIp) {
      if (_disposed) return;
      selfIp = ip;
      _notifyIfActive();
    }
    // 多网卡场景（USB 共享 + 热点等）：网段集合变化时刷新，广播需要覆盖新网段
    final ips = await _lookupSelfIps();
    if (_disposed) return;
    if (!_listEq(ips, _selfIps)) {
      if (_disposed) return;
      _selfIps = ips;
      if (ips.isNotEmpty && selfIp.isEmpty) selfIp = ips.first;
      _notifyIfActive();
    }
    final now = DateTime.now();
    var changed = false;
    for (final dev in _devices.values) {
      if (now.difference(dev.lastSeen) > DiscoveryService.offlineAfter) {
        if (dev.isManual) continue;
        changed = true;
      }
    }
    if (changed) _notifyIfActive();
  }

  bool isOnline(Device d) =>
      DateTime.now().difference(d.lastSeen) <= DiscoveryService.offlineAfter;

  Future<void> _onSecureEvent(String peerId, SecureEvent event) async {
    final dev = _devices[peerId];
    if (dev == null || !dev.isPaired || _disposed) return;
    dev.lastSeen = DateTime.now();
    await db.upsertDevice(dev);
    if (_disposed) return;
    if (event.kind != 'text') return;
    final text = event.fields['text'];
    if (text is! String) return;
    final m = Message(
      id: _safeMessageId(event.fields['messageId']),
      deviceId: dev.id,
      direction: 0,
      type: 'text',
      content: text,
      status: 1,
      createdAt: _safeMessageTime(event.fields['timestamp']),
    );
    if (await db.messageExists(m.id)) return;
    await db.insertMessage(m);
    if (_disposed) return;
    _latestMsgs[dev.id] = m;
    _msgController.add(dev.id);
    _notifyIfActive();
    final notifications = notificationService;
    if (notifications != null) {
      unawaited(notifications.showMessage(dev.name));
    }
  }

  Future<bool> _onPairingRequest(PairingRequest request) {
    if (_disposed || _devices[request.peerId]?.isPaired == true) {
      return Future.value(false);
    }
    _devices[request.peerId] = Device(
      id: request.peerId,
      name: request.peerName,
      ip: request.peerIp,
      port: request.peerPort,
      lastSeen: DateTime.now(),
      isManual: true,
      isPaired: false,
    );
    _notifyIfActive();
    final decision = Completer<bool>();
    _pairingDecisions[request.requestId] = decision;
    _pendingPairingRequests[request.requestId] = request;
    _pairingController.add(request);
    return decision.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        _pairingDecisions.remove(request.requestId);
        _pendingPairingRequests.remove(request.requestId);
        return false;
      },
    );
  }

  Future<void> decidePairing(String requestId, bool accepted) async {
    final decision = _pairingDecisions.remove(requestId);
    _pendingPairingRequests.remove(requestId);
    if (decision != null && !decision.isCompleted) decision.complete(accepted);
  }

  Future<PairingAttempt> requestPairing(
    String ip,
    int port, {
    String? expectedPeerId,
  }) => transport.requestPairing(ip, port, expectedPeerId: expectedPeerId);

  Future<void> _onPairingComplete(
    String peerId,
    String peerName,
    String ip,
    int port,
  ) async {
    if (_disposed) return;
    final existing = _devices[peerId];
    final device = Device(
      id: peerId,
      name: peerName.isEmpty ? (existing?.name ?? '设备') : peerName,
      ip: ip,
      port: port,
      avatarPath: existing?.avatarPath,
      lastSeen: DateTime.now(),
      isManual: true,
      isPaired: true,
    );
    _devices[peerId] = device;
    await db.upsertDevice(device);
    _notifyIfActive();
  }

  Future<FileOfferDecision> _onFileOffer(String peerId, SecureEvent event) {
    final dev = _devices[peerId];
    if (_disposed || dev == null || !dev.isPaired) {
      return Future.value(const FileOfferDecision.reject());
    }
    final transferId = event.fields['transferId'];
    final fileName = event.fields['fileName'];
    final size = event.fields['size'];
    if (transferId is! String ||
        fileName is! String ||
        size is! int ||
        transferId.isEmpty ||
        fileName.isEmpty ||
        size < 0) {
      return Future.value(const FileOfferDecision.reject());
    }
    if (_fileOfferDecisions.containsKey(transferId)) {
      return Future.value(const FileOfferDecision.reject());
    }
    if (!_incomingFiles.containsKey(transferId) &&
        _activeTransfers.length + _fileOfferDecisions.length >= 3) {
      return Future.value(const FileOfferDecision.reject());
    }
    final offer = IncomingFileOffer(
      transferId: transferId,
      peerId: peerId,
      fileName: _sanitizeFileName(fileName),
      size: size,
      isImage: event.fields['image'] == true,
      messageId: _safeMessageId(event.fields['messageId']),
      timestamp: _safeMessageTime(event.fields['timestamp'])
          .millisecondsSinceEpoch,
    );
    final decision = Completer<FileOfferDecision>();
    _pendingFileOffers[transferId] = offer;
    _fileOfferDecisions[transferId] = decision;
    _fileOfferController.add(offer);
    return decision.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        _pendingFileOffers.remove(transferId);
        _fileOfferDecisions.remove(transferId);
        return const FileOfferDecision.reject();
      },
    );
  }

  Future<void> decideFileOffer(String transferId, bool accepted) async {
    final decision = _fileOfferDecisions.remove(transferId);
    final offer = _pendingFileOffers.remove(transferId);
    if (decision == null || decision.isCompleted || offer == null) return;
    if (!accepted) {
      decision.complete(const FileOfferDecision.reject());
      return;
    }
    try {
      decision.complete(await _prepareIncomingFile(offer));
    } catch (_) {
      decision.complete(const FileOfferDecision.reject());
    }
  }

  Future<FileOfferDecision> _prepareIncomingFile(
    IncomingFileOffer offer,
  ) async {
    final device = _devices[offer.peerId];
    if (device == null || !device.isPaired) {
      return const FileOfferDecision.reject();
    }
    final existing = _incomingFiles[offer.transferId];
    if (existing != null) {
      if (existing.deviceId != offer.peerId ||
          existing.total != offer.size ||
          existing.isImage != offer.isImage ||
          existing.fileName != offer.fileName ||
          existing.messageId != offer.messageId) {
        return const FileOfferDecision.reject();
      }
      await existing.sink?.close();
      final length = await File(existing.partPath).length();
      existing.sink = File(existing.partPath).openWrite(mode: FileMode.append);
      existing.received = length;
      existing.persistedOffset = length;
      await _persistIncomingTransfer(existing, 'receiving');
      _activeTransfers.add(offer.transferId);
      _fileProgressController.add(
        FileReceivingEvent(
          deviceId: offer.peerId,
          msgId: offer.transferId,
          fileName: offer.fileName,
          total: offer.size,
          received: length,
        ),
      );
      _ensureTransferService();
      return FileOfferDecision.accept(offset: length);
    }
    final dir = await filesDir(device.id);
    final localId = _localUuid.v4();
    final partPath = p.join(dir, '.$localId.part');
    final transfer = _IncomingFileTransfer(
      transferId: offer.transferId,
      deviceId: offer.peerId,
      fileName: offer.fileName,
      total: offer.size,
      isImage: offer.isImage,
      partPath: partPath,
      finalDirectory: dir,
      messageId: offer.messageId,
      timestamp: offer.timestamp,
      sink: File(partPath).openWrite(),
      received: 0,
    );
    _incomingFiles[offer.transferId] = transfer;
    await _persistIncomingTransfer(transfer, 'receiving');
    _activeTransfers.add(offer.transferId);
    _fileProgressController.add(
      FileReceivingEvent(
        deviceId: offer.peerId,
        msgId: offer.transferId,
        fileName: offer.fileName,
        total: offer.size,
        received: 0,
      ),
    );
    _ensureTransferService();
    return const FileOfferDecision.accept();
  }

  Future<void> _onFileChunk(String peerId, SecureEvent event) async {
    if (_disposed) throw StateError('Application state is disposed.');
    final transferId = event.fields['transferId'];
    final offset = event.fields['offset'];
    final transfer = transferId is String ? _incomingFiles[transferId] : null;
    if (transfer == null ||
        transfer.deviceId != peerId ||
        offset != transfer.received) {
      throw StateError('Unexpected file chunk.');
    }
    final sink = transfer.sink;
    if (sink == null) throw StateError('File transfer sink is closed.');
    sink.add(event.bytes);
    transfer.received += event.bytes.length;
    transfer.unflushedBytes += event.bytes.length;
    if (transfer.unflushedBytes >= 256 * 1024 ||
        transfer.received == transfer.total) {
      await sink.flush();
      transfer.unflushedBytes = 0;
    }
    if (transfer.received - transfer.persistedOffset >= 1024 * 1024 ||
        transfer.received == transfer.total) {
      await _persistIncomingTransfer(transfer, 'receiving');
      transfer.persistedOffset = transfer.received;
    }
    _fileProgressController.add(
      FileReceivingEvent(
        deviceId: peerId,
        msgId: transferId as String,
        fileName: transfer.fileName,
        total: transfer.total,
        received: transfer.received,
      ),
    );
  }

  void _onDisconnect(String peerIp, String? peerId) {
    if (peerId == null || _disposed) return;
    for (final request
        in _pendingPairingRequests.values
            .where((request) => request.peerId == peerId)
            .toList()) {
      unawaited(decidePairing(request.requestId, false));
    }
    for (final offer
        in _pendingFileOffers.values
            .where((offer) => offer.peerId == peerId)
            .toList()) {
      unawaited(decideFileOffer(offer.transferId, false));
    }
    final transfers = _incomingFiles.values
        .where(
          (transfer) => transfer.deviceId == peerId && transfer.sink != null,
        )
        .toList();
    for (final transfer in transfers) {
      final sink = transfer.sink;
      transfer.sink = null;
      transfer.unflushedBytes = 0;
      unawaited(sink!.flush().then((_) => sink.close()).catchError((_) {}));
      unawaited(_persistIncomingTransfer(transfer, 'paused'));
      _fileProgressController.add(
        FileReceivingEvent(
          deviceId: peerId,
          msgId: transfer.transferId,
          fileName: transfer.fileName,
          total: transfer.total,
          received: transfer.received,
          done: true,
          failed: true,
        ),
      );
      _activeTransfers.remove(transfer.transferId);
    }
    unawaited(_maybeStopTransferService());
  }

  Future<bool> _onFileComplete(String peerId, SecureEvent event) async {
    if (_disposed) return false;
    final transferId = event.fields['transferId'];
    final transfer = transferId is String ? _incomingFiles[transferId] : null;
    if (transfer == null || transfer.deviceId != peerId) return false;
    await transfer.sink?.flush();
    await transfer.sink?.close();
    transfer.sink = null;
    final file = File(transfer.partPath);
    final digest = await sha256File(file);
    final expectedDigest = event.fields['digest'];
    if (transfer.received != transfer.total || digest != expectedDigest) {
      await _persistIncomingTransfer(transfer, 'paused');
      _activeTransfers.remove(transfer.transferId);
      _maybeStopTransferService();
      _fileProgressController.add(
        FileReceivingEvent(
          deviceId: peerId,
          msgId: transfer.transferId,
          fileName: transfer.fileName,
          total: transfer.total,
          received: transfer.received,
          done: true,
          failed: true,
        ),
      );
      return false;
    }
    if (await db.messageExists(transfer.messageId)) {
      await file.delete();
      await db.deleteTransfer(transfer.transferId);
      _incomingFiles.remove(transfer.transferId);
      _activeTransfers.remove(transfer.transferId);
      return true;
    }
    final finalPath = p.join(
      transfer.finalDirectory,
      '${_localUuid.v4()}_${_sanitizeFileName(transfer.fileName)}',
    );
    await file.rename(finalPath);
    final message = Message(
      id: transfer.messageId,
      deviceId: peerId,
      direction: 0,
      type: transfer.isImage ? 'image' : 'file',
      content: transfer.fileName,
      filePath: finalPath,
      fileSize: transfer.total,
      status: 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(transfer.timestamp),
    );
    await db.insertMessage(message);
    await db.deleteTransfer(transfer.transferId);
    _incomingFiles.remove(transfer.transferId);
    _activeTransfers.remove(transfer.transferId);
    _latestMsgs[peerId] = message;
    _msgController.add(peerId);
    _fileProgressController.add(
      FileReceivingEvent(
        deviceId: peerId,
        msgId: transfer.transferId,
        fileName: transfer.fileName,
        total: transfer.total,
        received: transfer.total,
        done: true,
      ),
    );
    _maybeStopTransferService();
    _notifyIfActive();
    return true;
  }

  Future<void> _persistIncomingTransfer(
    _IncomingFileTransfer transfer,
    String status,
  ) {
    return db.upsertTransfer(
      TransferRecord(
        id: transfer.transferId,
        deviceId: transfer.deviceId,
        messageId: transfer.messageId,
        direction: 0,
        type: transfer.isImage ? 'image' : 'file',
        fileName: transfer.fileName,
        filePath: transfer.partPath,
        totalBytes: transfer.total,
        offsetBytes: transfer.received,
        digest: null,
        status: status,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<String> sendFile(
    Message message, {
    void Function(double progress)? onProgress,
  }) async {
    final device = _devices[message.deviceId];
    final path = message.filePath;
    if (device == null || !device.isPaired || path == null) {
      throw StateError('Paired device or source file is missing.');
    }
    final file = File(path);
    final size = await file.length();
    final id = message.transferId ?? _localUuid.v4();
    if (!_outgoingTransfers.contains(id) && _outgoingTransfers.length >= 3) {
      throw StateError('最多同时传输 3 个文件。');
    }
    message.transferId = id;
    final record = TransferRecord(
      id: id,
      deviceId: message.deviceId,
      messageId: message.id,
      direction: 1,
      type: message.type,
      fileName: _sanitizeFileName(message.content),
      filePath: path,
      totalBytes: size,
      offsetBytes: 0,
      digest: null,
      status: 'sending',
      updatedAt: DateTime.now(),
    );
    _outgoingTransfers.add(id);
    try {
      await db.upsertTransfer(record);
      try {
        final transferId = await transport.sendFile(
          ip: device.ip,
          port: device.port,
          filePath: path,
          fileName: message.content,
          isImage: message.type == 'image',
          peerId: device.id,
          transferId: id,
          messageId: message.id,
          timestamp: message.createdAt.millisecondsSinceEpoch,
          onProgress: onProgress,
        );
        await db.deleteTransfer(transferId);
        return transferId;
      } catch (_) {
        await db.upsertTransfer(
          TransferRecord(
            id: record.id,
            deviceId: record.deviceId,
            messageId: record.messageId,
            direction: record.direction,
            type: record.type,
            fileName: record.fileName,
            filePath: record.filePath,
            totalBytes: record.totalBytes,
            offsetBytes: record.offsetBytes,
            digest: record.digest,
            status: 'paused',
            updatedAt: DateTime.now(),
          ),
        );
        rethrow;
      }
    } finally {
      _outgoingTransfers.remove(id);
    }
  }

  String? _filesBase;

  /// 当前接收文件保存根目录（供设置页展示）
  String get filesBase => _filesBase ?? '';
  Future<String> filesDir(String deviceId) async {
    if (_filesBase == null || _filesBase!.isEmpty) {
      _filesBase = await _defaultFilesBase();
    }
    final d = Directory(
      p.join(_filesBase!, 'files', _deviceStorageKey(deviceId)),
    );
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  String _deviceStorageKey(String deviceId) =>
      crypto.sha256.convert(utf8.encode(deviceId)).toString();

  String _safeMessageId(Object? value) =>
      value is String && value.isNotEmpty && value.length <= 128
      ? value
      : _localUuid.v4();

  DateTime _safeMessageTime(Object? value) {
    final now = DateTime.now();
    if (value is! int) return now;
    try {
      final timestamp = DateTime.fromMillisecondsSinceEpoch(value);
      return timestamp.difference(now).abs() <= const Duration(days: 365)
          ? timestamp
          : now;
    } catch (_) {
      return now;
    }
  }

  Future<String> _defaultFilesBase() async {
    final directory = Platform.isWindows || Platform.isLinux
        ? await getApplicationSupportDirectory()
        : await getApplicationDocumentsDirectory();
    return directory.path;
  }

  /// 过滤文件名：去路径分隔符、Windows 非法字符与控制字符，防路径穿越
  String _sanitizeFileName(String name) {
    var n = name.trim().split(RegExp(r'[/\\]')).last;
    n = n.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    n = n.replaceAll(RegExp(r'\.+$'), '_');
    if (n.isEmpty || n == '.' || n == '..') n = 'file';
    if (n.length > 100) n = n.substring(n.length - 100);
    return n;
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

  /// 手动刷新设备列表（组播 + 子网探测）
  Future<void> refreshDevices() async {
    await _discovery?.refresh();
  }

  /// 删除设备及其全部消息与收到的文件
  Future<void> deleteDevice(String id) async {
    await _cancelIncomingTransfers(id);
    _devices.remove(id);
    _latestMsgs.remove(id);
    await db.deleteDevice(id);
    await identityService.removePeerPublicKey(id);
    await _deleteFilesDir(id);
    _notifyIfActive();
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
  Future<bool> retrySendText(
    String deviceId,
    String text, {
    String? messageId,
    int? timestamp,
  }) async {
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
      await transport.sendText(
        d2.ip,
        d2.port,
        text,
        peerId: dev.id,
        messageId: messageId,
        timestamp: timestamp,
      );
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
  Future<bool> retrySendFile(
    String deviceId, {
    required String filePath,
    required String fileName,
    required bool isImage,
    String? messageId,
    int? timestamp,
    String? transferId,
    void Function(double)? onProgress,
  }) async {
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
        peerId: dev.id,
        transferId: transferId,
        messageId: messageId,
        timestamp: timestamp,
        onProgress: onProgress,
      );
      dev.ip = d2.ip;
      dev.port = d2.port;
      dev.lastSeen = DateTime.now();
      await db.upsertDevice(dev);
      if (transferId != null) await db.deleteTransfer(transferId);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清空与某设备的聊天记录与文件
  Future<void> clearMessages(String deviceId) async {
    await _cancelIncomingTransfers(deviceId);
    await db.deleteMessagesForDevice(deviceId);
    _latestMsgs.remove(deviceId);
    await _deleteFilesDir(deviceId);
    notifyListeners();
  }

  Future<void> _deleteFilesDir(String deviceId) async {
    try {
      final base = _filesBase ?? await _defaultFilesBase();
      final d = Directory(p.join(base, 'files', _deviceStorageKey(deviceId)));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _cancelIncomingTransfers(String deviceId) async {
    final transfers = _incomingFiles.values
        .where((transfer) => transfer.deviceId == deviceId)
        .toList();
    for (final transfer in transfers) {
      await transfer.sink?.close();
      _incomingFiles.remove(transfer.transferId);
      _activeTransfers.remove(transfer.transferId);
      await db.deleteTransfer(transfer.transferId);
    }
    await _maybeStopTransferService();
  }

  Future<void> _clearLegacyFiles(String? legacyFilesBase) async {
    try {
      final doc = await getApplicationDocumentsDirectory();
      final support = await getApplicationSupportDirectory();
      final roots = <String>{doc.path, support.path};
      if (legacyFilesBase != null && legacyFilesBase.isNotEmpty) {
        roots.add(legacyFilesBase);
      }
      for (final root in roots) {
        for (final name in ['files', 'avatars']) {
          final directory = Directory(p.join(root, name));
          if (await directory.exists()) await directory.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  Future<void> setSelfName(String name) async {
    final normalized = name.trim();
    selfName = normalized.isEmpty
        ? '用户${selfId.hashCode.abs() % 10000}'
        : normalized.characters.take(64).join();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selfName', selfName);
    _notifyIfActive();
  }

  Future<void> clearAllMessages() async {
    final deviceIds = <String>{
      ..._devices.keys,
      ..._incomingFiles.values.map((transfer) => transfer.deviceId),
    };
    for (final deviceId in deviceIds) {
      await _cancelIncomingTransfers(deviceId);
    }
    await db.clearAllMessages();
    _latestMsgs.clear();
    try {
      final base = _filesBase ?? await _defaultFilesBase();
      final files = Directory(p.join(base, 'files'));
      if (await files.exists()) await files.delete(recursive: true);
    } catch (_) {}
    _notifyIfActive();
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

  /// 从二维码解析：返回 (id, name, port)
  static (String, String, int)? parseQr(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'lanchat') return null;
    final id = uri.host;
    final name = uri.queryParameters['name'] ?? '设备';
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    if (id.isEmpty ||
        id.length > 128 ||
        name.length > 128 ||
        port == null ||
        port <= 0 ||
        port > 65535) {
      return null;
    }
    return (id, name, port);
  }

  /// 生成二维码内容：编码全部可达 IP（逗号分隔），对方扫码任选可达的一个连接
  String buildQr() {
    final ips = _selfIps.isNotEmpty
        ? _selfIps
        : (selfIp.isEmpty ? <String>[] : [selfIp]);
    final ipParam = ips.isEmpty
        ? ''
        : '&ip=${Uri.encodeComponent(ips.join(','))}';
    return 'lanchat://$selfId?name=${Uri.encodeComponent(selfName)}&port=$tcpPort$ipParam';
  }

  @override
  void dispose() {
    _disposed = true;
    for (final decision in _pairingDecisions.values) {
      if (!decision.isCompleted) decision.complete(false);
    }
    for (final decision in _fileOfferDecisions.values) {
      if (!decision.isCompleted) {
        decision.complete(const FileOfferDecision.reject());
      }
    }
    _pairingDecisions.clear();
    _pendingPairingRequests.clear();
    _fileOfferDecisions.clear();
    _pendingFileOffers.clear();
    for (final transfer in _incomingFiles.values) {
      unawaited(transfer.sink?.close());
    }
    _incomingFiles.clear();
    _stopInitializationResources();
    _msgController.close();
    _pairingController.close();
    _fileOfferController.close();
    _mergeController.close();
    _fileProgressController.close();
    super.dispose();
  }
}

/// 顶层 InheritedWidget 共享 AppState
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState notifier,
    required super.child,
  }) : super(notifier: notifier);

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

class IncomingFileOffer {
  const IncomingFileOffer({
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.size,
    required this.isImage,
    required this.messageId,
    required this.timestamp,
  });

  final String transferId;
  final String peerId;
  final String fileName;
  final int size;
  final bool isImage;
  final String messageId;
  final int timestamp;
}

class _IncomingFileTransfer {
  _IncomingFileTransfer({
    required this.transferId,
    required this.deviceId,
    required this.fileName,
    required this.total,
    required this.isImage,
    required this.partPath,
    required this.finalDirectory,
    required this.messageId,
    required this.timestamp,
    required this.sink,
    this.received = 0,
  });

  final String transferId;
  final String deviceId;
  final String fileName;
  final int total;
  final bool isImage;
  final String partPath;
  final String finalDirectory;
  final String messageId;
  final int timestamp;
  IOSink? sink;
  int received;
  int persistedOffset = 0;
  int unflushedBytes = 0;
}
