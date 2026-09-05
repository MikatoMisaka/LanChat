import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class PigImage {
  final String id;
  final String title;
  final String filename;
  final String url;

  const PigImage({
    required this.id,
    required this.title,
    required this.filename,
    required this.url,
  });

  bool get isGif => filename.toLowerCase().endsWith('.gif');
}

class LocalSticker {
  const LocalSticker({
    required this.id,
    required this.path,
    required this.name,
    required this.isGif,
  });

  final String id;
  final String path;
  final String name;
  final bool isGif;

  Map<String, dynamic> toMap() => {
    'id': id,
    'path': path,
    'name': name,
    'isGif': isGif,
  };

  static LocalSticker? fromMap(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['path'] is! String ||
        value['name'] is! String ||
        value['isGif'] is! bool) {
      return null;
    }
    return LocalSticker(
      id: value['id'] as String,
      path: value['path'] as String,
      name: value['name'] as String,
      isGif: value['isGif'] as bool,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LocalSticker && other.id == id && other.path == path;

  @override
  int get hashCode => Object.hash(id, path);
}

class StickerService {
  static const String _base = 'https://www.pighub.top';
  static const Duration _cacheTtl = Duration(hours: 1);
  static const int _maxListBytes = 2 * 1024 * 1024;
  static const int _maxStickerBytes = 10 * 1024 * 1024;
  static const _recentKey = 'stickers.recent';
  static const _favoriteKey = 'stickers.favorite';
  static const _customKey = 'stickers.custom';

  StickerService({
    http.Client? client,
    Future<Directory> Function()? supportDirectory,
  }) : _client = client ?? http.Client(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final http.Client _client;
  final Future<Directory> Function() _supportDirectory;
  static String? _memBody;
  static DateTime? _memTime;

  Future<File> _cacheFile() async {
    final dir = await _supportDirectory();
    return File(p.join(dir.path, 'pighub_list.json'));
  }

  Future<String?> _readCache() async {
    final now = DateTime.now();
    if (_memBody != null &&
        _memTime != null &&
        now.difference(_memTime!) <= _cacheTtl) {
      return _memBody;
    }
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null;
      final stat = await file.stat();
      if (now.difference(stat.modified) > _cacheTtl ||
          stat.size > _maxListBytes) {
        return null;
      }
      final body = await file.readAsString();
      _memBody = body;
      _memTime = now;
      return body;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String body) async {
    _memBody = body;
    _memTime = DateTime.now();
    try {
      final file = await _cacheFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(body, flush: true);
    } catch (_) {}
  }

  Future<List<PigImage>> fetchRandomPigs({int count = 10}) async {
    if (count < 1 || count > 20) {
      throw ArgumentError.value(count, 'count');
    }
    var body = await _readCache();
    if (body == null) {
      final response = await _client
          .get(Uri.parse('$_base/api/images?sort=0'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 ||
          response.bodyBytes.length > _maxListBytes) {
        throw Exception('PigHub 请求失败: ${response.statusCode}');
      }
      body = utf8.decode(response.bodyBytes);
      await _writeCache(body);
    }
    return _pickRandom(body, count);
  }

  List<PigImage> _pickRandom(String body, int count) {
    final root = jsonDecode(body);
    if (root is! Map || root['code'] != 0 || root['data'] is! List) {
      throw Exception('PigHub 返回异常');
    }
    final all = <PigImage>[];
    for (final item in root['data'] as List) {
      if (item is! Map) continue;
      final imageUrl = item['image_url'];
      final id = item['id']?.toString() ?? '';
      final title = item['title']?.toString() ?? '';
      final filename = item['filename']?.toString() ?? '';
      if (imageUrl is! String || imageUrl.isEmpty) continue;
      final uri = Uri.tryParse(
        imageUrl.startsWith('http') ? imageUrl : '$_base$imageUrl',
      );
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) continue;
      all.add(
        PigImage(
          id: id,
          title: title,
          filename: _safeName(filename.isEmpty ? 'sticker' : filename),
          url: uri.toString(),
        ),
      );
    }
    if (all.isEmpty) return [];
    final rng = Random();
    final pool = List<PigImage>.from(all);
    final picked = <PigImage>[];
    final n = min(count, pool.length);
    for (var i = 0; i < n; i++) {
      picked.add(pool.removeAt(rng.nextInt(pool.length)));
    }
    return picked;
  }

  Future<String> downloadPig(PigImage pig) async {
    final uri = Uri.tryParse(pig.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw Exception('图片地址不安全');
    }
    final root = await _supportDirectory();
    final stickerDir = Directory(p.join(root.path, 'stickers', 'cache'));
    await stickerDir.create(recursive: true);
    final id = _safeName(pig.id.isEmpty ? const Uuid().v4() : pig.id);
    final filename = _safeName(pig.filename);
    final localPath = p.join(stickerDir.path, '${id}_$filename');
    final file = File(localPath);
    if (await file.exists()) return localPath;
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 ||
        response.bodyBytes.isEmpty ||
        response.bodyBytes.length > _maxStickerBytes) {
      throw Exception('下载失败: ${response.statusCode}');
    }
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.isNotEmpty && !contentType.startsWith('image/')) {
      throw Exception('下载内容不是图片');
    }
    await file.writeAsBytes(response.bodyBytes, flush: true);
    return localPath;
  }

  Future<LocalSticker> addCustomSticker(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw Exception('图片不存在');
    final size = await source.length();
    if (size <= 0 || size > _maxStickerBytes) {
      throw Exception('图片大小必须在 1 B 到 10 MB 之间');
    }
    final extension = p.extension(sourcePath).toLowerCase();
    if (!{'.jpg', '.jpeg', '.png', '.gif', '.webp'}.contains(extension)) {
      throw Exception('只支持 JPG、PNG、GIF 和 WebP 图片');
    }
    final root = await _supportDirectory();
    final directory = Directory(p.join(root.path, 'stickers', 'custom'));
    await directory.create(recursive: true);
    final id = const Uuid().v4();
    final target = File(p.join(directory.path, '$id$extension'));
    await source.copy(target.path);
    final sticker = LocalSticker(
      id: id,
      path: target.path,
      name: p.basename(sourcePath),
      isGif: extension == '.gif',
    );
    final custom = await customStickers();
    await _writeList(_customKey, [sticker, ...custom]);
    return sticker;
  }

  Future<List<LocalSticker>> recentStickers() => _readList(_recentKey);

  Future<List<LocalSticker>> favoriteStickers() => _readList(_favoriteKey);

  Future<List<LocalSticker>> customStickers() => _readList(_customKey);

  Future<void> markRecent(LocalSticker sticker) async {
    final current = await recentStickers();
    await _writeList(
      _recentKey,
      [
        sticker,
        ...current.where((item) => item.id != sticker.id),
      ].take(30).toList(),
    );
  }

  Future<void> setFavorite(LocalSticker sticker, bool favorite) async {
    final current = await favoriteStickers();
    final next = current.where((item) => item.id != sticker.id).toList();
    if (favorite) next.insert(0, sticker);
    await _writeList(_favoriteKey, next.take(100).toList());
  }

  Future<bool> isFavorite(String id) async {
    return (await favoriteStickers()).any((sticker) => sticker.id == id);
  }

  Future<void> markPigRecent(PigImage pig, String path) {
    return markRecent(
      LocalSticker(
        id: 'pig:${pig.id}',
        path: path,
        name: pig.filename,
        isGif: pig.isGif,
      ),
    );
  }

  Future<bool> togglePigFavorite(PigImage pig) async {
    final id = 'pig:${pig.id}';
    final current = await favoriteStickers();
    final existing = current.where((item) => item.id == id).toList();
    if (existing.isNotEmpty) {
      await setFavorite(existing.single, false);
      return false;
    }
    final path = await downloadPig(pig);
    await setFavorite(
      LocalSticker(id: id, path: path, name: pig.filename, isGif: pig.isGif),
      true,
    );
    return true;
  }

  Future<List<LocalSticker>> _readList(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final result = <LocalSticker>[];
      for (final value in decoded) {
        final sticker = LocalSticker.fromMap(value);
        if (sticker != null && await File(sticker.path).exists()) {
          result.add(sticker);
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeList(String key, List<LocalSticker> stickers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(stickers.map((sticker) => sticker.toMap()).toList()),
    );
  }

  String _safeName(String value) {
    var name = value.trim().split(RegExp(r'[/\\]')).last;
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    if (name.isEmpty || name == '.' || name == '..') name = 'sticker';
    return name.length > 100 ? name.substring(name.length - 100) : name;
  }
}
