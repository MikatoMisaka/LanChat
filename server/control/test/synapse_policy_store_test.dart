import 'dart:io';

import 'package:lanchat_control/synapse_policy_store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'updates managed Synapse policy blocks without dropping other settings',
    () async {
      final directory = await Directory.systemTemp.createTemp('lanchat-policy');
      final file = File('${directory.path}/homeserver.yaml');
      await file.writeAsString('''
server_name: "example.com"
max_upload_size: 20M

retention:
  enabled: true
  default_policy:
    min_lifetime: 1d
    max_lifetime: 30d

media_retention:
  local_media_lifetime: 30d

listeners:
  - port: 8008
''');

      await SynapsePolicyStore(file)
          .update(retentionDays: 45, maxUploadBytes: 500 * 1024 * 1024);

      final result = await file.readAsString();
      expect(result, contains('server_name: "example.com"'));
      expect(result, contains('max_upload_size: 500M'));
      expect(result, contains('max_lifetime: 45d'));
      expect(result, contains('local_media_lifetime: 45d'));
      expect(result, contains('listeners:'));
      await directory.delete(recursive: true);
    },
  );
}
