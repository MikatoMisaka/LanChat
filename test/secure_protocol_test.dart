import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/secure_protocol.dart';

void main() {
  test('roundtrips secure event metadata and binary chunk', () {
    final event = SecureEvent(
      'file_chunk',
      fields: {'transferId': 't1', 'offset': 4096, 'total': 8192},
      bytes: List<int>.generate(32, (index) => index),
    );

    final decoded = SecureEventCodec.decode(SecureEventCodec.encode(event));

    expect(decoded.kind, 'file_chunk');
    expect(decoded.fields['transferId'], 't1');
    expect(decoded.fields['offset'], 4096);
    expect(decoded.bytes, List<int>.generate(32, (index) => index));
  });

  test('rejects malformed secure event metadata', () {
    final malformed = <int>[0, 0, 0, 1, 0x7b];

    expect(
      () => SecureEventCodec.decode(malformed),
      throwsA(isA<SecureProtocolException>()),
    );
  });

  test('encodes JSON control events without binary data', () {
    final event = SecureEvent('text', fields: {'text': '你好'});

    final decoded = SecureEventCodec.decode(SecureEventCodec.encode(event));

    expect(decoded.bytes, isEmpty);
    expect(decoded.fields['text'], '你好');
    expect(utf8.decode(utf8.encode(decoded.fields['text'] as String)), '你好');
  });
}
