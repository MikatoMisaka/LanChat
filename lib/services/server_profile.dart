class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required String baseUrl,
    required this.username,
    this.displayName = '',
    this.enabled = true,
    this.pendingRequestId,
  }) : baseUrl = normalizeBaseUrl(baseUrl) {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id');
    }
    if (name.trim().isEmpty || name.runes.length > 64) {
      throw ArgumentError.value(name, 'name');
    }
    if (username.trim().isEmpty || username.length > 128) {
      throw ArgumentError.value(username, 'username');
    }
    if (pendingRequestId != null &&
        (pendingRequestId!.trim().isEmpty || pendingRequestId!.length > 128)) {
      throw ArgumentError.value(pendingRequestId, 'pendingRequestId');
    }
  }

  final String id;
  final String name;
  final String baseUrl;
  final String username;
  final String displayName;
  final bool enabled;
  final String? pendingRequestId;

  Uri get uri => Uri.parse(baseUrl);

  bool get isSecure => uri.scheme == 'https';

  static String normalizeBaseUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw ArgumentError.value(raw, 'baseUrl');
    }
    var path = uri.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return uri.replace(path: path.isEmpty ? '/' : path).toString();
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'username': username,
    if (displayName.trim().isNotEmpty) 'displayName': displayName,
    'enabled': enabled,
    if (pendingRequestId != null) 'pendingRequestId': pendingRequestId,
  };

  static ServerProfile fromMap(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['baseUrl'] is! String ||
        value['username'] is! String) {
      throw const FormatException('Invalid server profile.');
    }
    return ServerProfile(
      id: value['id'] as String,
      name: value['name'] as String,
      baseUrl: value['baseUrl'] as String,
      username: value['username'] as String,
      displayName: value['displayName'] is String
          ? value['displayName'] as String
          : '',
      enabled: value['enabled'] != false,
      pendingRequestId: value['pendingRequestId'] is String
          ? value['pendingRequestId'] as String
          : null,
    );
  }

  ServerProfile withoutPendingRequest() => ServerProfile(
    id: id,
    name: name,
    baseUrl: baseUrl,
    username: username,
    displayName: displayName,
    enabled: enabled,
  );

  @override
  bool operator ==(Object other) =>
      other is ServerProfile &&
      other.id == id &&
      other.name == name &&
      other.baseUrl == baseUrl &&
      other.username == username &&
      other.displayName == displayName &&
      other.enabled == enabled &&
      other.pendingRequestId == pendingRequestId;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    baseUrl,
    username,
    displayName,
    enabled,
    pendingRequestId,
  );
}
