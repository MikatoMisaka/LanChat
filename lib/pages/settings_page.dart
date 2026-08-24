import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_state.dart';

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
      await Share.shareXFiles(
        [XFile(f1.path), XFile(f2.path)],
        text: 'LanChat 聊天记录',
      );
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
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    await AppStateScope.of(context).db.clearAllMessages();
    _toast('已清空');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _pickFilesDir() async {
    final app = AppStateScope.of(context);
    // Windows/桌面：file_picker 的目录选择器；移动端部分机型不可用，失败则提示
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    await app.setFilesDir(result);
    if (!mounted) return;
    _toast('已设置：$result');
  }

  Future<void> _resetFilesDir() async {
    final app = AppStateScope.of(context);
    await app.setFilesDir(null);
    if (!mounted) return;
    _toast('已恢复默认保存位置');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          Center(
            child: GestureDetector(
              onTap: _pickAvatar,
              child: CircleAvatar(
                radius: 40,
                backgroundImage: app.selfAvatar != null
                    ? FileImage(File(app.selfAvatar!))
                    : null,
                child: app.selfAvatar == null
                    ? const Icon(Icons.person, size: 40)
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text('点击更换头像',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text('昵称'),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(isDense: true),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await app.setSelfName(_nameCtrl.text.trim());
                    _toast('已保存');
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('接收文件保存位置'),
            subtitle: Text(
              app.filesBase.isEmpty ? '默认：应用文档目录' : app.filesBase,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            onTap: _pickFilesDir,
            trailing: app.filesBase.isEmpty
                ? null
                : TextButton(
                    onPressed: _resetFilesDir,
                    child: const Text('默认'),
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.file_download),
            title: const Text('导出聊天记录'),
            subtitle: const Text('导出 JSON 和文本，通过分享菜单保存'),
            onTap: _export,
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('清空聊天记录'),
            onTap: _clear,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '本机 IP（多网卡会列出全部，任选可达的一个）:\n'
              '${app.selfIps.isEmpty ? '未连接网络' : app.selfIps.join('\n')}\n'
              'TCP 端口: ${app.tcpPort}\n'
              '让对方在「添加设备」中输入以上任一 IP 和端口即可连接\n'
              '纯局域网 P2P，无服务器',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
