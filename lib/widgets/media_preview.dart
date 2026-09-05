import 'dart:io';

import 'package:flutter/material.dart';

class MediaPreviewPage extends StatelessWidget {
  const MediaPreviewPage({
    super.key,
    required this.path,
    required this.title,
    required this.onSave,
    required this.onShare,
  });

  final String path;
  final String title;
  final Future<void> Function() onSave;
  final Future<void> Function() onShare;

  Future<void> _showActions(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('保存图片'),
              onTap: () => Navigator.pop(context, 'save'),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('分享图片'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'save') await onSave();
    if (action == 'share') await onShare();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '分享图片',
            onPressed: onShare,
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            tooltip: '保存图片',
            onPressed: onSave,
            icon: const Icon(Icons.save_alt),
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _showActions(context),
        onSecondaryTap: () => _showActions(context),
        child: Center(
          child: Hero(
            tag: path,
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Image.file(
                File(path),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 64,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
