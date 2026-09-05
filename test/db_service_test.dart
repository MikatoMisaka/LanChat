import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/db_service.dart';

void main() {
  test('device mapping keeps the pairing state', () {
    final original = Device(
      id: 'peer-1',
      name: 'Peer',
      ip: '192.168.1.4',
      port: 45679,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(1),
      isPaired: false,
    );

    final restored = Device.fromMap(original.toMap());

    expect(restored.isPaired, isFalse);
    expect(restored.id, original.id);
  });

  test('message mapping keeps a resumable transfer id', () {
    final original = Message(
      id: 'message-1',
      deviceId: 'peer-1',
      direction: 1,
      type: 'file',
      content: 'payload.bin',
      filePath: 'payload.bin',
      fileSize: 10,
      transferId: 'transfer-1',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
    );

    final restored = Message.fromMap(original.toMap());

    expect(restored.transferId, 'transfer-1');
  });
}
