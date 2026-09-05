import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/sticker_service.dart';

class StickerPicker extends StatefulWidget {
  const StickerPicker({
    super.key,
    required this.onEmojiSelected,
    required this.onPigSelected,
  });

  final void Function(String emoji) onEmojiSelected;
  final void Function(String localPath, bool isGif, String displayName)
  onPigSelected;

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);
  final _sticker = StickerService();

  static const _emojis = <String>[
    '😀',
    '😁',
    '😂',
    '🤣',
    '😃',
    '😄',
    '😅',
    '😆',
    '😉',
    '😊',
    '😋',
    '😎',
    '😍',
    '😘',
    '🥰',
    '😗',
    '😙',
    '😚',
    '🙂',
    '🤗',
    '🤔',
    '🤨',
    '😐',
    '😑',
    '😶',
    '🙄',
    '😏',
    '😣',
    '😥',
    '😮',
    '🥺',
    '😯',
    '😪',
    '😫',
    '🥱',
    '😴',
    '😌',
    '😛',
    '😜',
    '😝',
    '🤤',
    '😒',
    '😓',
    '😔',
    '🙃',
    '🤐',
    '🤫',
    '🤥',
    '😶‍🌫️',
    '😇',
    '🤠',
    '🤡',
    '🥳',
    '🥴',
    '🥵',
    '🥶',
    '😱',
    '😨',
    '😰',
    '😥',
    '😡',
    '😠',
    '🤬',
    '😈',
    '👿',
    '💀',
    '💩',
    '🤡',
    '👻',
    '👽',
    '🙏',
    '👍',
    '👎',
    '👌',
    '✌️',
    '🤞',
    '🤟',
    '🤘',
    '👈',
    '👉',
    '🐷',
    '🐖',
    '🐽',
    '❤️',
    '🧡',
    '💛',
    '💚',
    '💙',
    '💜',
    '🔥',
    '✨',
    '⭐',
    '🌟',
    '💫',
    '🎉',
    '🎊',
    '🎁',
    '💯',
    '✅',
  ];

  List<LocalSticker> _recent = [];
  List<LocalSticker> _favorites = [];
  List<LocalSticker> _custom = [];
  List<PigImage> _pigs = [];
  bool _loadingLocal = true;
  bool _loadingPigs = false;
  String? _pigsError;
  final _downloading = <String>{};

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    final recent = await _sticker.recentStickers();
    final favorites = await _sticker.favoriteStickers();
    final custom = await _sticker.customStickers();
    if (!mounted) return;
    setState(() {
      _recent = recent;
      _favorites = favorites;
      _custom = custom;
      _loadingLocal = false;
    });
  }

  Future<void> _loadPigs() async {
    if (_loadingPigs) return;
    setState(() {
      _loadingPigs = true;
      _pigsError = null;
    });
    try {
      final pigs = await _sticker.fetchRandomPigs(count: 10);
      if (!mounted) return;
      setState(() {
        _pigs = pigs;
        _loadingPigs = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pigsError = '加载失败: $e';
        _loadingPigs = false;
      });
    }
  }

  Future<void> _sendPig(PigImage pig) async {
    if (_downloading.contains(pig.id)) return;
    setState(() => _downloading.add(pig.id));
    try {
      final path = await _sticker.downloadPig(pig);
      await _sticker.markPigRecent(pig, path);
      await _loadLocal();
      if (!mounted) return;
      widget.onPigSelected(path, pig.isGif, pig.filename);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发送失败: $e')));
    } finally {
      if (mounted) setState(() => _downloading.remove(pig.id));
    }
  }

  Future<void> _addCustom() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      await _sticker.addCustomSticker(path);
      await _loadLocal();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('添加失败: $e')));
      }
    }
  }

  Future<void> _toggleFavorite(LocalSticker sticker) async {
    final favorite = !_favorites.any((item) => item.id == sticker.id);
    await _sticker.setFavorite(sticker, favorite);
    await _loadLocal();
  }

  Future<void> _togglePigFavorite(PigImage pig) async {
    try {
      await _sticker.togglePigFavorite(pig);
      await _loadLocal();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('收藏失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 310,
      child: Column(
        children: [
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: const [
              Tab(icon: Icon(Icons.emoji_emotions_outlined), text: '表情'),
              Tab(icon: Icon(Icons.history), text: '最近'),
              Tab(icon: Icon(Icons.star_outline), text: '收藏'),
              Tab(icon: Icon(Icons.add_photo_alternate_outlined), text: '自定义'),
              Tab(icon: Icon(Icons.pets), text: '在线小猪'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _emojiGrid(),
                _localGrid(_recent, '还没有最近使用的表情'),
                _localGrid(_favorites, '长按或点击在线图片即可收藏'),
                _customGrid(),
                _pigGrid(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emojiGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        childAspectRatio: 1,
      ),
      itemCount: _emojis.length,
      itemBuilder: (_, index) {
        final emoji = _emojis[index];
        return InkWell(
          onTap: () => widget.onEmojiSelected(emoji),
          child: Center(
            child: Text(emoji, style: const TextStyle(fontSize: 22)),
          ),
        );
      },
    );
  }

  Widget _localGrid(List<LocalSticker> stickers, String emptyText) {
    if (_loadingLocal) return const Center(child: CircularProgressIndicator());
    if (stickers.isEmpty) return Center(child: Text(emptyText));
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: stickers.length,
      itemBuilder: (_, index) {
        final sticker = stickers[index];
        return GestureDetector(
          onTap: () =>
              widget.onPigSelected(sticker.path, sticker.isGif, sticker.name),
          onLongPress: () => _showLocalActions(sticker),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(sticker.path),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showLocalActions(LocalSticker sticker) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.star_outline),
          title: Text(
            _favorites.any((item) => item.id == sticker.id) ? '取消收藏' : '收藏',
          ),
          onTap: () => Navigator.pop(context, 'favorite'),
        ),
      ),
    );
    if (action == 'favorite') await _toggleFavorite(sticker);
  }

  Widget _customGrid() {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 8, top: 4),
            child: FilledButton.tonalIcon(
              onPressed: _addCustom,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加图片'),
            ),
          ),
        ),
        Expanded(child: _localGrid(_custom, '点击上方添加常用表情')),
      ],
    );
  }

  Widget _pigGrid() {
    if (_pigs.isEmpty && !_loadingPigs && _pigsError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPigs());
      return const Center(child: Text('正在准备在线表情…'));
    }
    if (_loadingPigs && _pigs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pigsError != null && _pigs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_pigsError!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
            FilledButton(onPressed: _loadPigs, child: const Text('重试')),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              Text('随机 10 张', style: TextStyle(color: Colors.grey.shade600)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: _loadingPigs ? null : _loadPigs,
                tooltip: '换一批',
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _pigs.length,
            itemBuilder: (_, index) {
              final pig = _pigs[index];
              final downloading = _downloading.contains(pig.id);
              final favorite = _favorites.any(
                (item) => item.id == 'pig:${pig.id}',
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    onTap: downloading ? null : () => _sendPig(pig),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: _PigThumb(url: pig.url),
                    ),
                  ),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black45,
                        foregroundColor: favorite ? Colors.amber : Colors.white,
                      ),
                      onPressed: () => _togglePigFavorite(pig),
                      icon: Icon(
                        favorite ? Icons.star : Icons.star_outline,
                        size: 18,
                      ),
                    ),
                  ),
                  if (downloading)
                    const ColoredBox(
                      color: Colors.black38,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PigThumb extends StatefulWidget {
  const _PigThumb({required this.url});

  final String url;

  @override
  State<_PigThumb> createState() => _PigThumbState();
}

class _PigThumbState extends State<_PigThumb> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uri = Uri.tryParse(widget.url);
      if (uri == null || uri.scheme != 'https') throw StateError('unsafe url');
      final response = await http.get(uri).timeout(const Duration(seconds: 20));
      final contentType = response.headers['content-type'] ?? '';
      if (response.statusCode != 200 ||
          response.bodyBytes.isEmpty ||
          response.bodyBytes.length > 10 * 1024 * 1024 ||
          (contentType.isNotEmpty && !contentType.startsWith('image/'))) {
        throw StateError('invalid image response');
      }
      if (!mounted) return;
      setState(() => _bytes = response.bodyBytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) return Image.memory(_bytes!, fit: BoxFit.cover);
    if (_failed) {
      return ColoredBox(
        color: Colors.grey.shade200,
        child: const Icon(Icons.broken_image_outlined),
      );
    }
    return ColoredBox(
      color: Colors.grey.shade100,
      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }
}
