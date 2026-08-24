import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/app_state.dart';

class AddDevicePage extends StatefulWidget {
  const AddDevicePage({super.key});

  @override
  State<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<AddDevicePage> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '45679');
  String _status = '';

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
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
    final app = AppStateScope.of(context);
    await app.addManualDevice(ip, port);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _scan() async {
    // 相机权限由 mobile_scanner 在启动时自动申请；
    // 若被拒绝，扫码页 errorBuilder 会提示并给出「去设置」入口
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _ScannerPage()),
    );
    if (!mounted) return;
    if (result is String) {
      final parsed = AppState.parseQr(result);
      if (parsed == null) {
        setState(() => _status = '不是 LanChat 二维码');
        return;
      }
      final (id, name, port) = parsed;
      final uri = Uri.tryParse(result);
      // 二维码含多个可达 IP（逗号分隔），任取第一个用于手动连接
      final rawIp = uri?.queryParameters['ip'];
      final ip = rawIp?.split(',').first.trim();
      final app = AppStateScope.of(context);
      await app.addManualDeviceById(id, name, port, ip: ip);
      if (mounted) Navigator.pop(context);
    }
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
              onPressed: _addByIp,
              icon: const Icon(Icons.lan),
              label: const Text('连接'),
            ),
            const SizedBox(height: 24),
            if (!Platform.isWindows)
              OutlinedButton.icon(
                onPressed: _scan,
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
                '提示：一方开热点另一方连接时，自动搜索可能失效，'
                '此时用 IP 手动连接（开热点的一方 IP 一般是 192.168.43.1，'
                '端口默认 45679）。添加后发出第一条消息，对方列表里也会自动出现你，'
                '之后双方都能互发。',
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
