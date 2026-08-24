import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../services/app_state.dart';
import '../services/db_service.dart';
import '../widgets/sticker_picker.dart';

class ChatPage extends StatefulWidget {
  final String deviceId;
  const ChatPage({super.key, required this.deviceId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  List<Message> _messages = [];
  StreamSubscription? _sub;
  StreamSubscription<(String, String)>? _mergeSub;
  bool _sending = false;
  final Map<String, double> _progress = {};
  late String _deviceId;
  bool _showSticker = false;
  StreamSubscription<FileReceivingEvent>? _fileSub;
  final Map<String, _Receiving> _receiving = {};

  @override
  void initState() {
    super.initState();
    _deviceId = widget.deviceId;
    _load();
    final app = AppStateScope.of(context);
    _sub = app.onNewMessage.listen((devId) {
      if (devId == _deviceId) _load();
    });
    // 设备 id 合并（同 IP 收敛）时跟随切换，避免聊天页失联
    _mergeSub = app.onDeviceMerged.listen((merge) {
      final (oldId, newId) = merge;
      if (oldId == _deviceId && mounted) {
        setState(() => _deviceId = newId);
        _load();
      }
    });
    // 接收文件：显示「正在接收」气泡 + 进度条
    _fileSub = app.onFileReceiving.listen((e) {
      if (e.deviceId != _deviceId) return;
      if (e.done) {
        if (_receiving.containsKey(e.msgId)) {
          setState(() => _receiving.remove(e.msgId));
        }
        return;
      }
      final cur = _receiving[e.msgId];
      if (cur == null) {
        setState(() =>
            _receiving[e.msgId] = _Receiving(e.msgId, e.fileName, e.total));
        _jumpBottom();
      } else if (e.received != cur.received) {
        setState(() => cur.received = e.received);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _mergeSub?.cancel();
    _fileSub?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppStateScope.of(context);
    final msgs = await app.db.getMessages(_deviceId);
    if (mounted) {
      setState(() => _messages = msgs);
      _jumpBottom();
    }
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _sendText() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    final app = AppStateScope.of(context);
    final dev = app.devices[_deviceId];
    if (dev == null) return;
    _controller.clear();
    final m = Message(
      id: const Uuid().v4(),
      deviceId: dev.id,
      direction: 1,
      type: 'text',
      content: text,
      status: 0,
      createdAt: DateTime.now(),
    );
    setState(() {
      _messages.add(m);
      _sending = true;
    });
    _jumpBottom();
    try {
      await app.transport.sendText(dev.ip, dev.port, text);
      m.status = 1;
    } catch (_) {
      // 旧地址连不上：探测对方新地址并重试一次（IP 愈合）
      final healed = await app.retrySendText(dev.id, text);
      m.status = healed ? 1 : 2;
    }
    await app.db.insertMessage(m);
    app.recordSentMessage(m);
    if (mounted) {
      setState(() => _sending = false);
      _jumpBottom();
    }
  }

  Future<void> _pickFile() async {
    final app = AppStateScope.of(context);
    final dev = app.devices[_deviceId];
    if (dev == null) return;
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;
    await _sendFile(result.files.single.path!, result.files.single.name, false);
  }

  Future<void> _pickImage() async {
    final app = AppStateScope.of(context);
    final dev = app.devices[_deviceId];
    if (dev == null) return;
    if (Platform.isWindows) {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      if (result == null || result.files.single.path == null) return;
      await _sendFile(result.files.single.path!, result.files.single.name, true);
      return;
    }
    final img = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (img == null) return;
    await _sendFile(img.path, p.basename(img.path), true);
  }

  /// 表情面板：emoji 追加到输入框；猪猪图下载后当图片发送（GIF 也走 image 通道）
  void _onEmoji(String emoji) {
    final cur = _controller.text;
    _controller.text = cur + emoji;
    _controller.selection =
        TextSelection.fromPosition(TextPosition(offset: _controller.text.length));
  }

  Future<void> _onPig(String localPath, bool isGif, String displayName) async {
    setState(() => _showSticker = false);
    await _sendFile(localPath, displayName, true);
  }

  Future<void> _sendFile(String path, String name, bool isImage) async {
    final app = AppStateScope.of(context);
    final dev = app.devices[_deviceId];
    if (dev == null) return;
    final size = await File(path).length();
    final m = Message(
      id: const Uuid().v4(),
      deviceId: dev.id,
      direction: 1,
      type: isImage ? 'image' : 'file',
      content: name,
      filePath: path,
      fileSize: size,
      status: 0,
      createdAt: DateTime.now(),
    );
    setState(() {
      _messages.add(m);
      _progress[m.id] = 0;
    });
    _jumpBottom();
    try {
      await app.transport.sendFile(
        ip: dev.ip,
        port: dev.port,
        filePath: path,
        fileName: name,
        isImage: isImage,
        onProgress: (v) {
          if (mounted) setState(() => _progress[m.id] = v);
        },
      );
      m.status = 1;
    } catch (_) {
      // 旧地址连不上：探测对方新地址并重试一次（IP 愈合）
      final healed = await app.retrySendFile(dev.id,
          filePath: path,
          fileName: name,
          isImage: isImage,
          onProgress: (v) {
            if (mounted) setState(() => _progress[m.id] = v);
          });
      m.status = healed ? 1 : 2;
    }
    await app.db.insertMessage(m);
    app.recordSentMessage(m);
    if (mounted) {
      setState(() => _progress.remove(m.id));
      _jumpBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final dev = app.devices[_deviceId];
    final online = dev != null && app.isOnline(dev);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dev?.name ?? '聊天', style: const TextStyle(fontSize: 17)),
            Text(
              online ? '在线' : (dev?.isManual ?? false ? '手动添加 · 连不上会提示失败' : '离线'),
              style: TextStyle(
                fontSize: 11,
                color: online ? Colors.lightGreen : Colors.grey,
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) =>
                v == 'clear' ? _confirmClear() : _confirmDeleteDevice(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('清空聊天记录')),
              PopupMenuItem(value: 'delete', child: Text('删除该设备')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: _messages.length + _receiving.length,
              itemBuilder: (_, i) {
                if (i < _messages.length) return _bubble(_messages[i]);
                final r = _receiving.values.elementAt(i - _messages.length);
                return _receivingBubble(r);
              },
            ),
          ),
          SafeArea(
            child: Row(
              children: [
                IconButton(
                  icon: Icon(_showSticker
                      ? Icons.keyboard
                      : Icons.emoji_emotions_outlined),
                  onPressed: () =>
                      setState(() => _showSticker = !_showSticker),
                  tooltip: '表情',
                ),
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _pickFile,
                ),
                IconButton(
                  icon: const Icon(Icons.image),
                  onPressed: _pickImage,
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: '输入消息…',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                    onSubmitted: (_) => _sendText(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendText,
                ),
              ],
            ),
          ),
          if (_showSticker)
            StickerPicker(
              onEmojiSelected: _onEmoji,
              onPigSelected: _onPig,
            ),
        ],
      ),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空聊天记录？'),
        content: const Text('将删除与该设备的全部消息和收到的文件'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final app = AppStateScope.of(context);
    await app.clearMessages(_deviceId);
    await _load();
  }

  Future<void> _confirmDeleteDevice() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除该设备？'),
        content: const Text('将删除该设备、全部聊天记录和收到的文件'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final app = AppStateScope.of(context);
    await app.deleteDevice(_deviceId);
    if (mounted) Navigator.pop(context);
  }

  /// 长按消息弹出操作菜单
  Future<void> _showMessageMenu(Message m) async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            if (m.type == 'text')
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('复制'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: m.content));
                  if (ctx.mounted) Navigator.pop(ctx);
                  _toast('已复制');
                },
              ),
            if (m.type == 'file' || m.type == 'image')
              ListTile(
                leading: const Icon(Icons.save_alt),
                title: const Text('保存 / 分享'),
                onTap: () {
                  Navigator.pop(ctx);
                  _saveFile(m);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteMessage(m);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteMessage(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除该消息？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final app = AppStateScope.of(context);
    await app.deleteMessage(m);
    await _load();
  }

  /// 接收中的文件：临时气泡（下载图标 + 文件名 + 进度条），完成后自动被正式消息替换
  Widget _receivingBubble(_Receiving r) {
    final pct = r.total > 0 ? (r.received / r.total).clamp(0.0, 1.0) : 0.0;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _avatar(_deviceId, _peerName()),
            const SizedBox(width: 6),
            Flexible(
              child: Container(
                width: 230,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.download, size: 36),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.fileName,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(value: pct),
                          const SizedBox(height: 4),
                          Text(
                            '正在接收 ${_fmtSize(r.received)} / ${_fmtSize(r.total)}',
                            style:
                                const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _peerName() {
    final app = AppStateScope.of(context);
    return app.devices[_deviceId]?.name ?? '对方';
  }

  String _fmtSize(int b) {
    if (b > 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    if (b > 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '$b B';
  }

  Widget _avatar(String deviceId, String name) {
    final app = AppStateScope.of(context);
    final d = app.devices[deviceId];
    if (d != null && d.avatarPath != null && File(d.avatarPath!).existsSync()) {
      return CircleAvatar(
        radius: 16,
        backgroundImage: FileImage(File(d.avatarPath!)),
      );
    }
    return CircleAvatar(
      radius: 16,
      child: Text(name.isNotEmpty ? name.characters.first : '?'),
    );
  }

  Widget _bubble(Message m) {
    final mine = m.direction == 1;
    final time = DateFormat('HH:mm').format(m.createdAt);
    final bubbleColor = mine
        ? const Color(0xFF95EC69)
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(12),
      topRight: const Radius.circular(12),
      bottomLeft: Radius.circular(mine ? 12 : 4),
      bottomRight: Radius.circular(mine ? 4 : 12),
    );
    Widget content;
    switch (m.type) {
      case 'image':
        content = _imageBubble(m);
      case 'file':
        content = _fileBubble(m);
      default:
        content = ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(m.content),
        );
    }
    final app = AppStateScope.of(context);
    final peerName = app.devices[_deviceId]?.name ?? '对方';
    // 自己的消息：气泡 + 头像（头像在右）；对方消息：头像 + 气泡（头像在左），并显示昵称
    final bubble = GestureDetector(
      onLongPress: () => _showMessageMenu(m),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: radius,
        ),
        child: content,
      ),
    );
    final avatar = _avatar(_deviceId, peerName);
    return Align(
      alignment: align,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!mine)
              Padding(
                padding: const EdgeInsets.only(left: 38, bottom: 2),
                child: Text(peerName,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            Directionality(
              textDirection: mine ? ui.TextDirection.rtl : ui.TextDirection.ltr,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  avatar,
                  const SizedBox(width: 6),
                  Flexible(child: bubble),
                ],
              ),
            ),
            Text(
              '$time${mine && m.status == 2 ? ' 发送失败' : ''}',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageBubble(Message m) {
    if (m.filePath != null && File(m.filePath!).existsSync()) {
      return GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => _FullImage(path: m.filePath!),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(m.filePath!),
            width: 200,
            cacheWidth: 600,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _brokenImage(),
          ),
        ),
      );
    }
    return _brokenImage();
  }

  Widget _brokenImage() => Container(
        width: 200,
        height: 120,
        color: Colors.grey.shade300,
        child: const Icon(Icons.broken_image, size: 40),
      );

  Widget _fileBubble(Message m) {
    final size = m.fileSize ?? 0;
    final sizeStr = size > 1024 * 1024
        ? '${(size / 1024 / 1024).toStringAsFixed(1)} MB'
        : '${(size / 1024).toStringAsFixed(0)} KB';
    final progress = _progress[m.id];
    return GestureDetector(
      onTap: () => _saveFile(m),
      child: SizedBox(
        width: 230,
        child: Row(
          children: [
            const Icon(Icons.insert_drive_file, size: 36),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.content,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  progress != null
                      ? LinearProgressIndicator(value: progress)
                      : Text(
                          m.direction == 1 && m.status == 2
                              ? '发送失败'
                              : '$sizeStr · 点击分享保存',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveFile(Message m) async {
    if (m.filePath == null || !File(m.filePath!).existsSync()) {
      _toast('文件不存在');
      return;
    }
    try {
      if (Platform.isWindows) {
        final target =
            await FilePicker.platform.saveFile(fileName: m.content);
        if (target != null && target.isNotEmpty) {
          await File(m.filePath!).copy(target);
          _toast('已保存到 $target');
        }
        return;
      }
      final tmp = await getTemporaryDirectory();
      final clean = p.join(tmp.path, m.content);
      await File(m.filePath!).copy(clean);
      await Share.shareXFiles([XFile(clean)], text: m.content);
    } catch (e) {
      _toast('保存失败: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }
}

class _FullImage extends StatelessWidget {
  final String path;
  const _FullImage({required this.path});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: Center(
        child: InteractiveViewer(
          child: Image.file(File(path)),
        ),
      ),
    );
  }
}

/// 接收中的文件（临时状态，完成后被正式 Message 替换）
class _Receiving {
  final String msgId;
  final String fileName;
  final int total;
  int received;
  _Receiving(this.msgId, this.fileName, this.total) : received = 0;
}
