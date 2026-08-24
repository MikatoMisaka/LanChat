import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// PigHub 一条猪猪图
class PigImage {
  final String id;
  final String title;
  final String filename;
  final String url; // 完整 URL

  const PigImage({
    required this.id,
    required this.title,
    required this.filename,
    required this.url,
  });

  bool get isGif => filename.toLowerCase().endsWith('.gif');
}

class StickerService {
  static const String _base = 'https://www.pighub.top';
  static const Duration _cacheTtl = Duration(hours: 1);

  // 内存缓存：同一次运行内「换一批」零开销
  static String? _memBody;
  static DateTime? _memTime;

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'pighub_list.json'));
  }

  /// 读取缓存（内存优先，磁盘次之，过期返回 null）
  Future<String?> _readCache() async {
    final now = DateTime.now();
    if (_memBody != null && _memTime != null && now.difference(_memTime!) <= _cacheTtl) {
      return _memBody;
    }
    try {
      final f = await _cacheFile();
      if (!await f.exists()) return null;
      final modified = (await f.stat()).modified;
      if (now.difference(modified) > _cacheTtl) return null;
      final body = await f.readAsString();
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
      final f = await _cacheFile();
      await f.writeAsString(body, flush: true);
    } catch (_) {}
  }

  /// 拉取猪猪列表并随机抽 [count] 张。
  /// 全量列表做磁盘+内存缓存（1 小时 TTL），「换一批」纯本地随机抽取，零网络请求。
  Future<List<PigImage>> fetchRandomPigs({int count = 10}) async {
    var body = await _readCache();
    if (body == null) {
      final resp = await http
          .get(Uri.parse('$_base/api/images?sort=0'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw Exception('PigHub 请求失败: ${resp.statusCode}');
      }
      body = utf8.decode(resp.bodyBytes);
      await _writeCache(body);
    }
    return _pickRandom(body, count);
  }

  List<PigImage> _pickRandom(String body, int count) {
    final root = jsonDecode(body) as Map<String, dynamic>;
    final code = root['code'];
    final data = root['data'];
    if (code != 0 || data is! List) throw Exception('PigHub 返回异常: $code');
    final all = <PigImage>[];
    for (final item in data) {
      if (item is! Map) continue;
      final imageUrl = item['image_url'];
      final id = item['id']?.toString() ?? '';
      final title = item['title']?.toString() ?? '';
      final filename = item['filename']?.toString() ?? '';
      if (imageUrl is! String || imageUrl.isEmpty) continue;
      all.add(PigImage(
        id: id,
        title: title,
        filename: filename,
        url: imageUrl.startsWith('http') ? imageUrl : '$_base$imageUrl',
      ));
    }
    if (all.isEmpty) return [];
    final rng = Random();
    final picked = <PigImage>[];
    final pool = List<PigImage>.from(all);
    final n = count < pool.length ? count : pool.length;
    for (var i = 0; i < n; i++) {
      picked.add(pool.removeAt(rng.nextInt(pool.length)));
    }
    return picked;
  }

  /// 下载一张猪猪图到临时缓存，返回本地路径（用于 sendFile 当图片发送）
  Future<String> downloadPig(PigImage pig) async {
    final tmp = await getTemporaryDirectory();
    final stickerDir = Directory(p.join(tmp.path, 'pigs'));
    if (!await stickerDir.exists()) await stickerDir.create(recursive: true);
    final localPath = p.join(stickerDir.path, '${pig.id}_${pig.filename}');
    final f = File(localPath);
    if (await f.exists()) return localPath; // 缓存命中
    final resp =
        await http.get(Uri.parse(pig.url)).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) throw Exception('下载失败: ${resp.statusCode}');
    await f.writeAsBytes(resp.bodyBytes, flush: true);
    return localPath;
  }
}
