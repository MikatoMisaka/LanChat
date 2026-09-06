import 'package:flutter/material.dart';

import '../services/server_form_validator.dart';
import '../services/server_profile.dart';

class ServerProfileDraft {
  const ServerProfileDraft({
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.displayName,
    required this.password,
    required this.inviteCode,
    required this.accessCode,
    required this.isJoining,
  });

  final String name;
  final String baseUrl;
  final String username;
  final String displayName;
  final String password;
  final String inviteCode;
  final String accessCode;
  final bool isJoining;
}

class ServerProfileEditor extends StatefulWidget {
  const ServerProfileEditor({
    super.key,
    this.profile,
    this.password,
    this.inviteCode,
    this.accessCode,
  });

  final ServerProfile? profile;
  final String? password;
  final String? inviteCode;
  final String? accessCode;

  @override
  State<ServerProfileEditor> createState() => _ServerProfileEditorState();
}

class _ServerProfileEditorState extends State<ServerProfileEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.profile?.baseUrl ?? 'https://',
  );
  late final TextEditingController _username = TextEditingController(
    text: widget.profile?.username ?? '',
  );
  late final TextEditingController _displayName = TextEditingController(
    text: widget.profile?.username ?? '',
  );
  late final TextEditingController _password = TextEditingController(
    text: widget.password ?? '',
  );
  late final TextEditingController _inviteCode = TextEditingController(
    text: widget.inviteCode ?? '',
  );
  late final TextEditingController _accessCode = TextEditingController(
    text: widget.accessCode ?? '',
  );

  late bool _isJoining =
      widget.profile == null ||
      widget.profile?.pendingRequestId != null ||
      widget.inviteCode?.isNotEmpty == true;
  Map<ServerFormField, String> _errors = {};

  bool get _editing => widget.profile != null;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    _inviteCode.dispose();
    _accessCode.dispose();
    super.dispose();
  }

  Map<ServerFormField, String> _validate() => ServerFormValidator.validate(
    baseUrl: _url.text,
    username: _username.text,
    password: _password.text,
    displayName: _displayName.text,
    inviteCode: _inviteCode.text,
    isJoining: _isJoining,
    passwordRequired: !_editing || _password.text.isNotEmpty,
  );

  void _refreshErrors() {
    final errors = _validate();
    if (mounted) setState(() => _errors = errors);
  }

  String? _error(ServerFormField field) => _errors[field];

  void _submit() {
    final errors = _validate();
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    Navigator.of(context).pop(
      ServerProfileDraft(
        name: _name.text.trim(),
        baseUrl: _url.text.trim(),
        username: _username.text.trim().toLowerCase(),
        displayName: _displayName.text.trim(),
        password: _password.text,
        inviteCode: _inviteCode.text.trim(),
        accessCode: _accessCode.text.trim(),
        isJoining: _isJoining,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = (MediaQuery.sizeOf(context).height - bottomInset - 48)
        .clamp(1.0, 760.0)
        .toDouble();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 24, 26, 20),
          child: SingleChildScrollView(
            child: Form(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _editing ? '编辑服务器' : '添加服务器',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _editing
                        ? '修改后会保留这个服务器条目，不会再生成重复配置。'
                        : '保存一个服务器入口，之后可以随时编辑和切换。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle(context, '服务器信息'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '显示名称（可选）',
                      helperText: '留空时使用服务器地址作为名称。',
                    ),
                    onChanged: (_) => _refreshErrors(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: '服务器地址',
                      hintText:
                          'https://chat.example.com 或 http://192.168.1.10:8080',
                      errorText: _error(ServerFormField.baseUrl),
                    ),
                    onChanged: (_) => _refreshErrors(),
                  ),
                  if (_url.text.trim().toLowerCase().startsWith('http://'))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '当前使用 HTTP，登录信息可能被同一网络中的其他人看到。',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  _sectionTitle(context, '账号信息'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _username,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: '用户名',
                      hintText: '例如 alice_1',
                      errorText: _error(ServerFormField.username),
                    ),
                    onChanged: (_) => _refreshErrors(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _displayName,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: '昵称',
                      errorText: _error(ServerFormField.displayName),
                    ),
                    onChanged: (_) => _refreshErrors(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: '密码',
                      helperText: _editing
                          ? '8-128 位，可使用任意字符；留空表示保持原密码。'
                          : '8-128 位，可使用任意字符。',
                      errorText: _error(ServerFormField.password),
                    ),
                    onChanged: (_) => _refreshErrors(),
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle(context, '加入方式'),
                  const SizedBox(height: 12),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment<bool>(
                        value: true,
                        icon: Icon(Icons.person_add_alt_1),
                        label: Text('申请加入'),
                      ),
                      ButtonSegment<bool>(
                        value: false,
                        icon: Icon(Icons.login),
                        label: Text('登录已有账号'),
                      ),
                    ],
                    selected: {_isJoining},
                    onSelectionChanged: (selection) {
                      setState(() {
                        _isJoining = selection.first;
                        _errors = _validate();
                      });
                    },
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _inviteCode,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: _isJoining ? '邀请码（必填）' : '邀请码（可选）',
                      helperText: _isJoining
                          ? '邀请码只用于提交申请，不会直接授予成员资格。'
                          : '已有账号登录时可以留空。',
                      errorText: _error(ServerFormField.inviteCode),
                    ),
                    onChanged: (_) => _refreshErrors(),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('旧版服务器兼容'),
                    subtitle: const Text('新服务器不需要接入码'),
                    children: [
                      TextField(
                        controller: _accessCode,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: '旧版服务器接入码（可选）',
                          helperText: '只有旧版服务器仍使用这个字段。',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _submit,
                          icon: const Icon(Icons.check),
                          label: Text(_editing ? '保存并检测' : '保存服务器'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Row(
    children: [
      Container(
        width: 4,
        height: 18,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 8),
      Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    ],
  );
}
