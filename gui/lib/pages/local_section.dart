// 本机: this machine's ID/password/relay as the service sees them, plus service control.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../permissions.dart';
import '../service_client.dart';
import '../service_control.dart';
import 'permissions_panel.dart';
import 'section_card.dart';
import 'update_section.dart';

const relayLabels = {'connected': '已连接', 'connecting': '连接中', 'off': '未连接'};

/// How 立即升级 / 仍然安装 / 回到上一版 leave the app (K28): the service installs once rapp is gone.
class UpdateHooks {
  const UpdateHooks({required this.confirmQuit, required this.quitNow});

  /// Asks first when remote windows are open; true to go on.
  final Future<bool> Function() confirmQuit;
  final Future<void> Function() quitNow;
}

/// Opens the release page (「打开安装包」); macOS only.
Future<void> openInstallerPage(String page) async {
  if (Platform.isMacOS) await Process.run('open', [page]);
}

class LocalSection extends StatefulWidget {
  const LocalSection({
    super.key,
    required this.monitor,
    required this.control,
    required this.configDir,
    this.openSettings = openSettingsPane,
    this.hooks,
    this.openPage = openInstallerPage,
  });
  final ServiceMonitor monitor;
  final ServiceController? control;
  final String configDir;
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
  Timer? _poll;
  bool _guideDecided = false;

  /// The guide after an update that lost the permissions, once per run (K30).
  bool _lostGuided = false;

  /// The last reset left accessibility's old record in place (K29).
  final _resetFailed = ValueNotifier(false);

  ServiceMonitor get m => widget.monitor;

  bool get _missing {
    final st = m.status;
    return st != null && missingPermissions(permissionsOf(st)).isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    if (!Platform.isMacOS) return;
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
    // Accessibility reads ✗ once its old record is gone: the manual steps have done their job.
    if (_resetFailed.value && m.status?.accessibility == false) _resetFailed.value = false;
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
    if (_missing && claimPermissionGuide(widget.configDir)) {
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

  /// relay/key are not in `status`; prefill them from service.json if readable.
  Map<String, dynamic> _serviceJson() {
    try {
      final f = File('${widget.configDir}${Platform.pathSeparator}service.json');
      final v = jsonDecode(f.readAsStringSync());
      return v is Map<String, dynamic> ? v : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _editPassword(String current) async {
    final pw = TextEditingController(text: current);
    final ok = await _dialog('修改密码', [
      TextField(controller: pw, autofocus: true, decoration: const InputDecoration(labelText: '新密码')),
    ]);
    if (ok == true && pw.text.isNotEmpty) await _apply(() => m.setPassword(pw.text));
  }

  Future<void> _editRelay() async {
    final cfg = _serviceJson();
    final relay = TextEditingController(text: '${cfg['relay'] ?? ''}');
    final key = TextEditingController(text: '${cfg['key'] ?? ''}');
    final ok = await _dialog('中继设置', [
      TextField(controller: relay, autofocus: true, decoration: const InputDecoration(labelText: '地址，例如 vps:21116')),
      TextField(controller: key, decoration: const InputDecoration(labelText: 'Key')),
    ]);
    if (ok == true) await _apply(() => m.setRelay(relay.text.trim(), key.text.trim()));
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

  Widget _row(String label, String value, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 72, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(child: SelectableText(value)),
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
        return SectionCard(title: '本机', children: [
          _row('服务', st == null ? '未运行（${m.error ?? '连接中'}）' : '运行中'),
          if (st != null) ...[
            _row('ID', st.shownIds.isEmpty ? '（还没有）' : st.shownIds.join('\n')),
            _row('名称', st.name),
            _row('密码', st.password,
                trailing: IconButton(
                    tooltip: '修改密码', icon: const Icon(Icons.edit, size: 18), onPressed: () => _editPassword(st.password))),
            _row('中继', '${relayLabels[st.relay] ?? st.relay}${st.relayError == null ? '' : '（${st.relayError}）'}',
                trailing:
                    IconButton(tooltip: '修改中继', icon: const Icon(Icons.edit, size: 18), onPressed: _editRelay)),
            if (Platform.isMacOS)
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
            else
              _row('权限',
                  '屏幕录制 ${st.screenRecording ? '✓' : '✗'}   辅助功能 ${st.accessibility ? '✓' : '✗'}'),
            if (update != null)
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
          const SizedBox(height: 8),
          buttons,
        ]);
      },
    );
  }
}
