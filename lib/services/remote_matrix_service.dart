// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'remote_message_adapter.dart';
import 'notification_service.dart';
import 'server_profile.dart';

class RemoteServerException implements Exception {
  RemoteServerException(this.message);

  final String message;

  @override
  String toString() => 'RemoteServerException: $message';
}

class RemoteServerCapabilities {
  const RemoteServerCapabilities({
    required this.serverName,
    required this.encryptionMode,
    required this.maxImageBytes,
    required this.retentionDays,
  });

  final String serverName;
  final String encryptionMode;
  final int maxImageBytes;
  final int retentionDays;

  bool get e2ee => encryptionMode == 'e2ee';

  factory RemoteServerCapabilities.fromMap(Object? value) {
    final data = value is Map ? value : const <Object?, Object?>{};
    final rawName = data['serverName'];
    final name = rawName is String ? rawName.trim() : '';
    return RemoteServerCapabilities(
      serverName: name.isEmpty
          ? 'LanChat Server'
          : name.substring(0, name.length.clamp(0, 128)),
      encryptionMode: data['encryptionMode'] == 'readable'
          ? 'readable'
          : 'e2ee',
      maxImageBytes: _boundedInt(
        data['maxImageBytes'],
        RemoteServerLimits.maxImageBytes,
        1,
        RemoteServerLimits.maxImageBytes,
      ),
      retentionDays: _boundedInt(data['retentionDays'], 30, 1, 365),
    );
  }

  static int _boundedInt(Object? value, int fallback, int min, int max) {
    if (value is! int) return fallback;
    return value.clamp(min, max).toInt();
  }
}

class RemoteServerLimits {
  static const maxImageBytes = 20 * 1024 * 1024;
  static const maxTextBytes = 60 * 1024;

  static void validateText(String text) {
    if (utf8.encode(text).length > maxTextBytes) {
      throw RemoteServerException('远程文字不能超过 60 KB。');
    }
  }

  static void validateImageSize(int size) {
    if (size <= 0 || size > maxImageBytes) {
      throw RemoteServerException('远程图片不能超过 20 MB。');
    }
  }
}

class RemoteUser {
  const RemoteUser({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.isOnline = false,
    this.lastSeen,
  });

  final String userId;
  final String username;
  final String displayName;
  final Uri? avatarUrl;
  final bool isOnline;
  final DateTime? lastSeen;
}

class RemoteFriendRequest {
  const RemoteFriendRequest({
    required this.roomId,
    required this.userId,
    required this.displayName,
  });

  final String roomId;
  final String userId;
  final String displayName;
}

class RemoteMatrixService extends ChangeNotifier {
  RemoteMatrixService({
    http.Client? httpClient,
    LocalNotificationService? notificationService,
  }) : _httpClient = httpClient ?? http.Client(),
       _notificationService = notificationService;

  static const _clientPrefix = 'lanchat_matrix_';
  final http.Client _httpClient;
  final LocalNotificationService? _notificationService;
  final _messages = StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get onMessage => _messages.stream;

  Client? _client;
  MatrixSdkDatabase? _database;
  StreamSubscription<Event>? _timelineSubscription;
  ServerProfile? _profile;
  RemoteServerCapabilities? _capabilities;
  bool _busy = false;
  bool _e2eeEnabled = true;

  ServerProfile? get profile => _profile;
  Client? get client => _client;
  bool get isConnected => _client?.isLogged() == true;
  bool get isBusy => _busy;
  bool get e2eeEnabled => _e2eeEnabled;
  RemoteServerCapabilities? get capabilities => _capabilities;

  List<Room> get rooms => List.unmodifiable(
    _client?.rooms
            .where(
              (room) =>
                  room.membership == Membership.join ||
                  room.membership == Membership.invite,
            )
            .toList() ??
        const <Room>[],
  );

  List<RemoteFriendRequest> get incomingFriendRequests {
    final current = _client;
    if (current == null) return const [];
    final requests = <RemoteFriendRequest>[];
    for (final room in rooms.where(
      (room) => room.membership == Membership.invite,
    )) {
      final participants = room.getParticipants();
      final other = participants
          .where((user) => user.id != current.userID)
          .firstOrNull;
      if (other != null) {
        requests.add(
          RemoteFriendRequest(
            roomId: room.id,
            userId: other.id,
            displayName: other.displayName ?? other.id.localpart ?? other.id,
          ),
        );
      }
    }
    return requests;
  }

  Room? directRoomForUser(String userId) {
    final client = _client;
    if (client == null) return null;
    final roomId = client.getDirectChatFromUserId(userId);
    if (roomId == null) return null;
    final room = client.getRoomById(roomId);
    if (room?.membership != Membership.join) return null;
    final other = room!
        .getParticipants()
        .where((user) => user.id == userId)
        .firstOrNull;
    return other?.membership == Membership.join ? room : null;
  }

  bool isFriend(String userId) => directRoomForUser(userId) != null;

  Future<void> connect(
    ServerProfile profile, {
    required String password,
    required String accessCode,
    bool e2ee = true,
  }) async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await disconnect();
      final capabilities = await _verifyAccessCode(profile, accessCode);
      final directory = await getApplicationSupportDirectory();
      final sqlite = await sqflite.openDatabase(
        p.join(directory.path, '$_clientPrefix${profile.id}.db'),
      );
      _database = await MatrixSdkDatabase.init(
        '$_clientPrefix${profile.id}',
        database: sqlite,
        sqfliteFactory: sqflite.databaseFactory,
      );
      final client = Client(
        'LanChat ${profile.id}',
        database: _database!,
        verificationMethods: const {KeyVerificationMethod.numbers},
      );
      await client.init();
      if (!client.isLogged()) {
        await client.checkHomeserver(profile.uri);
        await client.login(
          AuthenticationTypes.password,
          identifier: AuthenticationUserIdentifier(user: profile.username),
          password: password,
          initialDeviceDisplayName: 'LanChat',
        );
      }
      if (capabilities.e2ee && !client.encryptionEnabled) {
        throw RemoteServerException('服务器端到端加密初始化失败。');
      }
      _e2eeEnabled = capabilities.e2ee;
      _profile = profile;
      _capabilities = capabilities;
      _client = client;
      _timelineSubscription = client.onTimelineEvent.stream.listen(
        _onTimelineEvent,
      );
      notifyListeners();
    } catch (error) {
      await disconnect();
      if (error is RemoteServerException) rethrow;
      throw RemoteServerException('服务器连接失败：$error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await _timelineSubscription?.cancel();
    _timelineSubscription = null;
    final client = _client;
    _client = null;
    _profile = null;
    _capabilities = null;
    if (client != null) await client.dispose();
    _database = null;
  }

  Future<List<RemoteUser>> searchUsers(String query) async {
    final client = _requireClient();
    final term = query.trim();
    final response = await client.searchUserDirectory(term, limit: 100);
    final users = <RemoteUser>[];
    for (final profile in response.results) {
      if (profile.userId == client.userID) continue;
      DateTime? lastSeen;
      var online = false;
      try {
        final presence = await client.fetchCurrentPresence(profile.userId);
        online = presence.presence == PresenceType.online;
        lastSeen = presence.lastActiveTimestamp;
      } catch (_) {}
      users.add(
        RemoteUser(
          userId: profile.userId,
          username: profile.userId.localpart ?? profile.userId,
          displayName:
              profile.displayName ?? profile.userId.localpart ?? profile.userId,
          avatarUrl: profile.avatarUrl,
          isOnline: online,
          lastSeen: lastSeen,
        ),
      );
    }
    return users;
  }

  Future<String> sendFriendRequest(RemoteUser user) async {
    final client = _requireClient();
    return client.startDirectChat(user.userId, enableEncryption: _e2eeEnabled);
  }

  Future<void> acceptFriendRequest(String roomId) async {
    final room = _requireRoom(roomId);
    await room.join();
    notifyListeners();
  }

  Future<void> rejectFriendRequest(String roomId) async {
    final room = _requireRoom(roomId);
    await room.leave();
    notifyListeners();
  }

  Future<void> blockUser(String userId) async {
    await _requireClient().ignoreUser(userId);
    notifyListeners();
  }

  Future<void> sendText(String roomId, String text) async {
    RemoteServerLimits.validateText(text);
    final client = _requireClient();
    final room = _requireRoom(roomId);
    await room.sendTextEvent(
      text,
      parseCommands: false,
      txid: client.generateUniqueTransactionId(),
    );
  }

  Future<void> sendImage(String roomId, String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    RemoteServerLimits.validateImageSize(bytes.length);
    final serverMaxImageBytes = _capabilities?.maxImageBytes;
    if (serverMaxImageBytes != null && bytes.length > serverMaxImageBytes) {
      throw RemoteServerException('当前服务器的图片上限更低。');
    }
    final name = p.basename(path);
    final client = _requireClient();
    final room = _requireRoom(roomId);
    await room.sendFileEvent(
      MatrixImageFile(bytes: bytes, name: name),
      txid: client.generateUniqueTransactionId(),
    );
  }

  Future<List<RemoteMessage>> messagesForRoom(
    String roomId, {
    int limit = 100,
  }) async {
    final client = _requireClient();
    final timeline = await _requireRoom(roomId).getTimeline(limit: limit);
    return timeline.events
        .map(
          (event) =>
              RemoteMessageAdapter.fromEvent(event, ownUserId: client.userID),
        )
        .whereType<RemoteMessage>()
        .toList()
        .reversed
        .toList();
  }

  Future<Uint8List> downloadImage(RemoteMessage message) async {
    final event = message.event;
    if (event == null || !message.isImage) {
      throw RemoteServerException('远程图片事件不可用。');
    }
    final file = await event.downloadAndDecryptAttachment();
    RemoteServerLimits.validateImageSize(file.bytes.length);
    final serverMaxImageBytes = _capabilities?.maxImageBytes;
    if (serverMaxImageBytes != null &&
        file.bytes.length > serverMaxImageBytes) {
      throw RemoteServerException('远程图片超过当前服务器限制。');
    }
    return file.bytes;
  }

  Future<RemoteServerCapabilities> _verifyAccessCode(
    ServerProfile profile,
    String accessCode,
  ) async {
    if (accessCode.isEmpty) {
      throw RemoteServerException('服务器接入码不能为空。');
    }
    final uri = profile.uri.resolve('_lanchat/v1/access/verify');
    final response = await _httpClient
        .post(
          uri,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'accessCode': accessCode}),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw RemoteServerException('服务器接入码无效。');
    }
    try {
      return RemoteServerCapabilities.fromMap(jsonDecode(response.body));
    } catch (_) {
      throw RemoteServerException('服务器能力信息无效。');
    }
  }

  void _onTimelineEvent(Event event) {
    final message = RemoteMessageAdapter.fromEvent(
      event,
      ownUserId: _client?.userID,
    );
    if (message == null || message.isMine) return;
    _messages.add(message);
    final notifications = _notificationService;
    if (notifications != null) {
      unawaited(
        notifications.showMessage(
          message.senderId.localpart ?? message.senderId,
        ),
      );
    }
    notifyListeners();
  }

  Client _requireClient() {
    final client = _client;
    if (client == null || !client.isLogged()) {
      throw RemoteServerException('尚未连接服务器。');
    }
    return client;
  }

  Room _requireRoom(String roomId) {
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != Membership.join) {
      throw RemoteServerException('远程聊天不存在或尚未建立好友关系。');
    }
    final pendingMember = room
        .getParticipants()
        .where((user) => user.id != client.userID)
        .where((user) => user.membership != Membership.join)
        .firstOrNull;
    if (pendingMember != null) {
      throw RemoteServerException('对方尚未接受好友申请。');
    }
    return room;
  }

  @override
  void dispose() {
    unawaited(disconnect());
    _messages.close();
    super.dispose();
  }
}
