import 'package:matrix/matrix.dart';

class RemoteMessage {
  RemoteMessage({
    required this.id,
    required this.roomId,
    required this.senderId,
    required this.type,
    required this.body,
    required this.timestamp,
    required this.isMine,
    this.fileName,
    this.fileSize,
    this.attachmentMxc,
    this.event,
  });

  final String id;
  final String roomId;
  final String senderId;
  final String type;
  final String body;
  final DateTime timestamp;
  final bool isMine;
  final String? fileName;
  final int? fileSize;
  final String? attachmentMxc;
  final Event? event;

  bool get isImage => type == 'image';

  bool get isFile => type == 'file';
}

class RemoteMessageAdapter {
  static RemoteMessage? fromEvent(Event event, {required String? ownUserId}) {
    if (![EventTypes.Message, EventTypes.Sticker].contains(event.type)) {
      return null;
    }
    final msgType = event.content['msgtype'];
    final body = event.content['body'];
    if (msgType is! String || body is! String) return null;
    final isImage = msgType == MessageTypes.Image;
    final isText = msgType == MessageTypes.Text;
    final isFile = msgType == MessageTypes.File;
    if (!isText && !isImage && !isFile) return null;
    final size = event.infoMap['size'];
    return RemoteMessage(
      id: event.eventId,
      roomId: event.room.id,
      senderId: event.senderId,
      type: isImage
          ? 'image'
          : isFile
          ? 'file'
          : 'text',
      body: body,
      timestamp: event.originServerTs,
      isMine: ownUserId != null && event.senderId == ownUserId,
      fileName: isImage || isFile ? body : null,
      fileSize: size is int ? size : null,
      attachmentMxc: isImage || isFile
          ? event.attachmentMxcUrl?.toString()
          : null,
      event: event,
    );
  }

  static RemoteMessage text({
    required String id,
    required String roomId,
    required String senderId,
    required String body,
    required DateTime timestamp,
    required bool isMine,
  }) {
    return RemoteMessage(
      id: id,
      roomId: roomId,
      senderId: senderId,
      type: 'text',
      body: body,
      timestamp: timestamp,
      isMine: isMine,
    );
  }

  static RemoteMessage image({
    required String id,
    required String roomId,
    required String senderId,
    required String body,
    required int fileSize,
    required DateTime timestamp,
    required bool isMine,
    String? attachmentMxc,
  }) {
    return RemoteMessage(
      id: id,
      roomId: roomId,
      senderId: senderId,
      type: 'image',
      body: body,
      fileName: body,
      fileSize: fileSize,
      attachmentMxc: attachmentMxc,
      timestamp: timestamp,
      isMine: isMine,
    );
  }

  static RemoteMessage file({
    required String id,
    required String roomId,
    required String senderId,
    required String body,
    required int fileSize,
    required DateTime timestamp,
    required bool isMine,
  }) {
    return RemoteMessage(
      id: id,
      roomId: roomId,
      senderId: senderId,
      type: 'file',
      body: body,
      fileName: body,
      fileSize: fileSize,
      timestamp: timestamp,
      isMine: isMine,
    );
  }
}

List<RemoteMessage> mergeRemoteMessages(Iterable<RemoteMessage> messages) {
  final byId = <String, RemoteMessage>{};
  for (final message in messages) {
    byId[message.id] = message;
  }
  return byId.values.toList(growable: false);
}
