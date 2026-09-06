import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/remote_matrix_service.dart';
import '../services/remote_message_adapter.dart';
import '../widgets/sticker_picker.dart';

class ServerChatPage extends StatefulWidget {
  const ServerChatPage({
    super.key,
    required this.service,
    required this.roomId,
    required this.title,
  });

  final RemoteMatrixService service;
  final String roomId;
  final String title;

  @override
  State<ServerChatPage> createState() => _ServerChatPageState();
}

class _ServerChatPageState extends State<ServerChatPage> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<RemoteMessage>? _messageSubscription;
  final _imageLoads = <String, Future<Uint8List>>{};
  List<RemoteMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  bool _showSticker = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _messageSubscription = widget.service.onMessage.listen((message) {
      if (message.roomId == widget.roomId && mounted) {
        setState(
          () => _messages = mergeRemoteMessages([..._messages, message]),
        );
        _jumpBottom();
      }
    });
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final messages = await widget.service.messagesForRoom(widget.roomId);
      if (!mounted) return;
      setState(() {
        _messages = mergeRemoteMessages([...messages, ..._messages]);
        _loading = false;
      });
      _jumpBottom();
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        _toast('加载消息失败：$error');
      }
    }
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: MediaQuery.of(context).disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _sendText() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.service.sendText(widget.roomId, text);
      if (mounted) _controller.clear();
      await _load();
    } catch (error) {
      if (mounted) _toast('$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path == null || _sending) return;
    await _sendAttachment(path, image: true);
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path == null || _sending) return;
    await _sendAttachment(path, image: false);
  }

  Future<void> _sendAttachment(String path, {required bool image}) async {
    setState(() => _sending = true);
    try {
      if (image) {
        await widget.service.sendImage(widget.roomId, path);
      } else {
        await widget.service.sendFile(widget.roomId, path);
      }
      await _load();
    } catch (error) {
      if (mounted) _toast('$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _onEmoji(String emoji) {
    final current = _controller.text;
    _controller.text = current + emoji;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
  }

  void _onPig(String localPath, bool isGif, String displayName) {
    setState(() => _showSticker = false);
    unawaited(_sendAttachment(localPath, image: true));
  }

  Future<void> _saveFile(RemoteMessage message) async {
    try {
      final bytes = await widget.service.downloadFile(message);
      final name = p.basename(message.fileName ?? message.body);
      final temporary = await getTemporaryDirectory();
      final eventKey = message.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final path = p.join(temporary.path, '$eventKey-$name');
      await File(path).writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(path)], text: name);
    } catch (error) {
      if (mounted) _toast('保存文件失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                    itemCount: _messages.length,
                    itemBuilder: (_, index) => _bubble(_messages[index]),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: '表情和贴纸',
                    onPressed: _sending
                        ? null
                        : () => setState(() => _showSticker = !_showSticker),
                    icon: Icon(
                      _showSticker
                          ? Icons.keyboard_hide_outlined
                          : Icons.emoji_emotions_outlined,
                    ),
                  ),
                  IconButton(
                    tooltip: '发送图片',
                    onPressed: _sending ? null : _pickImage,
                    icon: const Icon(Icons.image_outlined),
                  ),
                  IconButton(
                    tooltip:
                        '发送小文件（最多 ${_formatBytes(widget.service.capabilities?.maxFileBytes ?? RemoteServerLimits.maxFileBytes)}）',
                    onPressed: _sending ? null : _pickFile,
                    icon: const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      maxLines: 4,
                      minLines: 1,
                      onSubmitted: (_) => _sendText(),
                      decoration: const InputDecoration(
                        hintText: '输入远程消息…',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '发送',
                    onPressed: _sending ? null : _sendText,
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: MediaQuery.of(context).disableAnimations
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: _showSticker
                ? StickerPicker(
                    onEmojiSelected: _onEmoji,
                    onPigSelected: _onPig,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _bubble(RemoteMessage message) {
    final alignment = message.isMine
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final color = message.isMine
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
          ),
          child: message.isImage
              ? _remoteImage(message)
              : message.isFile
              ? _remoteFile(message)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: 1,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 300),
                        child: SelectableText(message.body),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      DateFormat('HH:mm').format(message.timestamp),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _remoteImage(RemoteMessage message) {
    return FutureBuilder<Uint8List>(
      future: _imageFuture(message),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          if (snapshot.hasError) {
            return SizedBox(
              width: 180,
              height: 120,
              child: IconButton(
                tooltip: '重新加载图片',
                onPressed: () => setState(() {}),
                icon: const Icon(Icons.refresh),
              ),
            );
          }
          return const SizedBox(
            width: 180,
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(snapshot.data!, width: 220, fit: BoxFit.contain),
        );
      },
    );
  }

  Future<Uint8List> _imageFuture(RemoteMessage message) {
    return _imageLoads.putIfAbsent(message.id, () async {
      try {
        return await widget.service.downloadImage(message);
      } catch (_) {
        _imageLoads.remove(message.id);
        rethrow;
      }
    });
  }

  Widget _remoteFile(RemoteMessage message) {
    final size = message.fileSize;
    final label = size == null ? '文件' : _formatBytes(size);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.insert_drive_file_outlined, size: 34),
        const SizedBox(width: 9),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.fileName ?? message.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Text(label, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
        IconButton(
          tooltip: '保存文件',
          onPressed: () => _saveFile(message),
          icon: const Icon(Icons.download_outlined),
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
