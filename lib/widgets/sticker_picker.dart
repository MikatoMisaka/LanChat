import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/sticker_service.dart';

/// 表情/图片选择面板：
/// - 表情 tab：常用 emoji，点一下作为文本发送
/// - 小猪 tab：从 PigHub 随机抓 10 张，点一下下载并作为图片发送
class StickerPicker extends StatefulWidget {
  /// 选了 emoji 文本
  final void Function(String emoji) onEmojiSelected;
  /// 选了猪猪图（本地缓存路径 + 是否GIF + 原文件名）
  final void Function(String localPath, bool isGif, String displayName)
      onPigSelected;

  const StickerPicker({
    super.key,
    required this.onEmojiSelected,
    required this.onPigSelected,
  });

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _sticker = StickerService();

  static const _emojis = <String>[
    '😀','😁','😂','🤣','😃','😄','😅','😆','😉','😊',
    '😋','😎','😍','😘','🥰','😗','😙','😚','🙂','🤗',
    '🤔','🤨','😐','😑','😶','🙄','😏','😣','😥','😮',
    '🥺','😯','😪','😫','🥱','😴','😌','😛','😜','😝',
    '🤤','😒','😓','😔','🙃','🤐','🤫','🤥','😶‍🌫️','😇',
    '🤠','🤡','🥳','🥴','🥵','🥶','😱','😨','😰','😥',
    '😡','😠','🤬','😈','👿','💀','💩','🤡','👻','👽',
    '🙏','👍','👎','👌','✌️','🤞','🤟','🤘','👈','👉',
    '🐷','🐖','🐽','🐷','❤️','🧡','💛','💚','💙','💜',
    '🔥','✨','⭐','🌟','💫','🎉','🎊','🎁','💯','✅',
  ];

  List<PigImage> _pigs = [];
  bool _loadingPigs = false;
  String? _pigsError;
  final _downloading = <String>{}; // 正在下载的 pig.id

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
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
      if (!mounted) return;
      widget.onPigSelected(path, pig.isGif, pig.filename);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败: $e'), duration: const Duration(seconds: 2)),
      );
    } finally {
      if (mounted) setState(() => _downloading.remove(pig.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 260,
      child: Column(
        children: [
          TabBar(
            controller: _tabs,
            tabs: const [
              Tab(icon: Icon(Icons.emoji_emotions_outlined), text: '表情'),
              Tab(icon: Icon(Icons.pets), text: '随机小猪'),
            ],
            labelColor: Theme.of(context).colorScheme.primary,
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _emojiGrid(),
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
      itemBuilder: (_, i) {
        final e = _emojis[i];
        return InkWell(
          onTap: () => widget.onEmojiSelected(e),
          child: Center(
            child: Text(e, style: const TextStyle(fontSize: 22)),
          ),
        );
      },
    );
  }

  Widget _pigGrid() {
    if (_pigs.isEmpty && !_loadingPigs && _pigsError == null) {
      // 首次进入该 tab 时自动加载
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPigs());
      return const Center(child: Text('点下方刷新抓取小猪', style: TextStyle(color: Colors.grey)));
    }
    if (_loadingPigs && _pigs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pigsError != null && _pigs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_pigsError!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            const SizedBox(height: 8),
            FilledButton(onPressed: _loadPigs, child: const Text('重试')),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Text('随机 10 张小猪',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
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
              childAspectRatio: 1,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: _pigs.length,
            itemBuilder: (_, i) {
              final pig = _pigs[i];
              final dl = _downloading.contains(pig.id);
              return GestureDetector(
                onTap: dl ? null : () => _sendPig(pig),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: _PigThumb(url: pig.url),
                    ),
                    if (pig.isGif)
                      Positioned(
                        left: 4,
                        top: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text('GIF',
                              style: TextStyle(color: Colors.white, fontSize: 9)),
                        ),
                      ),
                    if (dl)
                      Container(
                        color: Colors.black38,
                        child: const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 猪猪缩略图：用 http 下载字节转 Image.memory（避免依赖 cached_network_image）
class _PigThumb extends StatefulWidget {
  final String url;
  const _PigThumb({required this.url});

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
      final resp = await http.get(Uri.parse(widget.url)).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        setState(() => _bytes = resp.bodyBytes);
      } else {
        setState(() => _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: BoxFit.cover);
    }
    if (_failed) {
      return Container(
        color: Colors.grey.shade300,
        child: const Icon(Icons.broken_image, size: 24),
      );
    }
    return Container(
      color: Colors.grey.shade200,
      child: const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
