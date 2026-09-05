class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required String baseUrl,
    required this.username,
    this.enabled = true,
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
  }

  final String id;
  final String name;
  final String baseUrl;
  final String username;
  final bool enabled;

  Uri get uri => Uri.parse(baseUrl);

  static String normalizeBaseUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
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
        'enabled': enabled,
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
      enabled: value['enabled'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ServerProfile &&
      other.id == id &&
      other.name == name &&
      other.baseUrl == baseUrl &&
      other.username == username &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, name, baseUrl, username, enabled);
}
