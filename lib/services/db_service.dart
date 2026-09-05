import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class Device {
  final String id;
  String name;
  String ip;
  int port;
  String? avatarPath;
  DateTime lastSeen;
  bool isManual;
  bool isPaired;

  Device({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.avatarPath,
    required this.lastSeen,
    this.isManual = false,
    this.isPaired = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'ip': ip,
    'port': port,
    'avatarPath': avatarPath,
    'lastSeen': lastSeen.millisecondsSinceEpoch,
    'isManual': isManual ? 1 : 0,
    'isPaired': isPaired ? 1 : 0,
  };

  static Device fromMap(Map m) => Device(
    id: m['id'] as String,
    name: m['name'] as String,
    ip: m['ip'] as String,
    port: m['port'] as int,
    avatarPath: m['avatarPath'] as String?,
    lastSeen: DateTime.fromMillisecondsSinceEpoch(m['lastSeen'] as int),
    isManual: (m['isManual'] as int) == 1,
    isPaired: (m['isPaired'] as int? ?? 0) == 1,
  );
}

class Message {
  final String id;
  final String deviceId;
  final int direction; // 0 收 1 发
  final String type; // text/file/image
  String content; // 文本内容或文件名
  String? filePath;
  int? fileSize;
  String? transferId;
  int status; // 0 发送中 1 已送达 2 失败
  final DateTime createdAt;

  Message({
    required this.id,
    required this.deviceId,
    required this.direction,
    required this.type,
    required this.content,
    this.filePath,
    this.fileSize,
    this.transferId,
    this.status = 0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'deviceId': deviceId,
    'direction': direction,
    'type': type,
    'content': content,
    'filePath': filePath,
    'fileSize': fileSize,
    'transferId': transferId,
    'status': status,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  static Message fromMap(Map m) => Message(
    id: m['id'] as String,
    deviceId: m['deviceId'] as String,
    direction: m['direction'] as int,
    type: m['type'] as String,
    content: m['content'] as String,
    filePath: m['filePath'] as String?,
    fileSize: m['fileSize'] as int?,
    transferId: m['transferId'] as String?,
    status: m['status'] as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int),
  );
}

class TransferRecord {
  TransferRecord({
    required this.id,
    required this.deviceId,
    required this.messageId,
    required this.direction,
    required this.type,
    required this.fileName,
    required this.filePath,
    required this.totalBytes,
    required this.offsetBytes,
    required this.digest,
    required this.status,
    required this.updatedAt,
  });

  final String id;
  final String deviceId;
  final String? messageId;
  final int direction;
  final String type;
  final String fileName;
  final String filePath;
  final int totalBytes;
  final int offsetBytes;
  final String? digest;
  final String status;
  final DateTime updatedAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'deviceId': deviceId,
    'messageId': messageId,
    'direction': direction,
    'type': type,
    'fileName': fileName,
    'filePath': filePath,
    'totalBytes': totalBytes,
    'offsetBytes': offsetBytes,
    'digest': digest,
    'status': status,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static TransferRecord fromMap(Map m) => TransferRecord(
    id: m['id'] as String,
    deviceId: m['deviceId'] as String,
    messageId: m['messageId'] as String?,
    direction: m['direction'] as int,
    type: m['type'] as String,
    fileName: m['fileName'] as String,
    filePath: m['filePath'] as String,
    totalBytes: m['totalBytes'] as int,
    offsetBytes: m['offsetBytes'] as int,
    digest: m['digest'] as String?,
    status: m['status'] as String,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updatedAt'] as int),
  );
}

class DbService {
  Database? _db;
  bool didResetLegacyData = false;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final String path;
    if (Platform.isWindows || Platform.isLinux) {
      final dir = await getApplicationSupportDirectory();
      path = p.join(dir.path, 'lanchat.db');
    } else {
      path = p.join(await getDatabasesPath(), 'lanchat.db');
    }
    return openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int v) async {
    await _createSchema(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.transaction((txn) async {
        await txn.execute('DROP TABLE IF EXISTS messages');
        await txn.execute('DROP TABLE IF EXISTS devices');
        await txn.execute('DROP TABLE IF EXISTS transfers');
        await txn.execute('DROP TABLE IF EXISTS stickers');
        await _createSchema(txn);
      });
      didResetLegacyData = true;
    }
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE devices(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        ip TEXT NOT NULL,
        port INTEGER NOT NULL,
        avatarPath TEXT,
        lastSeen INTEGER NOT NULL,
        isManual INTEGER NOT NULL DEFAULT 0,
        isPaired INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE messages(
        id TEXT PRIMARY KEY,
        deviceId TEXT NOT NULL,
        direction INTEGER NOT NULL,
        type TEXT NOT NULL,
        content TEXT NOT NULL,
        filePath TEXT,
        fileSize INTEGER,
        transferId TEXT,
        status INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_messages_device ON messages(deviceId, createdAt)',
    );
    await db.execute('''
      CREATE TABLE transfers(
        id TEXT PRIMARY KEY,
        deviceId TEXT NOT NULL,
        messageId TEXT,
        direction INTEGER NOT NULL,
        type TEXT NOT NULL,
        fileName TEXT NOT NULL,
        filePath TEXT NOT NULL,
        totalBytes INTEGER NOT NULL,
        offsetBytes INTEGER NOT NULL DEFAULT 0,
        digest TEXT,
        status TEXT NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE stickers(
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        favorite INTEGER NOT NULL DEFAULT 0,
        lastUsedAt INTEGER
      )
    ''');
  }

  // ---- devices ----
  Future<void> upsertDevice(Device d) async {
    final database = await db;
    await database.insert(
      'devices',
      d.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Device>> getAllDevices() async {
    final database = await db;
    final rows = await database.query('devices');
    return rows.map(Device.fromMap).toList();
  }

  Future<Device?> getDevice(String id) async {
    final database = await db;
    final rows = await database.query(
      'devices',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return Device.fromMap(rows.first);
  }

  Future<void> deleteDevice(String id) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('devices', where: 'id = ?', whereArgs: [id]);
      await txn.delete('messages', where: 'deviceId = ?', whereArgs: [id]);
      await txn.delete('transfers', where: 'deviceId = ?', whereArgs: [id]);
    });
  }

  /// 把旧设备 id 的消息迁到新 id，并删除旧设备行（用于同 IP 合并）
  Future<void> mergeDeviceId(String oldId, String newId) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.update(
        'messages',
        {'deviceId': newId},
        where: 'deviceId = ?',
        whereArgs: [oldId],
      );
      await txn.update(
        'transfers',
        {'deviceId': newId},
        where: 'deviceId = ?',
        whereArgs: [oldId],
      );
      await txn.delete('devices', where: 'id = ?', whereArgs: [oldId]);
    });
  }

  Future<void> deleteMessage(String id) async {
    final database = await db;
    await database.delete('messages', where: 'id = ?', whereArgs: [id]);
    await database.delete('transfers', where: 'messageId = ?', whereArgs: [id]);
  }

  Future<void> deleteMessagesForDevice(String deviceId) async {
    final database = await db;
    await database.delete(
      'messages',
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
    await database.delete(
      'transfers',
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
  }

  Future<void> upsertTransfer(TransferRecord transfer) async {
    final database = await db;
    await database.insert(
      'transfers',
      transfer.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<TransferRecord?> getTransfer(String id) async {
    final database = await db;
    final rows = await database.query(
      'transfers',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return TransferRecord.fromMap(rows.first);
  }

  Future<List<TransferRecord>> getTransfers() async {
    final database = await db;
    final rows = await database.query('transfers', orderBy: 'updatedAt DESC');
    return rows.map(TransferRecord.fromMap).toList();
  }

  Future<void> deleteTransfer(String id) async {
    final database = await db;
    await database.delete('transfers', where: 'id = ?', whereArgs: [id]);
  }

  // ---- messages ----
  Future<void> insertMessage(Message m) async {
    final database = await db;
    await database.insert(
      'messages',
      m.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateMessage(Message m) async {
    final database = await db;
    await database.update(
      'messages',
      m.toMap(),
      where: 'id = ?',
      whereArgs: [m.id],
    );
  }

  Future<bool> messageExists(String id) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<Message>> getMessages(String deviceId, {int limit = 500}) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      where: 'deviceId = ?',
      whereArgs: [deviceId],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.map(Message.fromMap).toList().reversed.toList();
  }

  /// 每个设备最近一条消息
  Future<Map<String, Message>> latestMessagePerDevice() async {
    final database = await db;
    final rows = await database.rawQuery('''
      SELECT m.* FROM messages m
      JOIN (SELECT deviceId, MAX(createdAt) mc FROM messages GROUP BY deviceId) t
      ON m.deviceId = t.deviceId AND m.createdAt = t.mc
    ''');
    final map = <String, Message>{};
    for (final r in rows) {
      final m = Message.fromMap(r);
      map[m.deviceId] = m;
    }
    return map;
  }

  Future<Message?> latestMessageForDevice(String deviceId) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      where: 'deviceId = ?',
      whereArgs: [deviceId],
      orderBy: 'createdAt DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Message.fromMap(rows.first);
  }

  Future<void> clearAllMessages() async {
    final database = await db;
    await database.delete('messages');
    await database.delete('transfers');
  }

  /// 导出所有记录为 JSON 字符串
  Future<String> exportJson() async {
    final database = await db;
    final msgs = await database.query('messages', orderBy: 'createdAt');
    final devs = await database.query('devices');
    return const JsonEncoder.withIndent('  ').convert({
      'exportedAt': DateTime.now().toIso8601String(),
      'devices': devs,
      'messages': msgs,
    });
  }

  /// 导出为可读文本
  Future<String> exportText() async {
    final database = await db;
    final devs = await database.query('devices');
    final nameOf = <String, String>{};
    for (final d in devs) {
      nameOf[d['id'] as String] = d['name'] as String;
    }
    final msgs = await database.query('messages', orderBy: 'createdAt');
    final buf = StringBuffer();
    for (final m in msgs) {
      final dt = DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int);
      final who = (m['direction'] as int) == 1
          ? '我'
          : (nameOf[m['deviceId']] ?? '对方');
      final type = m['type'] as String;
      String body;
      if (type == 'text') {
        body = m['content'] as String;
      } else {
        body = '[${type == 'image' ? '图片' : '文件'}] ${m['content']}';
      }
      buf.writeln('${dt.toString().substring(0, 19)} $who: $body');
    }
    return buf.toString();
  }
}
