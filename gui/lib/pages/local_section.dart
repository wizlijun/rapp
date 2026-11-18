// 本机: this machine's ID/password as the service sees them, plus service control.
import 'dart:async';
import 'dart:io';

import '../paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ios_channel.dart';
import '../permissions.dart';
import '../platform_caps.dart';
import '../service_client.dart';
import '../ui/controls.dart';
import '../ui/tokens.dart';
import '../ui/lifecycle.dart' show disconnectWord;
import '../ui/secure_text_field.dart';
import '../service_control.dart';
import 'permissions_panel.dart';
import 'section_card.dart';
import 'linux_firewall_section.dart';
import '../linux_firewall.dart';

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
  if (caps.systemOpen) return iosChannel.openUrl(page);
  final result = await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [page]);
  if (result.exitCode != 0) throw const FileSystemException('无法打开浏览器');
}

class LocalSection extends StatefulWidget {
  const LocalSection({
    super.key,
    required this.monitor,
    required this.control,
    required this.data,
    this.openSettings = openSettingsPane,
    this.platform,
    this.firewallCheck = checkLinuxFirewall,
  });
  /// Platform override for testing both desktop interfaces on either OS.
  final TargetPlatform? platform;
  final FirewallCheck firewallCheck;
  final ServiceMonitor monitor;
  final ServiceController? control;
  /// The current data root; the caller passes `state.data` and rebuilds when it changes.
  final DataDir data;
  final Future<void> Function(Permission) openSettings;

  @override
  State<LocalSection> createState() => _LocalSectionState();
}

/// The service's permission map, as the panel and hint helpers take it.
Map<String, dynamic> permissionsOf(ServiceStatus st) =>
    {'screen_recording': st.screenRecording, 'accessibility': st.accessibility};

class _LocalSectionState extends State<LocalSection> {
  bool _busy = false;
  bool _showPassword = false;
  bool _lanOpen = false; // not saved: the fold starts closed every time the page opens

  /// The key text, fetched on 显示 and dropped on 隐藏 or once the service reports a different key state.
  String? _shownKey;
  bool _newKeySaved = false; // the saved key came from 输入新 key; until the relay connects, a bad key means that one
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

  Future<void> _setAutoLock(bool on) async {
    try {
      await m.setAutoLock(on);
    } catch (e) {
      _say('失败：$e');
    }
  }

  Widget _autoLockRow(ServiceStatus st) {
    final t = RappTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        RappSwitchRow(
          switchKey: const Key('auto-lock-switch'),
          label: '远程 app 都关闭后自动锁屏',
          value: st.autoLock,
          onChanged: _setAutoLock,
        ),
        Text('锁屏后，B 打开 app 时需要输入这台 Mac 的登录密码。', style: TextStyle(color: t.muted)),
      ]),
    );
  }

  /// The service installs once this app's connection closes, so ok means quit now (K28).
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
      key: Key(key), tooltip: tip, icon: Icon(icon, size: 20, color: RappTokens.of(context).text), onPressed: onPressed);

  Widget _idRow(String label, String id, String key) =>
      _row(label, id, trailing: _icon(key, '复制 ID', Icons.copy, () => _copy(id, ' ID')));

  /// One row per ID, each with its own copy button; the label only on the first. With a relay set the bare ID
  /// is the first row and the `id@ip` forms fold under one line.
  List<Widget> _idRows(ServiceStatus st) {
    if (!st.relaySet) {
      final ids = st.shownIds;
      if (ids.isEmpty) return [_row('ID', '（还没有）')];
      return [for (final (i, id) in ids.indexed) _idRow(i == 0 ? 'ID' : '', id, 'copy-id-$i')];
    }
    final id = st.id;
    final lan = st.lanIds;
    return [
      if (id == null) _row('ID', '（还没有）') else _idRow('ID', id, 'copy-id-0'),
      if (lan.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            const SizedBox(width: 72),
            InkWell(
              key: const Key('lan-fold'),
              onTap: () => setState(() => _lanOpen = !_lanOpen),
              borderRadius: BorderRadius.circular(RappTokens.of(context).r),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: controlHeightOf(context)),
                child: Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: 1,
                  child: Text('${_lanOpen ? '▾' : '▸'} 局域网地址（${lan.length} 个）'),
                ),
              ),
            ),
          ]),
        ),
        if (_lanOpen)
          for (final (i, a) in lan.indexed) _idRow('', a, 'copy-lan-$i'),
      ],
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
      // Retrying after a failure: say why, or a relay that keeps failing reads 连接中 forever.
      'connecting' => st.relayError == null ? '连接中' : '连接中：${disconnectWord(st.relayError)}',
      'error' => '出错：${disconnectWord(st.relayError ?? '')}',
      _ => '未设置',
    };
  }

  Widget _relayRow(ServiceStatus st) => _row('中继', st.relayAddr == null ? _relayState(st) : '${st.relayAddr}',
      trailing: _icon('edit-relay', '修改中继', Icons.edit, () => _editRelay(st)));

  Widget? _stateRow(ServiceStatus st) {
    if (st.relayAddr == null) return null;
    if (st.relay == 'connected') _newKeySaved = false;
    final changed = st.relayError == 'key changed';
    final bad = st.relayError == 'bad key';
    if (!changed && !bad) return _row('状态', _relayState(st));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (changed)
        _row('状态', '⚠ 安全变更：中继换了 key', color: Theme.of(context).colorScheme.error)
      else
        _row('状态', bad && _newKeySaved ? '出错：新 key 不对' : _relayState(st)),
      if (changed)
        Padding(
          padding: const EdgeInsets.only(left: 72, top: 2),
          child: const Text('这台设备已经和中继断开。请向管理中继的人要新 key，再输入。'),
        ),
      Padding(
        padding: const EdgeInsets.only(left: 72),
        child: Align(
            alignment: Alignment.centerLeft,
            child: RappButton.primary(
                key: const Key('enter-new-key'), label: '输入新 key', onPressed: () => _enterNewKey(st))),
      ),
    ]);
  }

  Future<void> _enterNewKey(ServiceStatus st) async {
    final key = TextEditingController();
    final error = ValueNotifier<String?>(null);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入新 key'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SecureTextField(
              controller: key,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'key')),
          ValueListenableBuilder<String?>(
            valueListenable: error,
            builder: (_, e, _) => e == null
                ? const SizedBox.shrink()
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(e, style: TextStyle(color: Theme.of(ctx).colorScheme.error))),
          ),
        ]),
        actions: [
          RappButton.quiet(label: '取消', onPressed: () => Navigator.pop(ctx)),
          RappButton.primary(
            label: '保存',
            onPressed: () async {
              try {
                await m.setRelay(st.relayAddr ?? '', key.text.trim());
                if (mounted) {
                  setState(() {
                    _shownKey = null;
                    _newKeySaved = true;
                  });
                }
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                error.value = disconnectWord('$e');
              }
            },
          ),
        ],
      ),
    );
    // The dialog is still fading out here; dispose once its fields are gone.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      key.dispose();
      error.dispose();
    });
  }

  Widget _keyRow(ServiceStatus st) {
    final key = _shownKey;
    return _row('key', key ?? (st.hasKey ? keyMask : '未设置'),
        selectable: key != null,
        trailing: st.hasKey
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                RappButton.quiet(key: const Key('key-reveal'), label: key == null ? '显示' : '隐藏', onPressed: key == null ? _revealKey : _hideKey),
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
          SecureTextField(
              controller: key,
              decoration: const InputDecoration(labelText: 'key')),
          ValueListenableBuilder<String?>(
            valueListenable: error,
            builder: (_, e, _) =>
                e == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 8), child: Text(e, style: TextStyle(color: Theme.of(ctx).colorScheme.error))),
          ),
        ]),
        actions: [
          RappButton.quiet(label: '取消', onPressed: () => Navigator.pop(ctx)),
          RappButton.primary(
            label: '保存',
            onPressed: () async {
              try {
                await m.setRelay(addr.text.trim(), key.text.trim());
                if (mounted) {
                  setState(() {
                    _shownKey = null;
                    _newKeySaved = false;
                  });
                }
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                error.value = disconnectWord('$e');
              }
            },
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
            RappButton.quiet(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
            RappButton.primary(label: '保存', onPressed: () => Navigator.pop(ctx, true)),
          ],
        ),
      );

  Widget _row(String label, String value, {Widget? trailing, bool selectable = true, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 72, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(
              child: selectable
                  ? SelectableText(value, style: color == null ? null : TextStyle(color: color))
                  : Text(value, style: color == null ? null : TextStyle(color: color))),
          ?trailing,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([m, _resetFailed]),
      builder: (context, _) {
        final st = m.status;
        final buttons = Wrap(spacing: 8, children: [
          for (final (a, label) in [
            (ServiceAction.start, '启动'),
            (ServiceAction.stop, '停止'),
            (ServiceAction.restart, '重启'),
          ])
            RappButton.secondary(label: label, onPressed: _busy ? null : () => _control(a)),
        ]);
        return Column(children: [
        SectionCard(title: '本机', children: [
          // The service's state and its 启动 / 停止 / 重启 come first: they decide whether the rest means anything.
          _row('服务', st == null ? '未运行（${m.error ?? '连接中'}）' : '运行中'),
          Padding(padding: const EdgeInsets.only(top: 4, bottom: 8), child: buttons),
          if (st != null) ...[
            ..._idRows(st),
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
              ),
            if (_platform == TargetPlatform.macOS || _platform == TargetPlatform.linux) _autoLockRow(st),
            if (_platform == TargetPlatform.linux && st.capabilities?['desktop'] == true)
              _row('桌面', st.desktopError ?? (st.screenRecording && st.accessibility ? '可供其他设备连接' : '未检测到可共享的桌面')),
            if (_platform == TargetPlatform.linux)
              LinuxFirewallSection(port: st.port, localAddresses: localFirewallAddresses(st.lanIds), check: widget.firewallCheck),
            if (_platform != TargetPlatform.macOS && _platform != TargetPlatform.linux)
              _row('权限',
                  '屏幕录制 ${st.screenRecording ? '✓' : '✗'}   辅助功能 ${st.accessibility ? '✓' : '✗'}'),
            _row('会话', '${st.sessions.length} 个被访问中'),
          ],
          if (_platform == TargetPlatform.linux) ...[
            Text(st?.capabilities == null
              ? '启动或更新后台服务后，可查看本机提供的共享能力。'
              : '本机支持${st?.capabilities?['desktop'] == true ? '桌面共享、' : ''}端口分享${st?.capabilities?['terminal'] == true ? '和文本终端' : ''}；'
                '${st?.capabilities?['desktop'] == true ? '暂不支持单应用共享。' : '当前服务未提供桌面共享。'}'),
          ],
        ]),
        ]);
      },
    );
  }
}
