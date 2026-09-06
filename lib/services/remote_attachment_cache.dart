import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'remote_message_adapter.dart';

class RemoteAttachmentCache {
  RemoteAttachmentCache({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getTemporaryDirectory;

  static const autoReceiveLimit = 2 * 1024 * 1024;

  final Future<Directory> Function() _directoryProvider;
  final _inFlight = <String, Future<Uint8List>>{};

  bool shouldAutoReceive(RemoteMessage message) =>
      !message.isMine &&
      message.isImage &&
      message.fileSize != null &&
      message.fileSize! < autoReceiveLimit;

  Future<String?> autoReceiveImage(
    RemoteMessage message,
    Future<Uint8List> Function() download, {
    String scope = '',
  }) async {
    if (!shouldAutoReceive(message)) return null;
    try {
      final bytes = await loadImage(message, download, scope: scope);
      if (bytes.length >= autoReceiveLimit) {
        await _delete(message, scope: scope);
        return null;
      }
      return await cachedPathFor(message, scope: scope);
    } catch (_) {
      await _delete(message, scope: scope);
      return null;
    }
  }

  Future<Uint8List> loadImage(
    RemoteMessage message,
    Future<Uint8List> Function() download, {
    String scope = '',
  }) async {
    final cached = await _read(message, scope: scope);
    if (cached != null) return cached;

    final key = _key(message, scope);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _downloadAndCache(message, download, scope: scope);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }
  }

  Future<String?> cachedPathFor(
    RemoteMessage message, {
    String scope = '',
  }) async {
    final file = File(await _pathFor(message, scope: scope));
    if (!await file.exists()) return null;
    if (await file.length() == 0) {
      await file.delete();
      return null;
    }
    return file.path;
  }

  Future<Uint8List> _downloadAndCache(
    RemoteMessage message,
    Future<Uint8List> Function() download, {
    required String scope,
  }) async {
    final cached = await _read(message, scope: scope);
    if (cached != null) return cached;
    final bytes = await download();
    if (bytes.isEmpty) throw const FormatException('Empty image attachment.');
    final file = File(await _pathFor(message, scope: scope));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return bytes;
  }

  Future<Uint8List?> _read(
    RemoteMessage message, {
    required String scope,
  }) async {
    final file = File(await _pathFor(message, scope: scope));
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      await file.delete();
      return null;
    }
    return bytes;
  }

  Future<void> _delete(RemoteMessage message, {required String scope}) async {
    final file = File(await _pathFor(message, scope: scope));
    if (await file.exists()) await file.delete();
  }

  Future<String> _pathFor(
    RemoteMessage message, {
    required String scope,
  }) async {
    final directory = await _directoryProvider();
    return p.join(directory.path, 'lanchat-${_key(message, scope)}.img');
  }

  String _key(RemoteMessage message, String scope) =>
      base64UrlEncode(utf8.encode('$scope\n${message.id}')).replaceAll('=', '');
}
