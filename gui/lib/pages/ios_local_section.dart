// 本机 on iOS (spec §6): the relay, the key (masked), this device's name, the data it keeps, the version and
// 屏幕常亮. No password, permissions, service, updates or auto-lock: an iPad only reaches other machines.
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../ios_channel.dart';
import '../paths.dart';
import '../ui/access_setup.dart';
import '../ui/controls.dart';
import '../ui/prefs.dart';
import '../ui/resources_state.dart' show sizeText;
import '../ui/tokens.dart' show controlGapOf;
import 'local_section.dart' show keyMask;
import 'section_card.dart';

/// Bytes of every file under [dir] (links not followed); 0 when it is missing or unreadable. Sync: run it off the
/// UI isolate ([dirBytesOffThread]).
int dirBytes(String dir) {
  var n = 0;
  try {
    for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          n += e.lengthSync();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return n;
}

Future<int> dirBytesOffThread(String dir) => Isolate.run(() => dirBytes(dir));

class IosLocalSection extends StatefulWidget {
  const IosLocalSection({
    super.key,
    required this.hub,
    required this.prefs,
    required this.onPrefs,
    required this.data,
    this.version,
  });
  final HubClient hub;
  final UiPrefs prefs;

  /// [prefs] changed: save them.
  final VoidCallback onPrefs;

  /// The data root; 数据用量 is its `files/`.
  final DataDir data;

  /// The app's version; null asks `rapp/ios`.
  final Future<String> Function()? version;

  @override
  State<IosLocalSection> createState() => _IosLocalSectionState();
}

class _IosLocalSectionState extends State<IosLocalSection> {
  bool _showTail = false;
  int? _bytes;
  String? _version;

  @override
  void initState() {
    super.initState();
    widget.hub.addListener(_onHub);
    if (widget.hub.lastAccess == null) widget.hub.access().catchError((_) => const HubAccess(null, false, ''));
    dirBytesOffThread(widget.data.filesDir).then((n) {
      if (mounted) setState(() => _bytes = n);
    });
    (widget.version ?? iosChannel.version)().then((v) {
      if (mounted) setState(() => _version = v);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    widget.hub.removeListener(_onHub);
    super.dispose();
  }

  HubAccess? _seen;

  /// The hub notifies on every line; rebuild only when the access state changed.
  void _onHub() {
    final a = widget.hub.lastAccess;
    if (a != _seen && mounted) setState(() => _seen = a);
  }

  void _setKeepAwake(bool on) {
    setState(() => widget.prefs.keepAwake = on);
    widget.onPrefs();
  }

  Future<void> _editAccess() => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: const Text('修改接入')),
          body: AccessSetup(hub: widget.hub, onDone: (_) => Navigator.of(ctx).pop()),
        ),
      ));

  Widget _row(String label, Widget value, {Widget? trailing}) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(children: [
          SizedBox(width: 72, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(child: value),
          ?trailing,
        ]),
      );

  Widget _keyRow(HubAccess? a) {
    if (a == null || !a.hasKey) return _row('key', const Text('未设置', key: Key('ios-key-value')));
    final tail = widget.hub.keyTail;
    return _row(
      'key',
      Text(_showTail && tail != null ? '$keyMask$tail' : keyMask, key: const Key('ios-key-value')),
      // The key is not kept here: only the last 4 of one typed in this run can be shown.
      trailing: tail == null
          ? null
          : RappButton.quiet(
              key: const Key('ios-key-reveal'),
              label: _showTail ? '隐藏' : '显示',
              onPressed: () => setState(() => _showTail = !_showTail),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.hub.lastAccess;
    final bytes = _bytes;
    return SectionCard(title: '本机', children: [
      _row('接入点', SelectableText(a?.relay ?? '未设置')),
      _keyRow(a),
      _row('本机名', Text(a?.name ?? '')),
      _row('数据用量', Text(bytes == null ? '计算中…' : sizeText(bytes))),
      _row('版本', Text(_version ?? '')),
      // Bounded, so the switch stays near its label.
      Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: RappSwitchRow(
            switchKey: const Key('keep-awake-switch'),
            label: '屏幕常亮',
            note: '有会话时屏幕不自动熄灭',
            value: widget.prefs.keepAwake,
            onChanged: _setKeepAwake,
          ),
        ),
      ),
      SizedBox(height: controlGapOf(context)),
      Align(
        alignment: Alignment.centerLeft,
        child: RappButton.secondary(
          key: const Key('edit-access'),
          label: '修改接入',
          onPressed: _editAccess,
        ),
      ),
    ]);
  }
}
