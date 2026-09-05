import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/remote_matrix_service.dart';
import '../services/remote_message_adapter.dart';

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
  List<RemoteMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _messageSubscription = widget.service.onMessage.listen((message) {
      if (message.roomId == widget.roomId && mounted) {
        setState(() => _messages = [..._messages, message]);
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
        _messages = messages;
        _loading = false;
      });
      _jumpBottom();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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
    _controller.clear();
    setState(() => _sending = true);
    try {
      await widget.service.sendText(widget.roomId, text);
      await _load();
    } catch (error) {
      if (mounted) _toast('$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path == null || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.service.sendImage(widget.roomId, path);
      await _load();
    } catch (error) {
      if (mounted) _toast('$error');
    } finally {
      if (mounted) setState(() => _sending = false);
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
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '发送图片',
                    onPressed: _sending ? null : _sendImage,
                    icon: const Icon(Icons.image_outlined),
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
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(RemoteMessage message) {
    final alignment = message.isMine ? Alignment.centerRight : Alignment.centerLeft;
    final color = message.isMine
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
          ),
          child: message.isImage
              ? _remoteImage(message)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(message.body),
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
      future: widget.service.downloadImage(message),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          if (snapshot.hasError) {
            return const SizedBox(
              width: 180,
              height: 120,
              child: Icon(Icons.broken_image_outlined),
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
