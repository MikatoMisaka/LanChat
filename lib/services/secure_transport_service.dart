import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import 'file_digest.dart';
import 'identity_service.dart';
import 'secure_protocol.dart';
import 'secure_session.dart';
import 'transport_service.dart';

class SecureTransportException implements Exception {
  SecureTransportException(this.message);

  final String message;

  @override
  String toString() => 'SecureTransportException: $message';
}

class PairingRequest {
  const PairingRequest({
    required this.requestId,
    required this.peerId,
    required this.peerName,
    required this.peerPublicKey,
    required this.peerIp,
    required this.peerPort,
    required this.verificationCode,
  });

  final String requestId;
  final String peerId;
  final String peerName;
  final String peerPublicKey;
  final String peerIp;
  final int peerPort;
  final String verificationCode;
}

class FileOfferDecision {
  const FileOfferDecision({required this.accepted, this.offset = 0});

  const FileOfferDecision.accept({this.offset = 0}) : accepted = true;

  const FileOfferDecision.reject() : accepted = false, offset = 0;

  final bool accepted;
  final int offset;
}

class PairingAttempt {
  PairingAttempt._({
    required this.peerId,
    required this.peerName,
    required this.peerPublicKey,
    required this.verificationCode,
    required this._confirmCallback,
    required this._rejectCallback,
  });

  final String peerId;
  final String peerName;
  final String peerPublicKey;
  final String verificationCode;
  final Future<void> Function() _confirmCallback;
  final Future<void> Function() _rejectCallback;
  bool _finished = false;

  Future<void> confirm() async {
    if (_finished) throw StateError('Pairing attempt is already finished.');
    _finished = true;
    await _confirmCallback();
  }

  Future<void> reject() async {
    if (_finished) return;
    _finished = true;
    await _rejectCallback();
  }
}

class SecureTransportService {
  static const fixedPort = 45679;
  static const maxFileBytes = 5 * 1024 * 1024 * 1024;
  static const maxTextBytes = 60 * 1024;
  static const maxConnections = 16;
  static const maxConnectionsPerIp = 4;
  static const maxQueuedFramesPerConnection = 64;
  static const _idleTimeout = Duration(seconds: 60);
  static const _pairingTimeout = Duration(minutes: 2);
  static const _handshakeTimeout = Duration(seconds: 5);
  static const maxTransferDuration = Duration(hours: 2);
  static const _chunkBytes = 48 * 1024;

  SecureTransportService({
    required this.selfId,
    required this.selfName,
    required this.selfPublicKey,
    required this.sharedSecretForPublicKey,
    required this.peerPublicKey,
    required this.savePeerPublicKey,
    required this.onSecureEvent,
    this.onPairingRequest,
    this.onPairingComplete,
    this.onFileOffer,
    this.onFileChunk,
    this.onFileComplete,
    this.onDisconnect,
  });

  final String Function() selfId;
  final String Function() selfName;
  final Future<String> Function() selfPublicKey;
  final Future<List<int>> Function(String encodedPublicKey)
  sharedSecretForPublicKey;
  final Future<String?> Function(String peerId) peerPublicKey;
  final Future<void> Function(String peerId, String publicKey)
  savePeerPublicKey;
  final Future<void> Function(String peerId, SecureEvent event) onSecureEvent;
  final Future<bool> Function(PairingRequest request)? onPairingRequest;
  final Future<void> Function(
    String peerId,
    String peerName,
    String ip,
    int port,
  )?
  onPairingComplete;
  final Future<FileOfferDecision> Function(String peerId, SecureEvent event)?
  onFileOffer;
  final Future<void> Function(String peerId, SecureEvent event)? onFileChunk;
  final Future<bool> Function(String peerId, SecureEvent event)? onFileComplete;
  final void Function(String peerIp, String? peerId)? onDisconnect;

  final _uuid = const Uuid();
  ServerSocket? _server;
  final Set<_RawConnection> _incoming = {};
  int listenPort = 0;

  Future<int> start({int? port}) async {
    if (_server != null) return listenPort;
    final requestedPort = port ?? fixedPort;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, requestedPort);
    } on SocketException {
      if (port != null) rethrow;
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    listenPort = _server!.port;
    _server!.listen(_acceptSocket, onError: (_) {});
    return listenPort;
  }

  void _acceptSocket(Socket socket) {
    final ip = socket.remoteAddress.address;
    if (_incoming.length >= maxConnections ||
        _incoming.where((connection) => connection.ip == ip).length >=
            maxConnectionsPerIp) {
      socket.destroy();
      return;
    }

    late final _RawConnection connection;
    connection = _RawConnection(
      socket,
      queueFrames: false,
      idleTimeout: _idleTimeout,
      onFrame: (frame) =>
          connection.enqueue(() => _handleIncomingFrame(connection, frame)),
      onClosed: () {
        _incoming.remove(connection);
        onDisconnect?.call(ip, connection.peerId);
      },
    );
    _incoming.add(connection);
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    final connections = List<_RawConnection>.from(_incoming);
    await Future.wait(connections.map((connection) => connection.close()));
    _incoming.clear();
    listenPort = 0;
  }

  Future<void> sendText(
    String ip,
    int port,
    String text, {
    String? peerId,
    String? messageId,
    int? timestamp,
  }) async {
    final id = peerId;
    if (id == null || id.isEmpty) {
      throw SecureTransportException('A paired peer id is required.');
    }
    if (utf8.encode(text).length > maxTextBytes) {
      throw SecureTransportException('Text message is too large.');
    }
    final connection = await _connectSecure(ip, port, id);
    try {
      await connection.sendSecureEvent(
        SecureEvent(
          'text',
          fields: {
            'text': text,
            'messageId': messageId ?? _uuid.v4(),
            'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
          },
        ),
      );
    } finally {
      await connection.close();
    }
  }

  Future<String> sendFile({
    required String ip,
    required int port,
    required String filePath,
    required String fileName,
    required bool isImage,
    String? peerId,
    String? transferId,
    String? messageId,
    int? timestamp,
    void Function(double progress)? onProgress,
  }) async {
    final id = peerId;
    if (id == null || id.isEmpty) {
      throw SecureTransportException('A paired peer id is required.');
    }
    final file = File(filePath);
    final size = await file.length();
    if (size < 0 || size > maxFileBytes) {
      throw SecureTransportException('File exceeds the 5 GiB limit.');
    }
    if (fileName.isEmpty || utf8.encode(fileName).length > 255) {
      throw SecureTransportException('File name is invalid.');
    }
    final digest = await sha256File(file);
    final tid = transferId ?? _uuid.v4();
    final startedAt = DateTime.now();
    final connection = await _connectSecure(ip, port, id);
    try {
      await connection.sendSecureEvent(
        SecureEvent(
          'file_offer',
          fields: {
            'transferId': tid,
            'fileName': fileName,
            'size': size,
            'mime': _guessMime(fileName),
            'image': isImage,
            'messageId': messageId ?? _uuid.v4(),
            'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
          },
        ),
      );
      final response = await connection.nextSecureEvent(
        timeout: _handshakeTimeout,
      );
      if (response.kind == 'file_reject') {
        throw SecureTransportException('Peer rejected the file.');
      }
      if (response.kind != 'file_accept' ||
          response.fields['transferId'] != tid) {
        throw SecureTransportException('Invalid file acceptance response.');
      }
      final offset = _intField(response.fields, 'offset');
      if (offset < 0 || offset > size) {
        throw SecureTransportException('Invalid resume offset.');
      }
      connection.fileTotals[tid] = size;
      if (size == 0) {
        onProgress?.call(1.0);
      } else {
        var sent = offset;
        await for (final chunk in file.openRead(offset)) {
          for (var start = 0; start < chunk.length; start += _chunkBytes) {
            if (DateTime.now().difference(startedAt) > maxTransferDuration) {
              throw SecureTransportException(
                'File transfer time limit reached.',
              );
            }
            final end = min(start + _chunkBytes, chunk.length);
            final part = chunk.sublist(start, end);
            await connection.sendSecureEvent(
              SecureEvent(
                'file_chunk',
                fields: {'transferId': tid, 'offset': sent, 'total': size},
                bytes: part,
              ),
            );
            sent += part.length;
            onProgress?.call(sent / size);
          }
        }
      }
      if (DateTime.now().difference(startedAt) > maxTransferDuration) {
        throw SecureTransportException('File transfer time limit reached.');
      }
      await connection.sendSecureEvent(
        SecureEvent(
          'file_complete',
          fields: {'transferId': tid, 'total': size, 'digest': digest},
        ),
      );
      final done = await connection.nextSecureEvent(timeout: _handshakeTimeout);
      if (done.kind != 'file_done' || done.fields['transferId'] != tid) {
        throw SecureTransportException('Peer did not confirm the file.');
      }
      onProgress?.call(1.0);
      return tid;
    } finally {
      await connection.close();
    }
  }

  Future<PairingAttempt> requestPairing(
    String ip,
    int port, {
    String? expectedPeerId,
  }) async {
    final connection = await _connectRaw(
      ip,
      port,
      idleTimeout: _pairingTimeout,
    );
    final requestId = _uuid.v4();
    try {
      await connection.sendControl({
        'kind': 'pair_request',
        'requestId': requestId,
        'id': selfId(),
        'name': selfName(),
        'publicKey': await selfPublicKey(),
        'port': listenPort,
      });
      final challengeFrame = await connection.nextRaw(
        (frame) => frame.header.type == FrameType.control,
        timeout: _pairingTimeout,
      );
      final challenge = _decodeControl(challengeFrame.payload);
      if (challenge['kind'] == 'pair_reject') {
        throw SecureTransportException('Peer rejected the pairing request.');
      }
      if (challenge['kind'] != 'pair_challenge' ||
          challenge['requestId'] != requestId) {
        throw SecureTransportException('Invalid pairing challenge.');
      }
      final peerId = _stringField(challenge, 'id', maxLength: 128);
      final peerName = _stringField(challenge, 'name', maxLength: 128);
      final peerPublicKey = _stringField(
        challenge,
        'publicKey',
        maxLength: 128,
      );
      if (expectedPeerId != null && expectedPeerId != peerId) {
        throw SecureTransportException('QR code peer identity does not match.');
      }
      final sharedSecret = await sharedSecretForPublicKey(peerPublicKey);
      final code = await verificationCode(sharedSecret);

      Future<void> confirm() async {
        try {
          await connection.sendControl({
            'kind': 'pair_confirm',
            'requestId': requestId,
            'proof': await _pairingProof(sharedSecret, 'confirm'),
          });
          final doneFrame = await connection.nextRaw(
            (frame) => frame.header.type == FrameType.control,
            timeout: _pairingTimeout,
          );
          final done = _decodeControl(doneFrame.payload);
          if (done['kind'] != 'pair_done' ||
              done['requestId'] != requestId ||
              done['proof'] != await _pairingProof(sharedSecret, 'done')) {
            throw SecureTransportException('Pairing confirmation failed.');
          }
          await savePeerPublicKey(peerId, peerPublicKey);
          await onPairingComplete?.call(peerId, peerName, ip, port);
        } finally {
          await connection.close();
        }
      }

      Future<void> reject() async {
        try {
          await connection.sendControl({
            'kind': 'pair_reject',
            'requestId': requestId,
          });
        } finally {
          await connection.close();
        }
      }

      return PairingAttempt._(
        peerId: peerId,
        peerName: peerName,
        peerPublicKey: peerPublicKey,
        verificationCode: code,
        confirmCallback: confirm,
        rejectCallback: reject,
      );
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  Future<_RawConnection> _connectSecure(
    String ip,
    int port,
    String peerId,
  ) async {
    final expectedPublicKey = await peerPublicKey(peerId);
    if (expectedPublicKey == null || expectedPublicKey.isEmpty) {
      throw SecureTransportException('Peer is not paired.');
    }
    final connection = await _connectRaw(ip, port);
    try {
      final nonce = Uint8List.fromList(
        List<int>.generate(16, (_) => Random.secure().nextInt(256)),
      );
      await connection.sendControl({
        'kind': 'secure_hello',
        'id': selfId(),
        'publicKey': await selfPublicKey(),
        'nonce': base64UrlEncode(nonce).replaceAll('=', ''),
      });
      final welcomeFrame = await connection.nextRaw(
        (frame) => frame.header.type == FrameType.control,
        timeout: _handshakeTimeout,
      );
      final welcome = _decodeControl(welcomeFrame.payload);
      final remoteId = _stringField(welcome, 'id', maxLength: 128);
      final remotePublicKey = _stringField(
        welcome,
        'publicKey',
        maxLength: 128,
      );
      final remoteNonce = _decodeBytes(welcome, 'nonce', expectedLength: 16);
      if (welcome['kind'] != 'secure_welcome' ||
          remoteId != peerId ||
          remotePublicKey != expectedPublicKey ||
          !_sameBytes(remoteNonce, nonce)) {
        throw SecureTransportException('Secure handshake identity mismatch.');
      }
      final sharedSecret = await sharedSecretForPublicKey(expectedPublicKey);
      connection.session = await SecureSession.fromSharedSecret(
        sharedSecret: sharedSecret,
        sessionNonce: nonce,
        initiator: true,
      );
      await connection.sendSecureEvent(
        SecureEvent(
          'auth',
          fields: {
            'challenge': base64UrlEncode(
              List<int>.generate(16, (_) => Random.secure().nextInt(256)),
            ).replaceAll('=', ''),
          },
        ),
      );
      final authOk = await connection.nextSecureEvent(
        timeout: _handshakeTimeout,
      );
      if (authOk.kind != 'auth_ok') {
        throw SecureTransportException(
          'Secure handshake authentication failed.',
        );
      }
      connection.peerId = peerId;
      connection.authenticated = true;
      return connection;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  Future<_RawConnection> _connectRaw(
    String ip,
    int port, {
    Duration? idleTimeout,
  }) async {
    final socket = await Socket.connect(ip, port, timeout: _handshakeTimeout);
    return _RawConnection(socket, idleTimeout: idleTimeout ?? _idleTimeout);
  }

  Future<void> _handleIncomingFrame(
    _RawConnection connection,
    _RawFrame frame,
  ) async {
    if (connection.closed) return;
    if (connection.session == null) {
      if (frame.header.type != FrameType.control) {
        throw SecureTransportException('Handshake control frame required.');
      }
      final control = _decodeControl(frame.payload);
      final kind = control['kind'];
      if (kind == 'pair_request') {
        await _handlePairRequest(connection, control);
        return;
      }
      if (kind == 'pair_confirm' && connection.pairingAccepted) {
        await _handlePairConfirm(connection, control);
        return;
      }
      if (kind == 'secure_hello') {
        await _handleSecureHello(connection, control);
        return;
      }
      throw SecureTransportException('Unexpected handshake control frame.');
    }

    if (!connection.authenticated) {
      if (frame.header.type != FrameType.secure) {
        throw SecureTransportException('Encrypted authentication required.');
      }
      final event = await connection.openSecure(frame.payload);
      if (event.kind != 'auth') {
        throw SecureTransportException('Secure authentication frame required.');
      }
      await connection.sendSecureEvent(SecureEvent('auth_ok'));
      connection.authenticated = true;
      return;
    }

    if (frame.header.type != FrameType.secure) {
      throw SecureTransportException('Encrypted application frame required.');
    }
    await _handleSecureEvent(
      connection,
      await connection.openSecure(frame.payload),
    );
  }

  Future<void> _handlePairRequest(
    _RawConnection connection,
    Map<String, dynamic> control,
  ) async {
    final requestId = _stringField(control, 'requestId', maxLength: 128);
    final peerId = _stringField(control, 'id', maxLength: 128);
    final peerName = _stringField(control, 'name', maxLength: 128);
    final peerPublicKey = _stringField(control, 'publicKey', maxLength: 128);
    final peerPort = _intField(control, 'port');
    if (peerId == selfId() || peerPort < 0 || peerPort > 65535) {
      throw SecureTransportException('Pairing request fields are invalid.');
    }
    final sharedSecret = await sharedSecretForPublicKey(peerPublicKey);
    final code = await verificationCode(sharedSecret);
    connection.peerId = peerId;
    connection.pairingRequestId = requestId;
    connection.pairingPeerName = peerName;
    connection.pairingPeerPublicKey = peerPublicKey;
    connection.pairingPeerPort = peerPort;
    connection.pairingSecret = sharedSecret;
    final request = PairingRequest(
      requestId: requestId,
      peerId: peerId,
      peerName: peerName,
      peerPublicKey: peerPublicKey,
      peerIp: connection.ip,
      peerPort: peerPort,
      verificationCode: code,
    );
    final accepted = await onPairingRequest?.call(request) ?? false;
    if (!accepted || connection.closed) {
      await connection.sendControl({
        'kind': 'pair_reject',
        'requestId': requestId,
      });
      await connection.close();
      return;
    }
    connection.pairingAccepted = true;
    await connection.sendControl({
      'kind': 'pair_challenge',
      'requestId': requestId,
      'id': selfId(),
      'name': selfName(),
      'publicKey': await selfPublicKey(),
    });
  }

  Future<void> _handlePairConfirm(
    _RawConnection connection,
    Map<String, dynamic> control,
  ) async {
    final requestId = _stringField(control, 'requestId', maxLength: 128);
    final proof = _stringField(control, 'proof', maxLength: 128);
    final secret = connection.pairingSecret;
    if (connection.pairingRequestId != requestId || secret == null) {
      throw SecureTransportException('Pairing confirmation does not match.');
    }
    if (proof != await _pairingProof(secret, 'confirm')) {
      throw SecureTransportException('Pairing proof is invalid.');
    }
    final peerId = connection.peerId!;
    final peerName = connection.pairingPeerName!;
    final peerPublicKey = connection.pairingPeerPublicKey!;
    await savePeerPublicKey(peerId, peerPublicKey);
    await connection.sendControl({
      'kind': 'pair_done',
      'requestId': requestId,
      'proof': await _pairingProof(secret, 'done'),
    });
    await onPairingComplete?.call(
      peerId,
      peerName,
      connection.ip,
      connection.pairingPeerPort,
    );
    await connection.close();
  }

  Future<void> _handleSecureHello(
    _RawConnection connection,
    Map<String, dynamic> control,
  ) async {
    final peerId = _stringField(control, 'id', maxLength: 128);
    final encodedPeerPublicKey = _stringField(
      control,
      'publicKey',
      maxLength: 128,
    );
    final nonce = _decodeBytes(control, 'nonce', expectedLength: 16);
    final trustedPublicKey = await peerPublicKey(peerId);
    if (trustedPublicKey == null || trustedPublicKey != encodedPeerPublicKey) {
      throw SecureTransportException('Unpaired or forged peer identity.');
    }
    final sharedSecret = await sharedSecretForPublicKey(encodedPeerPublicKey);
    connection.peerId = peerId;
    connection.session = await SecureSession.fromSharedSecret(
      sharedSecret: sharedSecret,
      sessionNonce: nonce,
      initiator: false,
    );
    await connection.sendControl({
      'kind': 'secure_welcome',
      'id': selfId(),
      'publicKey': await selfPublicKey(),
      'nonce': base64UrlEncode(nonce).replaceAll('=', ''),
    });
  }

  Future<void> _handleSecureEvent(
    _RawConnection connection,
    SecureEvent event,
  ) async {
    final peerId = connection.peerId;
    if (peerId == null || peerId.isEmpty) {
      throw SecureTransportException('Secure peer identity is missing.');
    }
    switch (event.kind) {
      case 'text':
        final text = event.fields['text'];
        if (text is! String || utf8.encode(text).length > maxTextBytes) {
          throw SecureTransportException('Secure text event is invalid.');
        }
        await onSecureEvent(peerId, event);
      case 'file_offer':
        await _handleFileOffer(connection, event);
      case 'file_chunk':
        _validateFileChunk(connection, event);
        await onFileChunk?.call(peerId, event);
      case 'file_complete':
        _validateFileComplete(connection, event);
        final accepted = await onFileComplete?.call(peerId, event) ?? false;
        final transferId = _stringField(
          event.fields,
          'transferId',
          maxLength: 128,
        );
        await connection.sendSecureEvent(
          SecureEvent(
            accepted ? 'file_done' : 'file_failed',
            fields: {'transferId': transferId},
          ),
        );
        await connection.close();
      case 'file_cancel':
        await onSecureEvent(peerId, event);
      default:
        throw SecureTransportException('Unknown secure event kind.');
    }
  }

  Future<void> _handleFileOffer(
    _RawConnection connection,
    SecureEvent event,
  ) async {
    final peerId = connection.peerId!;
    final transferId = _stringField(event.fields, 'transferId', maxLength: 128);
    final size = _intField(event.fields, 'size');
    final fileName = _stringField(event.fields, 'fileName', maxLength: 255);
    if (size < 0 || size > maxFileBytes || fileName.isEmpty) {
      throw SecureTransportException('File offer is invalid.');
    }
    final decision =
        await onFileOffer?.call(peerId, event) ??
        const FileOfferDecision.reject();
    if (!decision.accepted || decision.offset < 0 || decision.offset > size) {
      await connection.sendSecureEvent(
        SecureEvent('file_reject', fields: {'transferId': transferId}),
      );
      return;
    }
    connection.fileTotals[transferId] = size;
    await connection.sendSecureEvent(
      SecureEvent(
        'file_accept',
        fields: {'transferId': transferId, 'offset': decision.offset},
      ),
    );
  }

  void _validateFileChunk(_RawConnection connection, SecureEvent event) {
    final transferId = _stringField(event.fields, 'transferId', maxLength: 128);
    final offset = _intField(event.fields, 'offset');
    final total = _intField(event.fields, 'total');
    final expectedTotal = connection.fileTotals[transferId];
    if (expectedTotal == null ||
        total != expectedTotal ||
        offset < 0 ||
        event.bytes.isEmpty ||
        event.bytes.length > _chunkBytes ||
        offset + event.bytes.length > total) {
      throw SecureTransportException('File chunk is invalid.');
    }
  }

  void _validateFileComplete(_RawConnection connection, SecureEvent event) {
    final transferId = _stringField(event.fields, 'transferId', maxLength: 128);
    final total = _intField(event.fields, 'total');
    final digest = _stringField(event.fields, 'digest', maxLength: 128);
    final expectedTotal = connection.fileTotals[transferId];
    if (expectedTotal == null ||
        total != expectedTotal ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(digest)) {
      throw SecureTransportException('File completion is invalid.');
    }
  }

  Map<String, dynamic> _decodeControl(List<int> payload) {
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map || decoded['kind'] is! String) {
        throw const FormatException();
      }
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw SecureTransportException('Control frame is invalid.');
    }
  }

  String _stringField(
    Map<String, dynamic> fields,
    String name, {
    required int maxLength,
  }) {
    final value = fields[name];
    if (value is! String || value.isEmpty || value.length > maxLength) {
      throw SecureTransportException('Invalid control field: $name.');
    }
    return value;
  }

  int _intField(Map<String, dynamic> fields, String name) {
    final value = fields[name];
    if (value is! int || value < 0) {
      throw SecureTransportException('Invalid numeric field: $name.');
    }
    return value;
  }

  List<int> _decodeBytes(
    Map<String, dynamic> fields,
    String name, {
    required int expectedLength,
  }) {
    final value = _stringField(fields, name, maxLength: expectedLength * 2);
    try {
      final bytes = base64Url.decode(base64Url.normalize(value));
      if (bytes.length != expectedLength) throw const FormatException();
      return bytes;
    } catch (_) {
      throw SecureTransportException('Invalid encoded field: $name.');
    }
  }

  Future<String> _pairingProof(List<int> secret, String label) async {
    final hash = await Sha256().hash([
      ...secret,
      ...utf8.encode('lanchat-pair-v1/$label'),
    ]);
    return base64UrlEncode(hash.bytes).replaceAll('=', '');
  }

  bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
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

class _RawFrame {
  const _RawFrame(this.header, this.payload);

  final MessageHeader header;
  final Uint8List payload;
}

class _RawWaiter {
  _RawWaiter(this.predicate, this.completer);

  final bool Function(_RawFrame frame) predicate;
  final Completer<_RawFrame> completer;
  Timer? timer;
}

class _RawConnection {
  _RawConnection(
    this.socket, {
    this.queueFrames = true,
    this.onFrame,
    this.onClosed,
    Duration idleTimeout = const Duration(seconds: 60),
    Duration lifetime = SecureTransportService.maxTransferDuration,
  }) : ip = socket.remoteAddress.address {
    _reader = FrameReader(
      socket,
      onFrame: (header, payload) => _addFrame(_RawFrame(header, payload)),
      onAbort: () => socket.destroy(),
    );
    _reader.listen();
    _touch(idleTimeout);
    _lifetimeTimer = Timer(lifetime, close);
    socket.done.then<void>(
      (_) => _closeState(),
      onError: (Object error, StackTrace stackTrace) => _closeState(),
    );
  }

  late final FrameReader _reader;
  final Socket socket;
  final String ip;
  final bool queueFrames;
  final void Function(_RawFrame frame)? onFrame;
  final void Function()? onClosed;
  final List<_RawFrame> _frames = [];
  final List<_RawWaiter> _waiters = [];
  Future<void> _processing = Future<void>.value();
  int _queuedActions = 0;
  Timer? _idleTimer;
  Timer? _lifetimeTimer;
  bool closed = false;
  bool _closedNotified = false;
  SecureSession? session;
  bool authenticated = false;
  String? peerId;
  String? pairingRequestId;
  String? pairingPeerName;
  String? pairingPeerPublicKey;
  int pairingPeerPort = 0;
  List<int>? pairingSecret;
  bool pairingAccepted = false;
  final Map<String, int> fileTotals = {};

  void _touch(Duration timeout) {
    _idleTimer?.cancel();
    _idleTimer = Timer(timeout, close);
  }

  void _addFrame(_RawFrame frame) {
    if (closed) return;
    if (queueFrames) {
      for (var i = 0; i < _waiters.length; i++) {
        final waiter = _waiters[i];
        if (waiter.predicate(frame)) {
          _waiters.removeAt(i);
          waiter.timer?.cancel();
          waiter.completer.complete(frame);
          onFrame?.call(frame);
          return;
        }
      }
      _frames.add(frame);
    }
    onFrame?.call(frame);
  }

  void enqueue(Future<void> Function() action) {
    if (closed) return;
    if (_queuedActions >= SecureTransportService.maxQueuedFramesPerConnection) {
      unawaited(close());
      return;
    }
    _queuedActions++;
    _processing = _processing.then<void>((_) async {
      _queuedActions--;
      if (closed) return;
      try {
        await action();
      } catch (_) {
        await close();
      }
    });
  }

  Future<_RawFrame> nextRaw(
    bool Function(_RawFrame frame) predicate, {
    required Duration timeout,
  }) {
    if (closed) {
      return Future.error(SecureTransportException('Connection closed.'));
    }
    for (var i = 0; i < _frames.length; i++) {
      final frame = _frames[i];
      if (predicate(frame)) {
        _frames.removeAt(i);
        return Future.value(frame);
      }
    }
    final waiter = _RawWaiter(predicate, Completer<_RawFrame>());
    waiter.timer = Timer(timeout, () {
      _waiters.remove(waiter);
      waiter.completer.completeError(
        SecureTransportException('Timed out waiting for peer.'),
      );
    });
    _waiters.add(waiter);
    return waiter.completer.future;
  }

  Future<void> sendControl(Map<String, dynamic> control) async {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(control)));
    await sendRaw(
      MessageHeader(
        type: FrameType.control,
        msgId: const Uuid().v4(),
        ts: DateTime.now().millisecondsSinceEpoch,
        size: payload.length,
      ),
      payload,
    );
  }

  Future<void> sendSecureEvent(SecureEvent event) async {
    final currentSession = session;
    if (currentSession == null) {
      throw SecureTransportException('Secure session is not ready.');
    }
    final payload = await currentSession.seal(SecureEventCodec.encode(event));
    await sendRaw(
      MessageHeader(
        type: FrameType.secure,
        msgId: const Uuid().v4(),
        ts: DateTime.now().millisecondsSinceEpoch,
        size: payload.length,
      ),
      payload,
    );
  }

  Future<SecureEvent> nextSecureEvent({required Duration timeout}) async {
    final frame = await nextRaw(
      (frame) => frame.header.type == FrameType.secure,
      timeout: timeout,
    );
    return openSecure(frame.payload);
  }

  Future<SecureEvent> openSecure(List<int> payload) async {
    final currentSession = session;
    if (currentSession == null) {
      throw SecureTransportException('Secure session is not ready.');
    }
    try {
      return SecureEventCodec.decode(await currentSession.open(payload));
    } on SecureProtocolException {
      rethrow;
    } catch (_) {
      throw SecureTransportException('Secure frame could not be opened.');
    }
  }

  Future<void> sendRaw(MessageHeader header, List<int> payload) async {
    if (closed) throw SecureTransportException('Connection closed.');
    socket.add(FrameCodec.encodePayload(header, payload));
    await socket.flush();
    _idleTimer?.cancel();
    _touch(const Duration(seconds: 60));
  }

  Future<void> close() async {
    if (closed) {
      _notifyClosed();
      return;
    }
    closed = true;
    _idleTimer?.cancel();
    _lifetimeTimer?.cancel();
    try {
      await socket.close();
    } catch (_) {
      socket.destroy();
    }
    _closeWaiters();
    _notifyClosed();
  }

  void _closeState() {
    if (closed) {
      _notifyClosed();
      return;
    }
    closed = true;
    _idleTimer?.cancel();
    _lifetimeTimer?.cancel();
    _closeWaiters();
    _notifyClosed();
  }

  void _notifyClosed() {
    if (_closedNotified) return;
    _closedNotified = true;
    onClosed?.call();
  }

  void _closeWaiters() {
    final error = SecureTransportException('Connection closed.');
    for (final waiter in _waiters) {
      waiter.timer?.cancel();
      if (!waiter.completer.isCompleted) waiter.completer.completeError(error);
    }
    _waiters.clear();
    _frames.clear();
  }
}
