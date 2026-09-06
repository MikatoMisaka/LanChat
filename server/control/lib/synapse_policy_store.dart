import 'dart:io';

class SynapsePolicyStore {
  SynapsePolicyStore(this.file);

  final File file;

  Future<void> update({
    required int retentionDays,
    required int maxUploadBytes,
  }) async {
    if (retentionDays < 1 || retentionDays > 365) {
      throw ArgumentError.value(retentionDays, 'retentionDays');
    }
    if (maxUploadBytes < 1 || maxUploadBytes > 500 * 1024 * 1024) {
      throw ArgumentError.value(maxUploadBytes, 'maxUploadBytes');
    }
    if (maxUploadBytes % (1024 * 1024) != 0) {
      throw ArgumentError.value(maxUploadBytes, 'maxUploadBytes');
    }
    if (!await file.exists()) {
      throw StateError('Synapse configuration does not exist.');
    }

    final lines = (await file.readAsString()).split('\n');
    _setScalar(
      lines,
      'max_upload_size',
      '${maxUploadBytes ~/ (1024 * 1024)}M',
      after: 'server_name',
    );
    _replaceBlock(lines, 'retention', [
      'retention:',
      '  enabled: true',
      '  default_policy:',
      '    min_lifetime: 1d',
      '    max_lifetime: ${retentionDays}d',
      '  allowed_lifetime_min: 1d',
      '  allowed_lifetime_max: ${retentionDays}d',
      '',
    ]);
    _replaceBlock(lines, 'media_retention', [
      'media_retention:',
      '  local_media_lifetime: ${retentionDays}d',
      '  remote_media_lifetime: ${retentionDays}d',
      '',
    ]);

    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(lines.join('\n'), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  void _setScalar(
    List<String> lines,
    String key,
    String value, {
    String? after,
  }) {
    final active = RegExp('^${RegExp.escape(key)}:');
    for (var i = 0; i < lines.length; i++) {
      if (active.hasMatch(lines[i])) {
        lines[i] = '$key: $value';
        return;
      }
    }
    var index = 0;
    if (after != null) {
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('$after:')) {
          index = i + 1;
          break;
        }
      }
    }
    lines.insert(index, '$key: $value');
  }

  void _replaceBlock(
    List<String> lines,
    String name,
    List<String> replacement,
  ) {
    final header = '$name:';
    var start = lines.indexOf(header);
    if (start < 0) {
      lines.addAll(['', ...replacement]);
      return;
    }
    var end = lines.length;
    for (var i = start + 1; i < lines.length; i++) {
      if (RegExp(r'^[A-Za-z0-9_-]+:').hasMatch(lines[i])) {
        end = i;
        break;
      }
    }
    lines.replaceRange(start, end, replacement);
  }
}
