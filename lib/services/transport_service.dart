import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

/// TCP 帧类型
enum FrameType { text, file, image, receipt }

class MessageHeader {
  final FrameType type;
  final String msgId;
  final int ts;
  final String? fileId;
  final String? fileName;
  final int? size;
  final String? mime;
  final String? forMsgId;
  final String? status;
  final int? fromPort;
  final String? fromName;
  final String? fromId;

  const MessageHeader({
    required this.type,
    required this.msgId,
    required this.ts,
    this.fileId,
    this.fileName,
    this.size,
    this.mime,
    this.forMsgId,
    this.status,
    this.fromPort,
    this.fromName,
    this.fromId,
  });

  Map<String, dynamic> toMap() => {
        'v': 1,
        'type': type.name,
        'msgId': msgId,
        'ts': ts,
        if (fileId != null) 'fileId': fileId,
        if (fileName != null) 'fileName': fileName,
        if (size != null) 'size': size,
        if (mime != null) 'mime': mime,
        if (forMsgId != null) 'for': forMsgId,
        if (status != null) 'status': status,
        if (fromPort != null) 'fromPort': fromPort,
        if (fromName != null) 'fromName': fromName,
        if (fromId != null) 'fromId': fromId,
      };

  static MessageHeader? fromMap(Map m) {
    final t = m['type'];
    if (t is! String) return null;
    FrameType? ft;
    switch (t) {
      case 'text':
        ft = FrameType.text;
      case 'file':
        ft = FrameType.file;
      case 'image':
        ft = FrameType.image;
      case 'receipt':
        ft = FrameType.receipt;
    }
    if (ft == null) return null;
    final msgId = m['msgId'];
    final ts = m['ts'];
    if (msgId is! String || ts is! int) return null;
    return MessageHeader(
      type: ft,
      msgId: msgId,
      ts: ts,
      fileId: m['fileId'] as String?,
      fileName: m['fileName'] as String?,
      size: m['size'] as int?,
      mime: m['mime'] as String?,
      forMsgId: m['for'] as String?,
      status: m['status'] as String?,
      fromPort: m['fromPort'] as int?,
      fromName: m['fromName'] as String?,
      fromId: m['fromId'] as String?,
    );
  }

  Uint8List encode() => utf8.encode(jsonEncode(toMap()));
}

/// 帧编码：[4字节大端头长度][头JSON][payload]
class FrameCodec {
  static Uint8List encodeText(MessageHeader header, String text) {
    final body = utf8.encode(text);
    final h = MessageHeader(
      type: header.type,
      msgId: header.msgId,
      ts: header.ts,
      size: body.length,
      fileId: header.fileId,
      fileName: header.fileName,
      mime: header.mime,
      forMsgId: header.forMsgId,
      status: header.status,
      fromPort: header.fromPort,
      fromName: header.fromName,
      fromId: header.fromId,
    );
    final head = h.encode();
    final b = BytesBuilder();
    b.add(_lenBytes(head.length));
    b.add(head);
    b.add(body);
    return b.toBytes();
  }

  static Uint8List encodeHeaderOnly(MessageHeader header) {
    final head = header.encode();
    final b = BytesBuilder();
    b.add(_lenBytes(head.length));
    b.add(head);
    return b.toBytes();
  }

  static Uint8List _lenBytes(int n) {
    final bd = ByteData(4)..setUint32(0, n);
    return bd.buffer.asUint8List();
  }
}

/// 文件帧流式写盘的句柄
class FrameFileSink {
  final IOSink sink;
  final String path;
  const FrameFileSink(this.sink, this.path);
}

/// 从 Socket 流中解析帧（状态机，O(n)，支持同连接多帧）。
/// 文件/图片帧在提供 [openFileSink] 时流式写盘，避免大文件撑爆内存；
/// 协议错误（非法头长度/头 JSON）直接通过 [onAbort] 断开本连接，避免数据堆积。
class FrameReader {
  final Stream<Uint8List> source;
  final void Function() onAbort;

  final void Function(MessageHeader header, Uint8List payload) onFrame;
  final Future<FrameFileSink?> Function(MessageHeader header)? openFileSink;
  final Future<void> Function(
      MessageHeader header, String path, int bytesWritten)? onFileDone;

  /// 文件接收进度（每写盘约 256KB 或完成时回调一次）
  final void Function(MessageHeader header, int received, int total)?
      onFileProgress;

  /// 文件接收中断（连接断开/写盘失败），不完整文件已删除
  final void Function(MessageHeader header)? onFileAbort;

  StreamSubscription<Uint8List>? _sub;
  MessageHeader? _header;
  int _needed = 0;
  int _got = 0;
  int _lastProgress = 0;
  FrameFileSink? _sink;
  final List<int> _buf = [];
  final BytesBuilder _payload = BytesBuilder(copy: false);
  bool _draining = false;
  bool _closed = false;

  FrameReader(
    this.source, {
    required this.onFrame,
    required this.onAbort,
    this.openFileSink,
    this.onFileDone,
    this.onFileProgress,
    this.onFileAbort,
  });

  void listen() {
    _sub = source.listen(_onData,
        onError: (_) => _onClosed(), onDone: _onClosed);
  }

  Future<void> _onData(Uint8List data) async {
    if (_closed) return;
    _buf.addAll(data);
    if (_draining) return; // 已有 drain 在跑，新数据已进 _buf，由其继续处理
    _draining = true;
    try {
      await _drain();
    } finally {
      _draining = false;
    }
  }

  void _onClosed() {
    if (_closed) return;
    _closed = true;
    final s = _sink;
    final h = _header;
    _sink = null;
    _header = null;
    if (s != null) {
      // 连接在文件传输中途断开：删掉不完整文件并通知上层
      _discardSink(s);
      if (h != null) onFileAbort?.call(h);
    }
  }

  void _protocolError() {
    if (_closed) return;
    _closed = true;
    final s = _sink;
    final h = _header;
    _sink = null;
    _header = null;
    _buf.clear();
    if (s != null) {
      _discardSink(s);
      if (h != null) onFileAbort?.call(h);
    }
    onAbort();
  }

  Future<void> _discardSink(FrameFileSink s) async {
    try {
      await s.sink.close();
    } catch (_) {}
    try {
      final f = File(s.path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _drain() async {
    while (true) {
      if (_header == null) {
        if (_buf.length < 4) return;
        final headLen =
            (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3];
        if (headLen <= 0 || headLen > 1 << 20) {
          _protocolError();
          return;
        }
        if (_buf.length < 4 + headLen) return;
        final headBytes = _buf.sublist(4, 4 + headLen);
        _buf.removeRange(0, 4 + headLen);
        MessageHeader? h;
        try {
          h = MessageHeader.fromMap(jsonDecode(utf8.decode(headBytes)));
        } catch (_) {
          h = null;
        }
        if (h == null) {
          _protocolError();
          return;
        }
        _header = h;
        _needed = h.size ?? 0;
        _got = 0;
        _lastProgress = 0;
        if ((h.type == FrameType.file || h.type == FrameType.image) &&
            openFileSink != null) {
          FrameFileSink? handle;
          try {
            _sub?.pause();
            handle = await openFileSink!(h);
          } catch (_) {
            handle = null;
          } finally {
            _sub?.resume();
          }
          _sink = handle; // null 则退回内存累积（兜底）
        }
        continue;
      }
      if (_got < _needed) {
        final want = _needed - _got;
        final n = want < _buf.length ? want : _buf.length;
        final chunk = _buf.sublist(0, n);
        _buf.removeRange(0, n);
        _got += n;
        final handle = _sink;
        if (handle != null) {
          handle.sink.add(chunk);
          try {
            _sub?.pause();
            await handle.sink.flush(); // 背压：暂停读 socket，等落盘
          } catch (_) {
            _protocolError();
            return;
          } finally {
            _sub?.resume();
          }
          if (_closed || _sink == null) return;
          // 每 ~256KB 或完成时上报一次接收进度
          if (_got - _lastProgress >= 256 * 1024 || _got >= _needed) {
            _lastProgress = _got;
            final hp = _header;
            if (hp != null && _needed > 0) {
              onFileProgress?.call(hp, _got, _needed);
            }
          }
          if (_got < _needed) return;
        } else {
          _payload.add(chunk);
          if (_got < _needed) return;
        }
      }
      // 帧完成
      final h = _header!;
      final bytesWritten = _got;
      final handle = _sink;
      _sink = null;
      _header = null;
      _needed = 0;
      _got = 0;
      if (handle != null) {
        try {
          _sub?.pause();
          await handle.sink.flush();
          await handle.sink.close();
        } catch (_) {
          _protocolError();
          return;
        } finally {
          _sub?.resume();
        }
        if (onFileDone != null) {
          try {
            await onFileDone!(h, handle.path, h.size ?? bytesWritten);
          } catch (_) {}
        }
      } else {
        onFrame(h, _payload.takeBytes());
      }
    }
  }
}

/// 传输层：TCP 服务端 + 客户端
class TransportService {
  /// 固定监听端口：手动添加 IP 后跨重启依然有效；被占用则回退系统随机端口
  static const int fixedPort = 45679;

  ServerSocket? _server;
  int? get port => _server?.port;
  int listenPort = 0;

  final String Function() selfName;
  final String Function() selfId;

  final void Function(
    String peerIp,
    MessageHeader header,
    Uint8List payload,
  ) onFrame;

  /// 文件/图片帧的流式接收：返回磁盘句柄则流式写盘，返回 null 则退回内存
  final Future<FrameFileSink?> Function(
      String peerIp, MessageHeader header)? openFileSink;

  /// 文件帧落盘完成（已 flush+close）
  final Future<void> Function(
      String peerIp, MessageHeader header, String path, int bytesWritten)?
      onFileDone;

  /// 文件接收进度（接收方聊天页显示进度条用）
  final void Function(
      String peerIp, MessageHeader header, int received, int total)?
      onFileProgress;

  /// 文件接收中断（连接断开/写盘失败）
  final void Function(String peerIp, MessageHeader header)? onFileAbort;

  final void Function(String peerIp) onDisconnect;

  TransportService({
    required this.selfName,
    required this.selfId,
    required this.onFrame,
    required this.onDisconnect,
    this.openFileSink,
    this.onFileDone,
    this.onFileProgress,
    this.onFileAbort,
  });

  Future<int> start() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, fixedPort);
    } on SocketException {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    listenPort = _server!.port;
    _server!.listen((socket) {
      final ip = socket.remoteAddress.address;
      FrameReader(socket,
          onFrame: (header, payload) => onFrame(ip, header, payload),
          openFileSink: openFileSink == null
              ? null
              : (header) => openFileSink!(ip, header),
          onFileDone: onFileDone == null
              ? null
              : (header, path, bytes) => onFileDone!(ip, header, path, bytes),
          onFileProgress: onFileProgress == null
              ? null
              : (header, received, total) =>
                  onFileProgress!(ip, header, received, total),
          onFileAbort:
              onFileAbort == null ? null : (header) => onFileAbort!(ip, header),
          onAbort: () {
        try {
          socket.destroy();
        } catch (_) {}
      }).listen();
      socket.done.then((_) => onDisconnect(ip));
    }, onError: (_) {});
    return listenPort;
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  /// 发送文本
  Future<void> sendText(String ip, int port, String text) async {
    final header = MessageHeader(
      type: FrameType.text,
      msgId: const Uuid().v4(),
      ts: DateTime.now().millisecondsSinceEpoch,
      fromPort: listenPort,
      fromName: selfName(),
      fromId: selfId(),
    );
    final socket = await Socket.connect(ip, port,
        timeout: const Duration(seconds: 5));
    try {
      socket.add(FrameCodec.encodeText(header, text));
      await socket.flush();
    } finally {
      await socket.close();
    }
  }

  /// 发送文件/图片流式传输，onProgress(0..1)
  Future<void> sendFile({
    required String ip,
    required int port,
    required String filePath,
    required String fileName,
    required bool isImage,
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    final size = await file.length();
    final fileId = const Uuid().v4();
    final header = MessageHeader(
      type: isImage ? FrameType.image : FrameType.file,
      msgId: const Uuid().v4(),
      ts: DateTime.now().millisecondsSinceEpoch,
      fileId: fileId,
      fileName: fileName,
      size: size,
      mime: _guessMime(fileName),
      fromPort: listenPort,
      fromName: selfName(),
      fromId: selfId(),
    );
    final socket = await Socket.connect(ip, port,
        timeout: const Duration(seconds: 5));
    try {
      socket.add(FrameCodec.encodeHeaderOnly(header));
      var sent = 0;
      var pending = 0;
      await for (final data in file.openRead()) {
        socket.add(data);
        sent += data.length;
        pending += data.length;
        // 每 256KB flush 一次再报进度：让进度条反映真实网络发送（而非内核缓冲）
        if (pending >= 256 * 1024) {
          await socket.flush();
          pending = 0;
          onProgress?.call(sent / size);
        }
      }
      await socket.flush();
      onProgress?.call(1.0);
    } finally {
      await socket.close();
    }
  }

  String _guessMime(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'pdf':
        return 'application/pdf';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }
}
