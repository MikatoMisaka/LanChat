import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

Future<String> sha256File(File file) async {
  Digest? digest;
  final digestSink = ChunkedConversionSink<Digest>.withCallback(
    (digests) => digest = digests.single,
  );
  final input = sha256.startChunkedConversion(digestSink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return base64UrlEncode(digest!.bytes).replaceAll('=', '');
}
