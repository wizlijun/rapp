import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class UnlockCredential {
  const UnlockCredential(this.password, {required this.auto});
  final String password;
  final bool auto;
}

/// The macOS runner stores both fields in a local, non-syncing Keychain item.
/// Linux keeps them in memory for this run only; other platforms have no backend.
class UnlockStore {
  UnlockStore({bool? supported, MethodChannel? channel, bool? memory})
    : memory = memory ?? Platform.isLinux,
      _channel = channel ?? const MethodChannel('rapp/unlock') {
    this.supported = supported ?? (Platform.isMacOS || this.memory);
  }
  late final bool supported;

  /// Passwords live in this object only (never the channel, never disk).
  final bool memory;
  final MethodChannel _channel;
  final Map<String, UnlockCredential> _mem = {};

  Future<UnlockCredential?> read(String device) async {
    if (!supported) return null;
    if (memory) return _mem[device];
    final value = await _channel.invokeMapMethod<String, dynamic>('read', {
      'device': device,
    });
    if (value == null) return null;
    final password = value['password'];
    final auto = value['auto'];
    if (password is! String ||
        auto is! bool ||
        utf8.encode(password).length > 1024) {
      throw const FormatException('钥匙串中的密码记录无效');
    }
    return UnlockCredential(password, auto: auto);
  }

  Future<void> save(
    String device,
    String password, {
    required bool auto,
  }) async {
    if (!supported) throw UnsupportedError('此平台暂不支持记住密码');
    if (utf8.encode(password).length > 1024) {
      throw const FormatException('密码过长');
    }
    if (memory) {
      _mem[device] = UnlockCredential(password, auto: auto);
      return;
    }
    await _channel.invokeMethod<void>('save', {
      'device': device,
      'password': password,
      'auto': auto,
    });
  }

  Future<void> forget(String device) async {
    if (memory) {
      _mem.remove(device);
    } else if (supported) {
      await _channel.invokeMethod<void>('forget', {'device': device});
    }
  }
}

class UnlockRequest {
  const UnlockRequest(
    this.password, {
    required this.remember,
    required this.auto,
  });
  final String password;
  final bool remember;
  final bool auto;
}

Future<UnlockRequest?> showUnlockDialog(
  BuildContext context, {
  required UnlockStore store,
  required String device,
}) => showDialog<UnlockRequest>(
  context: context,
  builder: (_) => UnlockDialog(store: store, device: device),
);

class UnlockDialog extends StatefulWidget {
  const UnlockDialog({super.key, required this.store, required this.device});
  final UnlockStore store;
  final String device;

  @override
  State<UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<UnlockDialog> {
  final _password = TextEditingController();
  bool _loading = true, _remember = false, _auto = false, _stored = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = widget.store.supported
          ? await widget.store.read(widget.device)
          : null;
      if (!mounted) return;
      if (saved != null) {
        _password.text = saved.password;
        _remember = _stored = true;
        _auto = saved.auto;
      }
    } catch (_) {
      if (!mounted) return;
      _error = '无法读取钥匙串；可以手动输入密码';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _forget() async {
    setState(() => _loading = true);
    try {
      await widget.store.forget(widget.device);
      if (!mounted) return;
      _password.clear();
      _stored = _remember = _auto = false;
      _error = null;
    } catch (_) {
      if (!mounted) return;
      _error = '未能从钥匙串删除密码，请重试';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _submit() {
    if (_loading) return;
    if (utf8.encode(_password.text).length > 1024) {
      setState(() => _error = '密码过长（最多 1024 字节）');
      return;
    }
    Navigator.of(context).pop(
      UnlockRequest(
        _password.text,
        remember: widget.store.supported && _remember,
        auto: widget.store.supported && _remember && _auto,
      ),
    );
  }

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('输入系统密码'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('输入远程电脑 ${widget.device} 的系统密码'),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            autofocus: true,
            enabled: !_loading,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(labelText: '系统密码', errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.store.supported) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(widget.store.memory ? '本次运行期间记住密码' : '记住密码'),
              value: _remember,
              onChanged: _loading
                  ? null
                  : (v) => setState(() {
                      _remember = v!;
                      if (!_remember) _auto = false;
                    }),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('连上时自动输入'),
              value: _auto,
              onChanged: _loading || !_remember
                  ? null
                  : (v) => setState(() => _auto = v!),
            ),
            if (_stored)
              TextButton(
                onPressed: _loading ? null : _forget,
                child: const Text('忘记密码'),
              ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _loading ? null : _submit,
        child: const Text('输入系统密码'),
      ),
    ],
  );
}
