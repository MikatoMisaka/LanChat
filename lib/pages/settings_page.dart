import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_state.dart';
import '../widgets/chat_theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    final app = AppStateScope.of(context);
    _nameCtrl = TextEditingController(text: app.selfName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    String? source;
    if (Platform.isWindows) {
      final r = await FilePicker.platform.pickFiles(type: FileType.image);
      source = r?.files.single.path;
    } else {
      final img = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 128,
        maxHeight: 128,
        imageQuality: 60,
      );
      source = img?.path;
    }
    if (source == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final target =
        '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(source).copy(target);
    if (mounted) {
      await AppStateScope.of(context).setSelfAvatar(target);
    }
  }

  Future<void> _export() async {
    final app = AppStateScope.of(context);
    try {
      final json = await app.db.exportJson();
      final text = await app.db.exportText();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      if (Platform.isWindows) {
        // Windows 无沙箱限制，直接写到下载目录
        final downloads = await getDownloadsDirectory();
        final dir = downloads ?? await getApplicationDocumentsDirectory();
        final f1 = File('${dir.path}/lanchat_export_$stamp.json')
          ..writeAsStringSync(json);
        File('${dir.path}/lanchat_export_$stamp.txt').writeAsStringSync(text);
        _toast('已导出到 ${f1.parent.path}');
        return;
      }
      final tmp = await getTemporaryDirectory();
      final f1 = File('${tmp.path}/lanchat_export_$stamp.json')
        ..writeAsStringSync(json);
      final f2 = File('${tmp.path}/lanchat_export_$stamp.txt')
        ..writeAsStringSync(text);
      await Share.shareXFiles([
        XFile(f1.path),
        XFile(f2.path),
      ], text: 'LanChat 聊天记录');
    } catch (e) {
      _toast('导出失败: $e');
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空所有聊天记录？'),
        content: const Text('此操作不可恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    await AppStateScope.of(context).clearAllMessages();
    _toast('已清空');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth > 720 ? 720 : double.infinity,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: _pickAvatar,
                          child: CircleAvatar(
                            radius: 38,
                            backgroundColor: LanChatTheme.mint,
                            backgroundImage: app.selfAvatar != null
                                ? FileImage(File(app.selfAvatar!))
                                : null,
                            child: app.selfAvatar == null
                                ? const Icon(Icons.person, size: 38)
                                : null,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '个人资料',
                                style: TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _nameCtrl,
                                decoration: const InputDecoration(
                                  hintText: '输入昵称',
                                  isDense: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: '保存昵称',
                          onPressed: () async {
                            await app.setSelfName(_nameCtrl.text);
                            _toast('昵称已保存');
                          },
                          icon: const Icon(Icons.check),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  '数据与文件',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      const ListTile(
                        leading: Icon(Icons.folder_outlined),
                        title: Text('应用专用文件目录'),
                        subtitle: Text(
                          '接收文件由 LanChat 管理，避免路径穿越和误覆盖。'
                          '需要取出文件时，在聊天中使用“另存为”。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.file_download_outlined),
                        title: const Text('导出聊天记录'),
                        subtitle: const Text('导出 JSON 和文本，内容为明文'),
                        onTap: _export,
                      ),
                      ListTile(
                        leading: const Icon(
                          Icons.delete_forever_outlined,
                          color: Colors.red,
                        ),
                        title: const Text('清空聊天记录'),
                        subtitle: const Text('同时删除已接收文件和未完成传输'),
                        onTap: _clear,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  '局域网连接',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '本机地址（多网卡可任选一个）:\n'
                      '${app.selfIps.isEmpty ? '未连接网络' : app.selfIps.join('\n')}\n'
                      'TCP 端口: ${app.tcpPort}\n\n'
                      '对方输入 IP 和端口后发起配对。配对并核对六位数字后，'
                      '聊天与文件才会加密传输。\n\n'
                      '纯局域网 P2P，无服务器',
                      style: TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
