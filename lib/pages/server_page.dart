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
import '../widgets/server_profile_editor.dart';
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
  final _statusByProfile = <String, ServerProbeResult>{};
  final _checkingProfiles = <String>{};
  StreamSubscription<RemoteMessage>? _messageSubscription;
  Timer? _statusTimer;
  List<ServerProfile> _profiles = [];
  List<RemoteUser> _users = [];
  ServerProfile? _selected;
  String? _error;
  String? _connectingProfileId;
  bool _searching = false;
  bool _refreshingStatuses = false;

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
    _statusTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_refreshAllStatuses()),
    );
    unawaited(_restore());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
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
    final selectedId = await _profilesStore.selectedProfileId();
    if (!mounted) return;
    final selected =
        _findProfile(profiles, selectedId) ??
        (profiles.isEmpty ? null : profiles.first);
    setState(() {
      _profiles = profiles;
      _selected = selected;
    });
    if (selected != null) {
      await _profilesStore.setSelectedProfileId(selected.id);
      unawaited(_probeProfile(selected));
      final password = await _profilesStore.passwordFor(selected.id);
      final accessCode = await _profilesStore.accessCodeFor(selected.id);
      if (!mounted || password == null) return;
      await _connectStored(selected, password, accessCode);
    } else {
      unawaited(_refreshAllStatuses());
    }
  }

  ServerProfile? _findProfile(List<ServerProfile> profiles, String? profileId) {
    if (profileId == null) return null;
    for (final profile in profiles) {
      if (profile.id == profileId) return profile;
    }
    return null;
  }

  Future<void> _refreshAllStatuses() async {
    if (_refreshingStatuses || _profiles.isEmpty) return;
    _refreshingStatuses = true;
    final profiles = List<ServerProfile>.of(_profiles);
    try {
      final results = await Future.wait(
        profiles.map(
          (profile) async => MapEntry(profile.id, await _api.probe(profile)),
        ),
      );
      if (!mounted) return;
      setState(() {
        for (final result in results) {
          _statusByProfile[result.key] = result.value;
        }
      });
    } finally {
      _refreshingStatuses = false;
    }
  }

  Future<void> _probeProfile(ServerProfile profile) async {
    if (_checkingProfiles.contains(profile.id)) return;
    if (mounted) setState(() => _checkingProfiles.add(profile.id));
    try {
      final result = await _api.probe(profile);
      if (mounted) {
        setState(() => _statusByProfile[profile.id] = result);
      }
    } finally {
      if (mounted) setState(() => _checkingProfiles.remove(profile.id));
    }
  }

  Future<void> _selectProfile(ServerProfile profile) async {
    if (_selected?.id == profile.id) return;
    await _service.disconnect();
    if (!mounted) return;
    setState(() {
      _selected = profile;
      _users = [];
      _error = null;
    });
    await _profilesStore.setSelectedProfileId(profile.id);
    await _probeProfile(profile);
    final password = await _profilesStore.passwordFor(profile.id);
    final accessCode = await _profilesStore.accessCodeFor(profile.id);
    if (!mounted || password == null) {
      if (mounted) setState(() => _error = '这个服务器缺少登录信息，请编辑服务器配置。');
      return;
    }
    await _connectStored(profile, password, accessCode);
  }

  Future<void> _connect(
    ServerProfile profile,
    String password,
    String? accessCode, {
    String? serverSessionToken,
    String? matrixAccessToken,
    String? matrixUserId,
    String? matrixDeviceId,
  }) async {
    if (!mounted) return;
    setState(() {
      _error = null;
      _connectingProfileId = profile.id;
      _selected = profile;
    });
    await _profilesStore.setSelectedProfileId(profile.id);
    try {
      await _service.connect(
        profile,
        password: password,
        accessCode: accessCode,
        serverSessionToken: serverSessionToken,
        matrixAccessToken: matrixAccessToken,
        matrixUserId: matrixUserId,
        matrixDeviceId: matrixDeviceId,
      );
      if (mounted) {
        setState(() => _error = null);
        await _searchUsers();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _connectingProfileId = null);
    }
  }

  Future<void> _connectAccount(ServerProfile profile, String password) async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final result = await _api.login(
        profile,
        username: profile.username,
        password: password,
        deviceId: _deviceId(profile),
      );
      if (result.status == ServerLoginStatus.devicePending) {
        if (mounted) setState(() => _error = '这台设备正在等待管理员审批。');
        return;
      }
      if (result.status != ServerLoginStatus.authenticated) {
        throw RemoteServerException('服务器账号暂时无法使用。');
      }
      await _profilesStore.save(
        profile,
        password: password,
        inviteCode: '',
        sessionToken: result.token,
      );
      await _connect(
        profile,
        password,
        null,
        serverSessionToken: result.token,
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
        await _profilesStore.save(
          ready,
          password: password,
          inviteCode: '',
          sessionToken: '',
        );
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

  Future<void> _openEditor([ServerProfile? existing]) async {
    final password = existing == null
        ? null
        : await _profilesStore.passwordFor(existing.id);
    final inviteCode = existing == null
        ? null
        : await _profilesStore.inviteCodeFor(existing.id);
    final accessCode = existing == null
        ? null
        : await _profilesStore.accessCodeFor(existing.id);
    if (!mounted) return;
    final draft = await showDialog<ServerProfileDraft>(
      context: context,
      builder: (_) => ServerProfileEditor(
        profile: existing,
        password: password,
        inviteCode: inviteCode,
        accessCode: accessCode,
      ),
    );
    if (draft == null) return;
    await _applyDraft(existing, password, draft);
  }

  Future<void> _applyDraft(
    ServerProfile? existing,
    String? existingPassword,
    ServerProfileDraft draft,
  ) async {
    final password = draft.password.isEmpty ? existingPassword : draft.password;
    if (password == null || password.isEmpty) {
      if (mounted) setState(() => _error = '请输入密码后再保存服务器。');
      return;
    }
    try {
      final normalizedUrl = ServerProfile.normalizeBaseUrl(draft.baseUrl);
      final name = _profileName(draft.name, normalizedUrl);
      final id =
          existing?.id ?? 'server-${DateTime.now().millisecondsSinceEpoch}';
      final connectionChanged =
          existing != null &&
          (existing.baseUrl != normalizedUrl ||
              existing.username != draft.username);
      final profile = ServerProfile(
        id: id,
        name: name,
        baseUrl: normalizedUrl,
        username: draft.username,
        pendingRequestId: connectionChanged ? null : existing?.pendingRequestId,
      );
      final probe = await _api.probe(profile);
      if (probe.state == ServerProbeState.offline) {
        throw RemoteServerException(probe.message ?? '服务器当前无法连接，请检查地址和端口。');
      }
      if (existing?.pendingRequestId != null && !connectionChanged) {
        await _profilesStore.save(
          profile,
          password: password,
          accessCode: draft.accessCode,
          inviteCode: draft.inviteCode,
          sessionToken: '',
        );
        await _replaceProfile(profile);
        if (mounted) {
          setState(() => _error = '服务器配置已保存，当前申请仍在审批中。');
        }
        return;
      }
      if (existing?.id == _selected?.id && _service.isConnected) {
        await _service.disconnect();
      }
      await _profilesStore.save(
        profile,
        password: password,
        accessCode: draft.accessCode,
        inviteCode: draft.inviteCode,
        sessionToken: connectionChanged ? '' : null,
      );
      await _replaceProfile(profile);
      if (draft.isJoining) {
        final join = await _api.submitJoin(
          profile,
          inviteCode: draft.inviteCode,
          username: draft.username,
          password: password,
          displayName: draft.displayName,
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
          password: password,
          inviteCode: draft.inviteCode,
          accessCode: '',
          sessionToken: '',
        );
        await _replaceProfile(pendingProfile);
        if (mounted) {
          setState(() {
            _selected = pendingProfile;
            _error = '申请已提交，等待管理员审批。';
          });
        }
      } else if (draft.accessCode.isNotEmpty) {
        await _connect(profile, password, draft.accessCode);
      } else {
        await _connectAccount(profile, password);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _replaceProfile(ServerProfile profile) async {
    if (!mounted) return;
    setState(() {
      _profiles = [
        profile,
        ..._profiles.where((item) => item.id != profile.id),
      ];
      _selected = profile;
    });
    await _profilesStore.setSelectedProfileId(profile.id);
    unawaited(_probeProfile(profile));
  }

  String _profileName(String rawName, String baseUrl) {
    final name = rawName.trim();
    if (name.isNotEmpty) return name;
    final uri = Uri.parse(baseUrl);
    final fallback = uri.authority.isEmpty ? baseUrl : uri.authority;
    final runes = fallback.runes.toList();
    return String.fromCharCodes(runes.take(64));
  }

  Future<void> _deleteProfile(ServerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除服务器配置？'),
        content: Text('将从本机删除“${profile.name}”的账号凭据和远程缓存。服务器上的数据不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_selected?.id == profile.id) await _service.disconnect();
    await _service.clearProfileData(profile.id);
    await _profilesStore.remove(profile.id);
    final profiles = await _profilesStore.load();
    if (!mounted) return;
    final next = profiles.isEmpty ? null : profiles.first;
    setState(() {
      _profiles = profiles;
      _selected = next;
      _users = [];
      _error = null;
    });
    if (next != null) {
      await _profilesStore.setSelectedProfileId(next.id);
      final password = await _profilesStore.passwordFor(next.id);
      final accessCode = await _profilesStore.accessCodeFor(next.id);
      if (password != null) await _connectStored(next, password, accessCode);
    }
  }

  Future<void> _connectSelected() async {
    final profile = _selected;
    if (profile == null) return;
    final password = await _profilesStore.passwordFor(profile.id);
    final accessCode = await _profilesStore.accessCodeFor(profile.id);
    if (password == null) {
      if (mounted) setState(() => _error = '这个服务器缺少登录信息，请编辑服务器配置。');
      return;
    }
    await _connectStored(profile, password, accessCode);
  }

  Future<void> _disconnect() async {
    await _service.disconnect();
    if (mounted) setState(() => _users = []);
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
    final friendState = _service.friendStateForUser(user.userId);
    final room = _service.directRoomForUser(user.userId);
    if (friendState == RemoteFriendState.friends && room != null) {
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
    if (friendState == RemoteFriendState.friends) {
      if (mounted) _toast('好友会话还没有同步完成，请稍后再试。');
      return;
    }
    if (friendState == RemoteFriendState.outgoingPending) {
      if (mounted) _toast('好友申请已经发送，等待对方同意。');
      return;
    }
    if (friendState == RemoteFriendState.incomingPending) {
      if (mounted) _toast('对方已经向你发送申请，请在上方处理。');
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
      if (mounted) {
        _toast('好友申请已发送');
        await _searchUsers();
      }
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
      if (mounted) {
        setState(() {});
        await _searchUsers();
      }
    } catch (error) {
      if (mounted) _toast('操作失败：$error');
    }
  }

  Future<void> _rejectRequest(RemoteFriendRequest request) async {
    try {
      await _service.rejectFriendRequest(request.roomId);
      if (mounted) {
        setState(() {});
        await _searchUsers();
      }
    } catch (error) {
      if (mounted) _toast('操作失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器'),
        actions: [
          IconButton(
            tooltip: '刷新服务器状态',
            onPressed: _refreshAllStatuses,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openEditor,
        icon: const Icon(Icons.add),
        label: const Text('添加服务器'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 310, child: _serverListPane()),
                const VerticalDivider(width: 1),
                Expanded(child: _serverDetailPane()),
              ],
            );
          }
          return Column(
            children: [
              SizedBox(height: 300, child: _serverListPane(compact: true)),
              Expanded(child: _serverDetailPane()),
            ],
          );
        },
      ),
    );
  }

  Widget _serverListPane({bool compact = false}) {
    return Card(
      margin: EdgeInsets.fromLTRB(compact ? 12 : 16, 16, compact ? 12 : 8, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '我的服务器',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '添加服务器',
                  onPressed: _openEditor,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            Text(
              _profiles.isEmpty
                  ? '添加一个服务器后，它会一直保存在这里。'
                  : '${_profiles.length} 个服务器配置',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _profiles.isEmpty
                  ? _emptyServerList()
                  : ListView.separated(
                      itemCount: _profiles.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (_, index) =>
                          _serverListItem(_profiles[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyServerList() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 36,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 8),
          const Text('还没有服务器'),
          const SizedBox(height: 4),
          Text(
            '地址、账号和申请状态都会集中显示。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _serverListItem(ServerProfile profile) {
    final selected = _selected?.id == profile.id;
    final checking = _checkingProfiles.contains(profile.id);
    final status = _statusLabel(profile, checking: checking);
    final color = _statusColor(profile, checking: checking);
    return Material(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _selectProfile(profile),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${profile.uri.authority} · $status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_ServerAction>(
                tooltip: '管理服务器',
                onSelected: (action) {
                  switch (action) {
                    case _ServerAction.edit:
                      _openEditor(profile);
                    case _ServerAction.delete:
                      _deleteProfile(profile);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _ServerAction.edit,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('编辑'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _ServerAction.delete,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline),
                      title: Text('删除'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _serverDetailPane() {
    final profile = _selected;
    if (profile == null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [_emptyDetail()],
      );
    }
    final connected =
        _service.isConnected && _service.profile?.id == profile.id;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
      children: [
        _detailHeader(profile, connected),
        if (_error != null) ...[
          const SizedBox(height: 10),
          _errorBanner(_error!),
        ],
        const SizedBox(height: 12),
        if (connected) ..._connectedContent() else ..._offlineContent(profile),
      ],
    );
  }

  Widget _emptyDetail() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            const Icon(Icons.cloud_queue_outlined, size: 52),
            const SizedBox(height: 12),
            const Text(
              '选择一个服务器',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '服务器状态、账号状态和可用操作会显示在这里。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailHeader(ServerProfile profile, bool connected) {
    final checking = _checkingProfiles.contains(profile.id);
    final status = _statusLabel(
      profile,
      checking: checking,
      connected: connected,
    );
    final color = _statusColor(
      profile,
      checking: checking,
      connected: connected,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 10, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        profile.baseUrl,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<_ServerAction>(
                  tooltip: '管理服务器',
                  onSelected: (action) => action == _ServerAction.edit
                      ? _openEditor(profile)
                      : _deleteProfile(profile),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: _ServerAction.edit,
                      child: Text('编辑服务器'),
                    ),
                    PopupMenuItem(
                      value: _ServerAction.delete,
                      child: Text('删除服务器'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  status,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
                if (_statusByProfile[profile.id]?.checkedAt != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    '检查于 ${_statusTime(_statusByProfile[profile.id]!.checkedAt)}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
                const Spacer(),
                if (connected)
                  OutlinedButton.icon(
                    onPressed: _disconnect,
                    icon: const Icon(Icons.link_off, size: 17),
                    label: const Text('断开'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _connectingProfileId == null
                        ? _connectSelected
                        : null,
                    icon: const Icon(Icons.link, size: 17),
                    label: const Text('连接'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _offlineContent(ServerProfile profile) {
    final status = _statusByProfile[profile.id];
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            children: [
              Icon(
                profile.pendingRequestId == null
                    ? Icons.cloud_off_outlined
                    : Icons.hourglass_empty,
                size: 42,
                color: profile.pendingRequestId == null
                    ? LanChatTheme.jade
                    : Colors.orange,
              ),
              const SizedBox(height: 12),
              Text(
                profile.pendingRequestId == null ? '服务器尚未连接' : '入群申请等待审批',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                profile.pendingRequestId != null
                    ? '管理员通过申请后，点击连接即可继续。'
                    : status?.message ?? '可以编辑服务器配置，或重新检测连接。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _openEditor(profile),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('编辑配置'),
                  ),
                  TextButton.icon(
                    onPressed: () => _probeProfile(profile),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新检测'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _connectedContent() {
    final requests = _service.incomingFriendRequests;
    final rooms = _service.rooms.where(
      (room) => room.membership == Membership.join,
    );
    final capabilities = _service.capabilities;
    return [
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
              '${capabilities.serverName} · 图片 ${_formatBytes(capabilities.maxImageBytes)} · 文件 ${_formatBytes(capabilities.maxFileBytes)}',
            ),
          ),
        ),
      if (requests.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('好友申请', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ...requests.map(_requestCard),
      ],
      const SizedBox(height: 12),
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
      if (_users.isNotEmpty) ...[
        const SizedBox(height: 14),
        Row(
          children: [
            const Expanded(
              child: Text(
                '服务器用户',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${_users.length} 人',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ..._users.map(_userCard),
      ],
      if (rooms.isNotEmpty) ...[
        const SizedBox(height: 18),
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
          padding: EdgeInsets.only(top: 60),
          child: Center(child: Text('服务器用户会显示在这里。')),
        ),
    ];
  }

  Widget _errorBanner(String message) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );

  Widget _userCard(RemoteUser user) {
    final friendState = user.friendState;
    final relation = switch (friendState) {
      RemoteFriendState.friends => '已是好友',
      RemoteFriendState.outgoingPending => '申请中',
      RemoteFriendState.incomingPending => '待处理',
      RemoteFriendState.none => '未添加',
    };
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
        subtitle: Text(
          '@${user.username} · ${user.isOnline ? '在线' : '离线'} · $relation',
        ),
        trailing: switch (friendState) {
          RemoteFriendState.friends => const Icon(Icons.chat_bubble_outline),
          RemoteFriendState.outgoingPending => const Icon(
            Icons.hourglass_top_outlined,
          ),
          RemoteFriendState.incomingPending => const Icon(
            Icons.mark_email_unread_outlined,
          ),
          RemoteFriendState.none => const Icon(Icons.person_add_alt_1),
        },
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

  String _statusLabel(
    ServerProfile profile, {
    bool checking = false,
    bool connected = false,
  }) {
    if (connected) return '已连接';
    if (_connectingProfileId == profile.id) return '连接中';
    if (profile.pendingRequestId != null) return '申请待审批';
    if (checking) return '检测中';
    final result = _statusByProfile[profile.id];
    if (result == null) return '未检测';
    return result.state == ServerProbeState.online ? '在线' : '离线';
  }

  Color _statusColor(
    ServerProfile profile, {
    bool checking = false,
    bool connected = false,
  }) {
    if (connected ||
        (!checking &&
            _statusByProfile[profile.id]?.state == ServerProbeState.online)) {
      return LanChatTheme.jade;
    }
    if (profile.pendingRequestId != null || checking) return Colors.orange;
    return Theme.of(context).colorScheme.outline;
  }

  String _statusTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

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

enum _ServerAction { edit, delete }
