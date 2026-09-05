import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/app_state.dart';
import '../services/secure_transport_service.dart';

class AddDevicePage extends StatefulWidget {
  const AddDevicePage({super.key});

  @override
  State<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<AddDevicePage> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '45679');
  String _status = '';
  bool _pairing = false;

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _pairWith(String ip, int port, {String? expectedPeerId}) async {
    if (_pairing) return;
    setState(() {
      _pairing = true;
      _status = '';
    });
    final app = AppStateScope.of(context);
    PairingAttempt? attempt;
    try {
      attempt = await app.requestPairing(
        ip,
        port,
        expectedPeerId: expectedPeerId,
      );
      if (!mounted) {
        await attempt.reject();
        return;
      }
      // 双方核对同一个六位数字，确认后才建立信任
      final ok = await _showVerifyDialog(attempt);
      if (ok == true) {
        await attempt.confirm();
        if (mounted) Navigator.pop(context);
      } else {
        await attempt.reject();
        if (mounted) setState(() => _status = '已取消配对');
      }
    } catch (e) {
      if (mounted) setState(() => _status = '配对失败：$e');
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  Future<bool?> _showVerifyDialog(PairingAttempt attempt) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('与「${attempt.peerName}」配对？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请核对两台设备显示的六位数字是否一致'),
            const SizedBox(height: 12),
            Text(
              attempt.verificationCode,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('不一致'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('一致，配对'),
          ),
        ],
      ),
    );
  }

  Future<void> _addByIp() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 0;
    final ipOk = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(ip);
    if (!ipOk) {
      setState(() => _status = 'IP 格式不对，例如 192.168.43.1');
      return;
    }
    if (port <= 0 || port > 65535) {
      setState(() => _status = '端口不对，请看对方 LanChat 的设置页');
      return;
    }
    await _pairWith(ip, port);
  }

  Future<void> _scan() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _ScannerPage()),
    );
    if (!mounted || result is! String) return;
    final parsed = AppState.parseQr(result);
    if (parsed == null) {
      setState(() => _status = '不是 LanChat 二维码');
      return;
    }
    final (id, _, port) = parsed;
    final uri = Uri.tryParse(result);
    final ip = uri?.queryParameters['ip']?.split(',').first.trim();
    if (ip == null || ip.isEmpty) {
      setState(() => _status = '二维码缺少可达地址');
      return;
    }
    await _pairWith(ip, port, expectedPeerId: id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加设备')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ipController,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: '对方 IP',
                hintText: '例如 192.168.43.1',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '对方端口',
                hintText: '默认 45679，一般不用改',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _pairing ? null : _addByIp,
              icon: const Icon(Icons.lan),
              label: Text(_pairing ? '正在配对…' : '发起配对'),
            ),
            const SizedBox(height: 24),
            if (!Platform.isWindows)
              OutlinedButton.icon(
                onPressed: _pairing ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫描对方二维码'),
              ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_status, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '配对需要双方核对同一个六位数字。配对完成后，聊天和文件'
                '都会加密传输，只有已配对设备可以通信。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool _popped = false;
  late final MobileScannerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      facing: CameraFacing.back,
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码')),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_popped) return;
          final raw = capture.barcodes.firstOrNull?.rawValue;
          if (raw != null && raw.isNotEmpty) {
            _popped = true;
            Navigator.pop(context, raw);
          }
        },
        errorBuilder: (context, error) {
          final isPerm =
              error.errorCode == MobileScannerErrorCode.permissionDenied;
          final detailStr = error.errorDetails?.message ?? '';
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isPerm
                        ? '相机权限被拒绝\n请在系统设置里允许 LanChat 使用相机'
                        : '相机启动失败\n错误码: ${error.errorCode.name}\n${detailStr.isNotEmpty ? '详情: $detailStr' : ''}\n\n可尝试：重启手机后再试',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                  ),
                  if (isPerm) ...[
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () =>
                          AppStateScope.of(context).openAppSettings(),
                      child: const Text('去系统设置开启'),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
