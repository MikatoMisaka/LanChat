import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 设备广播/应答的 payload
class DiscoveryPayload {
  final String id;
  final String name;
  final String ip;
  final int tcpPort;
  final bool isReply;
  final String avatar;

  const DiscoveryPayload({
    required this.id,
    required this.name,
    required this.ip,
    required this.tcpPort,
    this.isReply = false,
    this.avatar = '',
  });

  String encode() => jsonEncode({
        'id': id,
        'name': name,
        'ip': ip,
        'tcpPort': tcpPort,
        if (avatar.isNotEmpty) 'avatar': avatar,
        if (isReply) 'reply': true,
      });

  static DiscoveryPayload? decode(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final id = m['id'];
      final name = m['name'];
      final ip = m['ip'];
      final port = m['tcpPort'];
      if (id is! String || name is! String || ip is! String || port is! int) {
        return null;
      }
      final avatar = m['avatar'];
      return DiscoveryPayload(
        id: id,
        name: name,
        ip: ip,
        tcpPort: port,
        isReply: m['reply'] == true,
        avatar: avatar is String ? avatar : '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 发现层：UDP 组播广播 + 应答
class DiscoveryService {
  static const String multicastGroup = '239.255.42.99';
  static const int multicastPort = 45678;
  static const Duration announceInterval = Duration(seconds: 3);
  static const Duration offlineAfter = Duration(seconds: 10);

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  bool _running = false;

  final String selfId;
  final String Function() selfName;
  final int Function() selfTcpPort;
  final String Function() selfIp;
  final List<String> Function() selfIps;
  final String Function() selfAvatarB64;

  /// 收到其他设备的广播/应答时回调（已过滤自己）
  final void Function(DiscoveryPayload payload, String fromIp) onPeer;

  DiscoveryService({
    required this.selfId,
    required this.selfName,
    required this.selfTcpPort,
    required this.selfIp,
    required this.selfIps,
    required this.selfAvatarB64,
    required this.onPeer,
  });

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      multicastPort,
      reuseAddress: true,
    );
    _socket!.broadcastEnabled = true;
    _socket!.joinMulticast(InternetAddress(multicastGroup));
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null) return;
      final payload = DiscoveryPayload.decode(utf8.decode(dg.data));
      if (payload == null) return;
      if (payload.id == selfId) return;
      final fromIp = dg.address.address;
      // 收到广播/探测时单播回应答（应答不再回，避免风暴）
      if (!payload.isReply) {
        _replyTo(fromIp);
      }
      onPeer(payload, fromIp);
    });
    _running = true;
    _announce();
    _announceTimer = Timer.periodic(announceInterval, (_) => _announce());
  }

  void _announce() {
    // 组播一次（从默认路由接口出去）
    final data = utf8.encode(DiscoveryPayload(
      id: selfId,
      name: selfName(),
      ip: selfIp(),
      tcpPort: selfTcpPort(),
      avatar: selfAvatarB64(),
    ).encode());
    try {
      _socket?.send(data, InternetAddress(multicastGroup), multicastPort);
    } catch (_) {}
    // 子网广播兜底：对每个本机网段都发一次（多网卡场景关键！）
    // 部分路由器/热点屏蔽组播但放行广播
    for (final myIp in selfIps()) {
      final parts = myIp.split('.');
      if (parts.length != 4) continue;
      // payload 里的 ip 用该网段的本机地址，对方拿到即可达
      final d = myIp == selfIp()
          ? data
          : utf8.encode(DiscoveryPayload(
              id: selfId,
              name: selfName(),
              ip: myIp,
              tcpPort: selfTcpPort(),
              avatar: selfAvatarB64(),
            ).encode());
      try {
        _socket?.send(d,
            InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'),
            multicastPort);
      } catch (_) {}
    }
  }

  void _replyTo(String ip) {
    final p = DiscoveryPayload(
      id: selfId,
      name: selfName(),
      ip: selfIp(),
      tcpPort: selfTcpPort(),
      isReply: true,
      avatar: selfAvatarB64(),
    );
    try {
      _socket?.send(utf8.encode(p.encode()), InternetAddress(ip), multicastPort);
    } catch (_) {}
  }

  /// 手动刷新：立即广播一次 + 所有本机网段内逐 IP 单播探测（组播被路由器/热点屏蔽时的兜底）
  Future<void> refresh() async {
    _announce();
    final ips = selfIps().isEmpty ? [selfIp()] : selfIps();
    for (final ip in ips) {
      if (ip.isEmpty) continue;
      final parts = ip.split('.');
      if (parts.length != 4) continue;
      final base = '${parts[0]}.${parts[1]}.${parts[2]}';
      final data = utf8.encode(DiscoveryPayload(
        id: selfId,
        name: selfName(),
        ip: ip,
        tcpPort: selfTcpPort(),
        avatar: selfAvatarB64(),
      ).encode());
      for (var i = 1; i <= 254; i++) {
        try {
          _socket?.send(data, InternetAddress('$base.$i'), multicastPort);
        } catch (_) {}
        // 分批让出事件循环，避免 254 次同步发送卡住 UI
        if ((i & 15) == 0) await Future<void>.delayed(Duration.zero);
      }
    }
  }

  void stop() {
    _announceTimer?.cancel();
    _announceTimer = null;
    _socket?.close();
    _socket = null;
    _running = false;
  }
}
