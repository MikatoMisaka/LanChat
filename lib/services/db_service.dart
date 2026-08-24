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

  Device({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.avatarPath,
    required this.lastSeen,
    this.isManual = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'ip': ip,
        'port': port,
        'avatarPath': avatarPath,
        'lastSeen': lastSeen.millisecondsSinceEpoch,
        'isManual': isManual ? 1 : 0,
      };

  static Device fromMap(Map m) => Device(
        id: m['id'] as String,
        name: m['name'] as String,
        ip: m['ip'] as String,
        port: m['port'] as int,
        avatarPath: m['avatarPath'] as String?,
        lastSeen:
            DateTime.fromMillisecondsSinceEpoch(m['lastSeen'] as int),
        isManual: (m['isManual'] as int) == 1,
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
        status: m['status'] as int,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int),
      );
}

class DbService {
  Database? _db;

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
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int v) async {
    await db.execute('''
      CREATE TABLE devices(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        ip TEXT NOT NULL,
        port INTEGER NOT NULL,
        avatarPath TEXT,
        lastSeen INTEGER NOT NULL,
        isManual INTEGER NOT NULL DEFAULT 0
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
        status INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_messages_device ON messages(deviceId, createdAt)');
  }

  // ---- devices ----
  Future<void> upsertDevice(Device d) async {
    final database = await db;
    await database.insert('devices', d.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Device>> getAllDevices() async {
    final database = await db;
    final rows = await database.query('devices');
    return rows.map(Device.fromMap).toList();
  }

  Future<Device?> getDevice(String id) async {
    final database = await db;
    final rows =
        await database.query('devices', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Device.fromMap(rows.first);
  }

  Future<void> deleteDevice(String id) async {
    final database = await db;
    await database.delete('devices', where: 'id = ?', whereArgs: [id]);
    await database.delete('messages', where: 'deviceId = ?', whereArgs: [id]);
  }

  /// 把旧设备 id 的消息迁到新 id，并删除旧设备行（用于同 IP 合并）
  Future<void> mergeDeviceId(String oldId, String newId) async {
    final database = await db;
    await database.update('messages', {'deviceId': newId},
        where: 'deviceId = ?', whereArgs: [oldId]);
    await database.delete('devices', where: 'id = ?', whereArgs: [oldId]);
  }

  Future<void> deleteMessage(String id) async {
    final database = await db;
    await database.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMessagesForDevice(String deviceId) async {
    final database = await db;
    await database.delete('messages', where: 'deviceId = ?', whereArgs: [deviceId]);
  }

  // ---- messages ----
  Future<void> insertMessage(Message m) async {
    final database = await db;
    await database.insert('messages', m.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateMessage(Message m) async {
    final database = await db;
    await database
        .update('messages', m.toMap(), where: 'id = ?', whereArgs: [m.id]);
  }

  Future<List<Message>> getMessages(String deviceId,
      {int limit = 500}) async {
    final database = await db;
    final rows = await database.query('messages',
        where: 'deviceId = ?',
        whereArgs: [deviceId],
        orderBy: 'createdAt DESC',
        limit: limit);
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
    final rows = await database.query('messages',
        where: 'deviceId = ?',
        whereArgs: [deviceId],
        orderBy: 'createdAt DESC',
        limit: 1);
    if (rows.isEmpty) return null;
    return Message.fromMap(rows.first);
  }

  Future<void> clearAllMessages() async {
    final database = await db;
    await database.delete('messages');
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
      final who = (m['direction'] as int) == 1 ? '我' : (nameOf[m['deviceId']] ?? '对方');
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
