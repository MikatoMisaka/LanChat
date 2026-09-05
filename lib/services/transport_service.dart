import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// TCP 外层帧类型
enum FrameType { text, file, image, receipt, control, secure }

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
      case 'control':
        ft = FrameType.control;
      case 'secure':
        ft = FrameType.secure;
    }
    if (ft == null) return null;
    final msgId = m['msgId'];
    final ts = m['ts'];
    if (msgId is! String || ts is! int) return null;
    return MessageHeader(
      type: ft,
      msgId: msgId,
      ts: ts,
      fileId: _stringOrNull(m['fileId']),
      fileName: _stringOrNull(m['fileName']),
      size: _intOrNull(m['size']),
      mime: _stringOrNull(m['mime']),
      forMsgId: _stringOrNull(m['for']),
      status: _stringOrNull(m['status']),
      fromPort: _intOrNull(m['fromPort']),
      fromName: _stringOrNull(m['fromName']),
      fromId: _stringOrNull(m['fromId']),
    );
  }

  Uint8List encode() => utf8.encode(jsonEncode(toMap()));
}

String? _stringOrNull(Object? value) => value is String ? value : null;

int? _intOrNull(Object? value) => value is int ? value : null;

/// 帧编码：[4字节大端头长度][头JSON][payload]
class FrameCodec {
  static const maxHeaderBytes = 8 * 1024;

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
    return encodePayload(h, body);
  }

  static Uint8List encodeHeaderOnly(MessageHeader header) {
    return encodePayload(header, const <int>[]);
  }

  static Uint8List encodePayload(MessageHeader header, List<int> payload) {
    final head = header.encode();
    if (head.length > maxHeaderBytes) {
      throw ArgumentError.value(head.length, 'header', 'Header is too large');
    }
    final b = BytesBuilder();
    b.add(_lenBytes(head.length));
    b.add(head);
    b.add(payload);
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
  static const maxHeaderBytes = FrameCodec.maxHeaderBytes;
  static const maxFileBytes = 5 * 1024 * 1024 * 1024;
  static const maxBufferedBytes = 64 * 1024 + 64;
  static const maxSocketBufferBytes = 4 * 1024 * 1024;

  final Stream<Uint8List> source;
  final void Function() onAbort;

  final void Function(MessageHeader header, Uint8List payload) onFrame;
  final Future<FrameFileSink?> Function(MessageHeader header)? openFileSink;
  final Future<void> Function(
    MessageHeader header,
    String path,
    int bytesWritten,
  )?
  onFileDone;

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
    _sub = source.listen(
      _onData,
      onError: (_) => _onClosed(),
      onDone: _onClosed,
    );
  }

  Future<void> _onData(Uint8List data) async {
    if (_closed) return;
    _buf.addAll(data);
    if (_buf.length > maxSocketBufferBytes) {
      _protocolError();
      return;
    }
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
        if (headLen <= 0 || headLen > maxHeaderBytes) {
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
        final size = h.size;
        if (size == null || size < 0 || size > maxFileBytes) {
          _protocolError();
          return;
        }
        if (h.type != FrameType.file &&
            h.type != FrameType.image &&
            size > maxBufferedBytes) {
          _protocolError();
          return;
        }
        _header = h;
        _needed = size;
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
          if (handle == null && _needed > maxBufferedBytes) {
            _protocolError();
            return;
          }
          _sink = handle;
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
