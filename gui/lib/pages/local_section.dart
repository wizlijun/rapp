// 本机: this machine's ID/password as the service sees them, plus service control.
import 'dart:async';
import 'dart:io';

import '../paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../permissions.dart';
import '../service_client.dart';
import '../ui/lifecycle.dart' show disconnectWord;
import '../service_control.dart';
import '../data_relocate.dart';
import 'data_section.dart';
import 'permissions_panel.dart';
import 'section_card.dart';
import 'update_section.dart';
import 'linux_update_section.dart';

/// What the 密码 row shows while hidden: a fixed length, so the real length stays private too.
const passwordMask = '••••••••';

/// What the key row shows until 显示 is pressed.
const keyMask = '••••••';

/// How 立即升级 / 仍然安装 / 回到上一版 leave the app (K28): the service installs once rapp is gone.
class UpdateHooks {
  const UpdateHooks({required this.confirmQuit, required this.quitNow});

  /// Asks first when remote windows are open; true to go on.
  final Future<bool> Function() confirmQuit;
  final Future<void> Function() quitNow;
}

/// Opens a release/installer page with the platform browser.
Future<void> openInstallerPage(String page) async {
  final uri = Uri.tryParse(page);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) throw const FormatException('安装包地址无效');
  final result = await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [page]);
  if (result.exitCode != 0) throw const FileSystemException('无法打开浏览器');
}

class LocalSection extends StatefulWidget {
  const LocalSection({
    super.key,
    required this.monitor,
    required this.control,
    required this.data,
    this.relocate,
    this.openSettings = openSettingsPane,
    this.hooks,
    this.openPage = openInstallerPage,
    this.platform,
  });
  /// Platform override for testing both desktop interfaces on either OS.
  final TargetPlatform? platform;
  final ServiceMonitor monitor;
  final ServiceController? control;
  /// The current data root; the caller passes `state.data` and rebuilds when it changes.
  final DataDir data;
  final DataRelocator? relocate;
  final Future<void> Function(Permission) openSettings;

  /// Null (tests): the update buttons only send the command.
  final UpdateHooks? hooks;
  final Future<void> Function(String page) openPage;

  @override
  State<LocalSection> createState() => _LocalSectionState();
}

/// The service's permission map, as the panel and hint helpers take it.
Map<String, dynamic> permissionsOf(ServiceStatus st) =>
    {'screen_recording': st.screenRecording, 'accessibility': st.accessibility};

class _LocalSectionState extends State<LocalSection> {
  bool _busy = false;
  bool _showPassword = false;

  /// The key text, fetched on 显示 and dropped on 隐藏 or once the service reports a different key state.
  String? _shownKey;
  Timer? _poll;
  bool _guideDecided = false;

  /// The guide after an update that lost the permissions, once per run (K30).
  bool _lostGuided = false;

  /// The last reset left accessibility's old record in place (K29).
  final _resetFailed = ValueNotifier(false);

  ServiceMonitor get m => widget.monitor;
  TargetPlatform get _platform => widget.platform ?? defaultTargetPlatform;

  bool get _missing {
    final st = m.status;
    return st != null && missingPermissions(permissionsOf(st)).isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    if (_platform != TargetPlatform.macOS) return;
    // While something is missing, look again every 3 s so a grant shows up as ✓ by itself.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_missing) m.checkPermissions().catchError((_) {});
    });
    m.addListener(_onStatus);
    _onStatus();
  }

  @override
  void dispose() {
    _poll?.cancel();
    m.removeListener(_onStatus);
    _resetFailed.dispose();
    super.dispose();
  }

  void _onStatus() {
    // The manual steps stay while accessibility still reads ✗; they have done their job once it reads ✓.
    if (_resetFailed.value && m.status?.accessibility == true) _resetFailed.value = false;
    _maybeGuide();
  }

  /// The first time ever the service reports something missing, walk the user through it once.
  /// After an update that lost the permissions, once more this run, marker or not (K30).
  void _maybeGuide() {
    final st = m.status;
    if (st == null) return;
    if (st.permissionsLostAfterUpdate && !_lostGuided) {
      _lostGuided = _guideDecided = true;
      return _guideNextFrame();
    }
    if (_guideDecided) return;
    _guideDecided = true;
    if (_missing && claimPermissionGuide(widget.data.localDir)) {
      _lostGuided = true;
      _guideNextFrame();
    }
  }

  void _guideNextFrame() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showGuide();
      });

  Future<void> _showGuide() => showDialog<void>(
        context: context,
        builder: (ctx) => ListenableBuilder(
          listenable: Listenable.merge([m, _resetFailed]),
          builder: (ctx, _) {
            final st = m.status;
            return PermissionGuideDialog(
              permissions: st == null ? null : permissionsOf(st),
              onOpenSettings: _openSettings,
              onRestart: widget.control == null ? null : () => _control(ServiceAction.restart),
              onReset: _resetPermissions,
              accessibilityResetFailed: _resetFailed.value,
            );
          },
        ),
      );

  Future<void> _resetPermissions() async {
    try {
      final r = await m.permissionsReset();
      _resetFailed.value = r['accessibility_reset'] == false;
    } catch (e) {
      _say('失败：$e');
    }
  }

  /// The service installs once this app's connection closes, so ok means quit now (K28).
  Future<void> _thenQuit(Future<Object?> Function() send) async {
    final h = widget.hooks;
    if (h != null && !await h.confirmQuit()) return;
    await send();
    await h?.quitNow();
  }

  Future<void> _openSettings(Permission p) =>
      promptThenOpen(() => m.checkPermissions(prompt: true), () => widget.openSettings(p));

  void _say(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _control(ServiceAction a) async {
    final c = widget.control;
    if (c == null) return _say('找不到 rapp-service');
    setState(() => _busy = true);
    final err = await c.run(a);
    if (mounted) setState(() => _busy = false);
    _say(err ?? '已执行：${a.name}');
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    _say('已复制$what');
  }

  Widget _icon(String key, String tip, IconData icon, VoidCallback onPressed) => IconButton(
      key: Key(key), tooltip: tip, icon: Icon(icon, size: 18), visualDensity: VisualDensity.compact, onPressed: onPressed);

  /// One row per ID, each with its own copy button; the label only on the first.
  List<Widget> _idRows(List<String> ids) {
    if (ids.isEmpty) return [_row('ID', '（还没有）')];
    return [
      for (final (i, id) in ids.indexed)
        _row(i == 0 ? 'ID' : '', id, trailing: _icon('copy-id-$i', '复制 ID', Icons.copy, () => _copy(id, ' ID'))),
    ];
  }

  Widget _passwordRow(String pw) => _row('密码', _showPassword ? pw : passwordMask,
      selectable: _showPassword,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        _icon('password-reveal', _showPassword ? '隐藏密码' : '显示密码',
            _showPassword ? Icons.visibility_off : Icons.visibility, () => setState(() => _showPassword = !_showPassword)),
        _icon('copy-password', '复制密码', Icons.copy, () => _copy(pw, '密码')),
        _icon('edit-password', '修改密码', Icons.edit, () => _editPassword(pw)),
      ]));

  Future<void> _editPassword(String current) async {
    final pw = TextEditingController(text: current);
    final ok = await _dialog('修改密码', [
      TextField(controller: pw, autofocus: true, decoration: const InputDecoration(labelText: '新密码')),
    ]);
    if (ok == true && pw.text.isNotEmpty) await _apply(() => m.setPassword(pw.text));
  }

  String _relayState(ServiceStatus st) {
    if (st.relayAddr == null) return '未设置';
    return switch (st.relay) {
      'connected' => '已连接',
      'connecting' => '连接中',
      'error' => '出错：${disconnectWord(st.relayError ?? '')}',
      _ => '未设置',
    };
  }

  Widget _relayRow(ServiceStatus st) => _row('中继', st.relayAddr == null ? _relayState(st) : '${st.relayAddr}',
      trailing: _icon('edit-relay', '修改中继', Icons.edit, () => _editRelay(st)));

  Widget? _stateRow(ServiceStatus st) => st.relayAddr == null ? null : _row('状态', _relayState(st));

  Widget _keyRow(ServiceStatus st) {
    final key = _shownKey;
    return _row('key', key ?? (st.hasKey ? keyMask : '未设置'),
        selectable: key != null,
        trailing: st.hasKey
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(key: const Key('key-reveal'), onPressed: key == null ? _revealKey : _hideKey, child: Text(key == null ? '显示' : '隐藏')),
                if (key != null) _icon('copy-key', '复制 key', Icons.copy, () => _copy(key, ' key')),
              ])
            : null);
  }

  Future<void> _revealKey() async {
    try {
      final k = await m.showKey();
      if (mounted) setState(() => _shownKey = k);
    } catch (e) {
      _say('失败：$e');
    }
  }

  void _hideKey() => setState(() => _shownKey = null);

  Future<void> _editRelay(ServiceStatus st) async {
    final addr = TextEditingController(text: st.relayAddr ?? '');
    // Prefill with the saved key (still hidden on screen) so saving an address change keeps it.
    var current = _shownKey ?? '';
    if (current.isEmpty && st.hasKey) {
      try {
        current = await m.showKey();
      } catch (e) {
        _say('失败：$e');
        return;
      }
    }
    if (!mounted) return;
    final key = TextEditingController(text: current);
    final error = ValueNotifier<String?>(null);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改中继'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: addr, autofocus: true, decoration: const InputDecoration(labelText: '接入点')),
          TextField(
              controller: key,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'key')),
          ValueListenableBuilder<String?>(
            valueListenable: error,
            builder: (_, e, _) =>
                e == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 8), child: Text(e, style: const TextStyle(color: Colors.red))),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              try {
                await m.setRelay(addr.text.trim(), key.text.trim());
                if (mounted) setState(() => _shownKey = null);
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                error.value = disconnectWord('$e');
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    addr.dispose();
    key.dispose();
    error.dispose();
  }

  Future<void> _apply(Future<void> Function() f) async {
    try {
      await f();
      _say('已保存');
    } catch (e) {
      _say('失败：$e');
    }
  }

  Future<bool?> _dialog(String title, List<Widget> fields) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: fields),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
          ],
        ),
      );

  Widget _row(String label, String value, {Widget? trailing, bool selectable = true}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 72, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(child: selectable ? SelectableText(value) : Text(value)),
          ?trailing,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([m, _resetFailed]),
      builder: (context, _) {
        final update = m.status?.update;
        final st = m.status;
        final buttons = Wrap(spacing: 8, children: [
          for (final (a, label) in [
            (ServiceAction.start, '启动'),
            (ServiceAction.stop, '停止'),
            (ServiceAction.restart, '重启'),
          ])
            OutlinedButton(onPressed: _busy ? null : () => _control(a), child: Text(label)),
        ]);
        return Column(children: [
        SectionCard(title: '本机', children: [
          _row('服务', st == null ? '未运行（${m.error ?? '连接中'}）' : '运行中'),
          if (st != null) ...[
            ..._idRows(st.shownIds),
            _row('名称', st.name),
            _passwordRow(st.password),
            _relayRow(st),
            ?_stateRow(st),
            _keyRow(st),
            if (_platform == TargetPlatform.macOS)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SizedBox(
                      width: 72,
                      child: Padding(
                          padding: EdgeInsets.only(top: 4), child: Text('权限', style: TextStyle(color: Colors.grey)))),
                  Expanded(
                    child: PermissionsPanel(
                      permissions: permissionsOf(st),
                      onOpenSettings: _openSettings,
                      onReset: _resetPermissions,
                      accessibilityResetFailed: _resetFailed.value,
                    ),
                  ),
                ]),
              )
            else if (_platform != TargetPlatform.linux)
              _row('权限',
                  '屏幕录制 ${st.screenRecording ? '✓' : '✗'}   辅助功能 ${st.accessibility ? '✓' : '✗'}'),
            if (update != null && _platform != TargetPlatform.linux)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: UpdateSection(
                  info: update,
                  onCheck: m.updateCheck,
                  onApply: (confirm) => _thenQuit(() => m.updateApply(confirm: confirm)),
                  onDismiss: m.updateDismiss,
                  onRollback: () => _thenQuit(m.updateRollback),
                  onSetAuto: (on) => m.setUpdate(autoUpdate: on),
                  onOpenPage: (page) => widget.openPage(page).catchError((_) {}),
                ),
              ),
            _row('会话', '${st.sessions.length} 个被访问中'),
          ],
          if (_platform == TargetPlatform.linux) ...[
            const Text('本机为 Linux 客户端，暂不支持被远程控制。'),
            Padding(padding: const EdgeInsets.symmetric(vertical: 8),
              child: LinuxUpdateSection(openPage: widget.openPage)),
          ],
          const SizedBox(height: 8),
          buttons,
        ]),
        DataSection(data: widget.data, relocate: widget.relocate),
        ]);
      },
    );
  }
}
