import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/discovery_service.dart';
import 'package:lanchat/services/transport_service.dart';

void main() {
  test('MessageHeader 编解码 roundtrip', () {
    final h = MessageHeader(
      type: FrameType.text,
      msgId: 'abc',
      ts: 123,
    );
    final map = h.toMap();
    final h2 = MessageHeader.fromMap(map);
    expect(h2!.type, FrameType.text);
    expect(h2.msgId, 'abc');
    expect(h2.ts, 123);
  });

  test('MessageHeader file 字段', () {
    final h = MessageHeader(
      type: FrameType.file,
      msgId: 'f1',
      ts: 1,
      fileId: 'fid',
      fileName: 'a.zip',
      size: 1024,
      mime: 'application/zip',
    );
    final h2 = MessageHeader.fromMap(h.toMap());
    expect(h2!.fileName, 'a.zip');
    expect(h2.size, 1024);
    expect(h2.mime, 'application/zip');
  });

  test('非法 JSON 返回 null', () {
    expect(MessageHeader.fromMap({'type': 'nope'}), isNull);
  });

  test('FrameCodec 文本帧编码', () {
    final h = MessageHeader(type: FrameType.text, msgId: 'x', ts: 1);
    final bytes = FrameCodec.encodeText(h, '你好');
    final headLen =
        ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
    expect(headLen, greaterThan(0));
    final headJson = utf8.decode(bytes.sublist(4, 4 + headLen));
    expect(headJson, contains('"msgId":"x"'));
    expect(headJson, contains('"size":6')); // '你好' = 6 字节 UTF-8
    final body = utf8.decode(bytes.sublist(4 + headLen));
    expect(body, '你好');
  });

  test('encodeText 保留 fromPort/fromName/fromId（接收方回连+多重校验依赖）', () {
    final h = MessageHeader(
      type: FrameType.text,
      msgId: 'x',
      ts: 1,
      fromPort: 45679,
      fromName: 'Alice',
      fromId: 'uuid-1234',
    );
    final bytes = FrameCodec.encodeText(h, 'hi');
    final headLen =
        ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
    final h2 = MessageHeader.fromMap(
        jsonDecode(utf8.decode(bytes.sublist(4, 4 + headLen)))
            as Map<dynamic, dynamic>);
    expect(h2!.fromPort, 45679);
    expect(h2.fromName, 'Alice');
    expect(h2.fromId, 'uuid-1234');
  });

  test('DiscoveryPayload avatar roundtrip', () {
    final p = DiscoveryPayload(
      id: 'id1',
      name: 'Alice',
      ip: '192.168.1.2',
      tcpPort: 45679,
      avatar: 'aGVsbG8=',
    );
    final d = DiscoveryPayload.decode(p.encode());
    expect(d, isNotNull);
    expect(d!.avatar, 'aGVsbG8=');
    expect(d.id, 'id1');
    // 无 avatar 字段时解析为空串
    final p2 =
        DiscoveryPayload(id: 'id2', name: 'B', ip: '1.2.3.4', tcpPort: 1);
    expect(DiscoveryPayload.decode(p2.encode())!.avatar, '');
  });

  test('FrameReader 文件帧流式落盘 + 同连接文本帧', () async {
    final dir = await Directory.systemTemp.createTemp('lanchat');
    final path = '${dir.path}/recv.bin';
    final ctrl = StreamController<Uint8List>();
    final frames = <String>[];
    MessageHeader? fileHeader;
    int? fileBytes;
    var aborted = false;
    FrameReader(ctrl.stream,
        onFrame: (h, p) => frames.add('${h.msgId}:${utf8.decode(p)}'),
        openFileSink: (h) async => FrameFileSink(File(path).openWrite(), path),
        onFileDone: (h, p, n) async {
          fileHeader = h;
          fileBytes = n;
        },
        onAbort: () => aborted = true).listen();

    // 文件帧（分片喂入，模拟跨 TCP 分段）
    final payload = Uint8List.fromList(List.generate(8192, (i) => i & 0xff));
    final fh = MessageHeader(
        type: FrameType.file,
        msgId: 'f1',
        ts: 1,
        size: payload.length,
        fileName: 'a.bin');
    final fbytes = FrameCodec.encodeHeaderOnly(fh);
    ctrl.add(fbytes.sublist(0, 7));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ctrl.add(fbytes.sublist(7));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ctrl.add(payload.sublist(0, 5000));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ctrl.add(payload.sublist(5000));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 同连接再跟一帧文本，验证状态机复位
    ctrl.add(FrameCodec.encodeText(
        MessageHeader(type: FrameType.text, msgId: 't1', ts: 2), 'hello'));
    await ctrl.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(fileHeader?.msgId, 'f1');
    expect(fileBytes, 8192);
    expect(File(path).lengthSync(), 8192);
    expect(frames, ['t1:hello']);
    expect(aborted, false);
  });

  test('FrameReader 非法帧头长度时中止连接', () async {
    final ctrl = StreamController<Uint8List>();
    var aborted = false;
    FrameReader(ctrl.stream,
        onFrame: (h, p) {},
        onAbort: () => aborted = true).listen();
    ctrl.add(Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 1, 2]));
    await ctrl.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(aborted, true);
  });
}
