import 'dart:convert';
import 'dart:typed_data';

import 'secure_session.dart';

export 'secure_session.dart' show SecureProtocolException;

class SecureEvent {
  SecureEvent(
    this.kind, {
    Map<String, dynamic>? fields,
    List<int> bytes = const <int>[],
  }) : fields = Map.unmodifiable(fields ?? <String, dynamic>{}),
       bytes = Uint8List.fromList(bytes);

  final String kind;
  final Map<String, dynamic> fields;
  final Uint8List bytes;
}

class SecureEventCodec {
  static const maxMetadataBytes = 8 * 1024;
  static const _metadataLengthBytes = 4;

  static Uint8List encode(SecureEvent event) {
    if (event.kind.isEmpty || event.kind.length > 64) {
      throw SecureProtocolException('Secure event kind is invalid.');
    }
    final metadata = <String, dynamic>{...event.fields, 'kind': event.kind};
    final metadataBytes = utf8.encode(jsonEncode(metadata));
    if (metadataBytes.isEmpty || metadataBytes.length > maxMetadataBytes) {
      throw SecureProtocolException('Secure event metadata is too large.');
    }
    final totalLength =
        _metadataLengthBytes + metadataBytes.length + event.bytes.length;
    if (totalLength > SecureSession.maxPlaintextBytes) {
      throw SecureProtocolException('Secure event exceeds the size limit.');
    }

    final result = Uint8List(totalLength);
    result.buffer.asByteData().setUint32(0, metadataBytes.length, Endian.big);
    result.setAll(_metadataLengthBytes, metadataBytes);
    result.setAll(_metadataLengthBytes + metadataBytes.length, event.bytes);
    return result;
  }

  static SecureEvent decode(List<int> encoded) {
    if (encoded.length < _metadataLengthBytes) {
      throw SecureProtocolException('Secure event is truncated.');
    }
    final metadataLength = ByteData.sublistView(
      Uint8List.fromList(encoded.sublist(0, _metadataLengthBytes)),
    ).getUint32(0, Endian.big);
    if (metadataLength <= 0 || metadataLength > maxMetadataBytes) {
      throw SecureProtocolException('Secure event metadata length is invalid.');
    }
    final metadataStart = _metadataLengthBytes;
    final bytesStart = metadataStart + metadataLength;
    if (bytesStart > encoded.length ||
        encoded.length > SecureSession.maxPlaintextBytes) {
      throw SecureProtocolException('Secure event length is invalid.');
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(encoded.sublist(metadataStart, bytesStart)),
      );
    } catch (_) {
      throw SecureProtocolException('Secure event metadata is not valid JSON.');
    }
    if (decoded is! Map || decoded['kind'] is! String) {
      throw SecureProtocolException('Secure event kind is missing.');
    }
    final fields = <String, dynamic>{};
    decoded.forEach((key, value) {
      if (key != 'kind' && key is String) fields[key] = value;
    });
    return SecureEvent(
      decoded['kind'] as String,
      fields: fields,
      bytes: encoded.sublist(bytesStart),
    );
  }
}
