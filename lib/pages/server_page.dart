import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../services/app_state.dart';
import '../services/notification_service.dart';
import '../services/notification_service_factory.dart';
import '../services/remote_matrix_service.dart';
import '../services/remote_message_adapter.dart';
import '../services/server_api_service.dart';
import '../services/server_profile.dart';
import '../services/server_profile_store.dart';
import '../widgets/chat_theme.dart';
import 'server_chat_page.dart';

class ServerPage extends StatefulWidget {
  const ServerPage({super.key});

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  late final LocalNotificationService _notificationService;
  late final RemoteMatrixService _service;
  late final ServerApiService _api;
  bool _ownsNotificationService = false;
  final _profilesStore = ServerProfileStore();
  final _searchController = TextEditingController();
  StreamSubscription<RemoteMessage>? _messageSubscription;
  List<ServerProfile> _profiles = [];
  List<RemoteUser> _users = [];
  ServerProfile? _selected;
  String? _error;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    final sharedNotifications = AppStateScope.of(context).notificationService;
    if (sharedNotifications == null) {
      _notificationService = createDefaultLocalNotificationService();
      _ownsNotificationService = true;
      unawaited(_notificationService.initialize());
    } else {
      _notificationService = sharedNotifications;
    }
    _service = RemoteMatrixService(notificationService: _notificationService);
    _api = ServerApiService();
    _messageSubscription = _service.onMessage.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_restore());
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _searchController.dispose();
    _service.dispose();
    if (_ownsNotificationService) {
      unawaited(_notificationService.dispose());
    }
    super.dispose();
  }

  Future<void> _restore() async {
    final profiles = await _profilesStore.load();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _selected = profiles.isEmpty ? null : profiles.first;
    });
    final profile = _selected;
    if (profile == null) return;
    final password = await _profilesStore.passwordFor(profile.id);
    final accessCode = await _profilesStore.accessCodeFor(profile.id);
    if (!mounted || password == null) return;
    await _connectStored(profile, password, accessCode);
  }

  Future<void> _connect(
    ServerProfile profile,
    String password,
    String? accessCode, {
    String? matrixAccessToken,
    String? matrixUserId,
    String? matrixDeviceId,
  }) async {
    setState(() => _error = null);
    try {
      await _service.connect(
        profile,
        password: password,
        accessCode: accessCode,
        matrixAccessToken: matrixAccessToken,
        matrixUserId: matrixUserId,
        matrixDeviceId: matrixDeviceId,
      );
      if (mounted) {
        setState(() {
          _selected = profile;
          _error = null;
        });
        await _searchUsers();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _connectAccount(ServerProfile profile, String password) async {
    setState(() => _error = null);
    try {
      final result = await _api.login(
        profile,
        username: profile.username,
        password: password,
        deviceId: _deviceId(profile),
      );
      if (result.status == ServerLoginStatus.devicePending) {
        if (mounted) {
          setState(() => _error = '这台设备正在等待管理员审批。');
        }
        return;
      }
      if (result.status != ServerLoginStatus.authenticated) {
        throw RemoteServerException('服务器账号暂时无法使用。');
      }
      if (result.token != null) {
        await _profilesStore.save(
          profile,
          password: password,
          sessionToken: result.token,
        );
      }
      await _connect(
        profile,
        password,
        null,
        matrixAccessToken: result.matrixAccessToken,
        matrixUserId: result.matrixUserId,
        matrixDeviceId: result.matrixDeviceId,
      );
    } on ServerApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _connectStored(
    ServerProfile profile,
    String password,
    String? accessCode,
  ) async {
    if (accessCode != null && accessCode.isNotEmpty) {
      await _connect(profile, password, accessCode);
      return;
    }
    final requestId = profile.pendingRequestId;
    if (requestId != null) {
      try {
        final status = await _api.joinStatus(profile, requestId);
        if (status.status == 'pending') {
          if (mounted) setState(() => _error = '申请仍在等待管理员审批。');
          return;
        }
        if (status.status == 'rejected') {
          if (mounted) setState(() => _error = '这次入群申请已被拒绝。');
          return;
        }
        final ready = profile.withoutPendingRequest();
        await _profilesStore.save(ready, password: password);
        if (mounted) {
          setState(() {
            _selected = ready;
            _profiles = [
              ready,
              ..._profiles.where((item) => item.id != ready.id),
            ];
          });
        }
        await _connectAccount(ready, password);
        return;
      } on ServerApiException catch (error) {
        if (mounted) setState(() => _error = error.message);
        return;
      }
    }
    await _connectAccount(profile, password);
  }

  String _deviceId(ServerProfile profile) {
    final id = AppStateScope.of(context).selfId.trim();
    return id.isEmpty ? profile.id : id;
  }

  Future<void> _addServer() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _AddServerDialog(),
    );
    if (result == null) return;
    try {
      final profile = ServerProfile(
        id: 'server-${DateTime.now().millisecondsSinceEpoch}',
        name: result['name']!.isEmpty ? result['url']! : result['name']!,
        baseUrl: result['url']!,
        username: result['username']!,
      );
      final inviteCode = result['inviteCode']!;
      final legacyAccessCode = result['accessCode']!;
      await _profilesStore.save(
        profile,
        password: result['password']!,
        accessCode: legacyAccessCode.isEmpty ? null : legacyAccessCode,
        inviteCode: inviteCode.isEmpty ? null : inviteCode,
      );
      final profiles = await _profilesStore.load();
      if (!mounted) return;
      setState(() => _profiles = profiles);
      if (inviteCode.isNotEmpty) {
        final join = await _api.submitJoin(
          profile,
          inviteCode: inviteCode,
          username: result['username']!,
          password: result['password']!,
          displayName: result['displayName']!,
          deviceId: _deviceId(profile),
        );
        final pendingProfile = ServerProfile(
          id: profile.id,
          name: profile.name,
          baseUrl: profile.baseUrl,
          username: profile.username,
          pendingRequestId: join.requestId,
        );
        await _profilesStore.save(
          pendingProfile,
          password: result['password']!,
          inviteCode: inviteCode,
        );
        if (mounted) {
          setState(() {
            _selected = pendingProfile;
            _profiles = [
              pendingProfile,
              ..._profiles.where((item) => item.id != pendingProfile.id),
            ];
            _error = '申请已提交，等待管理员审批。申请编号：${join.requestId}';
          });
        }
      } else if (legacyAccessCode.isNotEmpty) {
        await _connect(profile, result['password']!, legacyAccessCode);
      } else {
        await _connectAccount(profile, result['password']!);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _switchServer(ServerProfile profile) async {
    final password = await _profilesStore.passwordFor(profile.id);
    final accessCode = await _profilesStore.accessCodeFor(profile.id);
    if (password == null) {
      setState(() => _error = '这个服务器缺少登录信息');
      return;
    }
    await _connectStored(profile, password, accessCode);
  }

  Future<void> _searchUsers() async {
    if (_searching || !_service.isConnected) return;
    setState(() => _searching = true);
    try {
      final users = await _service.searchUsers(_searchController.text);
      if (mounted) setState(() => _users = users);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _showUserAction(RemoteUser user) async {
    if (!_service.isConnected) return;
    final room = _service.directRoomForUser(user.userId);
    if (room != null) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ServerChatPage(
            service: _service,
            roomId: room.id,
            title: user.displayName,
          ),
        ),
      );
      return;
    }
    final send = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(user.displayName),
        content: Text('@${user.username}\n发送好友申请后，需对方同意才能聊天。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('发送申请'),
          ),
        ],
      ),
    );
    if (send != true) return;
    try {
      await _service.sendFriendRequest(user);
      if (mounted) _toast('好友申请已发送');
    } catch (error) {
      if (mounted) _toast('发送失败：$error');
    }
  }

  Future<void> _openRoom(Room room) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ServerChatPage(
          service: _service,
          roomId: room.id,
          title: room.getLocalizedDisplayname(),
        ),
      ),
    );
  }

  Future<void> _acceptRequest(RemoteFriendRequest request) async {
    try {
      await _service.acceptFriendRequest(request.roomId);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _toast('操作失败：$error');
    }
  }

  Future<void> _rejectRequest(RemoteFriendRequest request) async {
    try {
      await _service.rejectFriendRequest(request.roomId);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _toast('操作失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _service.isConnected;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('服务器'),
            const SizedBox(width: 10),
            _connectionPill(connected),
          ],
        ),
        actions: [
          if (_profiles.isNotEmpty)
            PopupMenuButton<ServerProfile>(
              tooltip: '切换服务器',
              onSelected: _switchServer,
              itemBuilder: (_) => [
                ..._profiles.map(
                  (profile) =>
                      PopupMenuItem(value: profile, child: Text(profile.name)),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: null,
                  enabled: false,
                  child: Text('服务器配置保存在本机'),
                ),
              ],
              icon: const Icon(Icons.dns_outlined),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addServer,
        icon: const Icon(Icons.add),
        label: const Text('添加服务器'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth > 760 ? 760 : double.infinity,
            ),
            child: connected ? _connectedBody() : _offlineBody(),
          ),
        ),
      ),
    );
  }

  Widget _connectedBody() {
    final requests = _service.incomingFriendRequests;
    final rooms = _service.rooms.where(
      (room) => room.membership == Membership.join,
    );
    final capabilities = _service.capabilities;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 100),
      children: [
        if (capabilities != null)
          Card(
            color: capabilities.e2ee
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
              leading: Icon(
                capabilities.e2ee ? Icons.lock_outline : Icons.lock_open,
              ),
              title: Text(capabilities.e2ee ? '端到端加密已启用' : '服务器可读取消息内容'),
              subtitle: Text(
                '${capabilities.serverName} · 图片上限 ${_formatBytes(capabilities.maxImageBytes)}',
              ),
            ),
          ),
        if (requests.isNotEmpty) ...[
          const Text('好友申请', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...requests.map(_requestCard),
          const SizedBox(height: 18),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
            child: TextField(
              controller: _searchController,
              onSubmitted: (_) => _searchUsers(),
              decoration: InputDecoration(
                icon: const Icon(Icons.search),
                hintText: '搜索服务器用户',
                border: InputBorder.none,
                suffixIcon: IconButton(
                  onPressed: _searching ? null : _searchUsers,
                  icon: _searching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward),
                ),
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_users.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Text('用户', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ..._users.map(_userCard),
        ],
        if (rooms.isNotEmpty) ...[
          const SizedBox(height: 22),
          const Text('我的远程聊天', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...rooms.map(
            (room) => Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text(room.getLocalizedDisplayname()),
                subtitle: Text(room.lastEvent?.body ?? '暂无消息'),
                onTap: () => _openRoom(room),
              ),
            ),
          ),
        ],
        if (_users.isEmpty && requests.isEmpty && rooms.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 80),
            child: Center(child: Text('搜索用户后发送好友申请')),
          ),
      ],
    );
  }

  Widget _offlineBody() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              children: [
                const Icon(Icons.cloud_off, size: 48, color: LanChatTheme.jade),
                const SizedBox(height: 12),
                Text(
                  _profiles.isEmpty ? '连接一个自建服务器' : '服务器尚未连接',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _error ?? '服务器版仍然可以正常使用局域网聊天。登录服务器后可发送远程文字和图片。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _addServer,
                  icon: const Icon(Icons.add),
                  label: const Text('添加服务器'),
                ),
                if (_selected != null) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => _switchServer(_selected!),
                    icon: const Icon(Icons.refresh),
                    label: const Text('检查当前服务器'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _connectionPill(bool connected) {
    final color = connected ? LanChatTheme.jade : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        connected ? '已连接' : '未连接',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _userCard(RemoteUser user) {
    final friend = _service.isFriend(user.userId);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: LanChatTheme.mint,
          foregroundColor: LanChatTheme.jadeDark,
          child: Text(
            user.displayName.isEmpty ? '?' : user.displayName.characters.first,
          ),
        ),
        title: Text(user.displayName),
        subtitle: Text('@${user.username} · ${user.isOnline ? '在线' : '离线'}'),
        trailing: friend
            ? const Icon(Icons.chat_bubble_outline)
            : const Icon(Icons.person_add_alt_1),
        onTap: () => _showUserAction(user),
      ),
    );
  }

  Widget _requestCard(RemoteFriendRequest request) {
    return Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person_add_outlined)),
        title: Text(request.displayName),
        subtitle: const Text('请求添加你为好友'),
        trailing: Wrap(
          children: [
            IconButton(
              tooltip: '拒绝',
              onPressed: () => _rejectRequest(request),
              icon: const Icon(Icons.close),
            ),
            IconButton(
              tooltip: '同意',
              onPressed: () => _acceptRequest(request),
              icon: const Icon(Icons.check, color: LanChatTheme.jade),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

class _AddServerDialog extends StatefulWidget {
  const _AddServerDialog();

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<_AddServerDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController(text: 'https://');
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _inviteCode = TextEditingController();
  final _accessCode = TextEditingController();
  bool _isInsecureUrl = false;

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

  void _submit() {
    if ([
      _url,
      _username,
      _password,
    ].any((controller) => controller.text.trim().isEmpty)) {
      return;
    }
    Navigator.pop(context, {
      'name': _name.text.trim(),
      'url': _url.text.trim(),
      'username': _username.text.trim(),
      'displayName': _displayName.text.trim().isEmpty
          ? _username.text.trim()
          : _displayName.text.trim(),
      'password': _password.text,
      'inviteCode': _inviteCode.text.trim(),
      'accessCode': _accessCode.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加自建服务器'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: _url,
              onChanged: (value) {
                final uri = Uri.tryParse(value.trim());
                setState(() => _isInsecureUrl = uri?.scheme == 'http');
              },
              decoration: const InputDecoration(labelText: '服务器地址（IP 或域名）'),
            ),
            if (_isInsecureUrl)
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '当前使用 HTTP，登录信息可能被同一网络中的其他人看到。',
                    style: TextStyle(color: Colors.deepOrange, fontSize: 12),
                  ),
                ),
              ),
            TextField(
              controller: _username,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            TextField(
              controller: _displayName,
              decoration: const InputDecoration(labelText: '昵称'),
            ),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '用户密码'),
            ),
            TextField(
              controller: _inviteCode,
              obscureText: true,
              decoration: const InputDecoration(labelText: '邀请码'),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text('兼容旧版服务器'),
              subtitle: const Text('新服务器不需要填写接入码'),
              children: [
                TextField(
                  controller: _accessCode,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '旧版服务器接入码（可选）'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('连接')),
      ],
    );
  }
}
