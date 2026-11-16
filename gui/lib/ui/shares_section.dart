// The "端口" section: the ports a device shares, and a way to share or stop sharing one.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shares.dart';
import '../term/term_stage.dart' as term;
import 'allow_dialog.dart';
import 'controls.dart';
import 'inline_edit.dart';
import 'lamp.dart';
import 'tokens.dart';

/// Asks which devices may use [row]; null means leave it as it is.
typedef PickAllow = Future<List<String>?> Function(BuildContext context, ShareRow row, List<Device> known);

Future<List<String>?> _dialogPick(BuildContext context, ShareRow row, List<Device> known) =>
    showAllowDialog(context, candidates: known, current: row.allow);

class SharesSection extends StatefulWidget {
  const SharesSection({
    super.key,
    required this.api,
    this.to,
    this.pickAllow = _dialogPick,
    this.open = term.openUrl,
    this.online = true,
  });
  final SharesApi api;

  /// The device to ask; null is this one.
  final String? to;
  final PickAllow pickAllow;
  final Future<void> Function(String url) open;

  /// False while the service this section asks is unreachable; going back to true reloads once.
  final bool online;

  @override
  State<SharesSection> createState() => _SharesSectionState();
}

class _SharesSectionState extends State<SharesSection> {
  final _port = TextEditingController();
  final _note = TextEditingController();
  ShareTable? _table;
  Object? _loadError;
  bool _loading = true;
  bool _busy = false;
  String? _setError;
  final _warns = <int, String>{};
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SharesSection old) {
    super.didUpdateWidget(old);
    if (!old.online && widget.online) _load();
    if (old.to != widget.to || !identical(old.api, widget.api)) {
      _table = null;
      _loadError = null;
      _setError = null;
      _busy = false;
      _warns.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _port.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final t = await widget.api.shares(to: widget.to);
      if (!mounted || seq != _seq) return;
      setState(() {
        _table = t;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _table = null;
        _loadError = e;
        _loading = false;
      });
    }
  }

  /// Runs a set call; on success asks again, on failure leaves the table alone.
  Future<bool> _set(Future<void> Function() call) async {
    final seq = _seq;
    setState(() {
      _busy = true;
      _setError = null;
    });
    try {
      await call();
    } catch (e) {
      if (mounted && seq == _seq) {
        setState(() {
          _busy = false;
          _setError = shareErrorText(e);
        });
      }
      return false;
    }
    if (!mounted || seq != _seq) return false;
    setState(() => _busy = false);
    await _load();
    return true;
  }

  Future<void> _add() async {
    final port = parsePort(_port.text);
    if (port == null) {
      setState(() => _setError = '端口号是 1 到 65535 的数字');
      return;
    }
    final note = _note.text.trim();
    final ok = await _set(() async {
      final r = await widget.api.share(to: widget.to, ports: [port], note: note.isEmpty ? null : note);
      for (final s in r) {
        if (s.warn != null) _warns[s.port] = s.warn!;
      }
    });
    if (ok && mounted) {
      _port.clear();
      _note.clear();
    }
  }

  Future<void> _pick(ShareRow row, List<Device> known) async {
    final allow = await widget.pickAllow(context, row, known);
    if (allow == null || !mounted) return;
    await _set(() async {
      await widget.api.share(to: widget.to, ports: [row.port], allow: allow);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final table = _table;
    final err = _loadError;
    final hidden = err != null && shareErrorHidesInput(err);
    Widget status(String s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(s, style: TextStyle(color: t.muted)),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Row(
            children: [
              Expanded(child: Text('端口', style: TextStyle(color: t.text, fontWeight: FontWeight.w600))),
              RappButton.secondary(key: const Key('shares-refresh'), label: '刷新', onPressed: _loading ? null : _load),
            ],
          ),
        ),
        if (table == null && _loading) status('正在读取…'),
        if (err != null) status(shareErrorText(err)),
        if (table != null) ...[
          if (table.rows.isEmpty) status('没有分享端口'),
          for (final r in table.rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _ShareRowView(
                row: r,
                t: t,
                openEnabled: r.web && r.addr.isNotEmpty,
                warn: _warns[r.port],
                busy: _busy,
                onOpen: () => widget.open(r.addr),
                onUnshare: () => _set(() async {
                  await widget.api.unshare(to: widget.to, port: r.port);
                  _warns.remove(r.port);
                }),
                onAllow: () => _pick(r, table.known),
                onNote: (s) => _set(() async {
                  await widget.api.share(to: widget.to, ports: [r.port], note: s.trim());
                }),
              ),
            ),
        ],
        if (!hidden && !(table == null && _loading)) _form(t),
      ],
    );
  }

  Widget _form(RappTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  key: const Key('share-port'),
                  controller: _port,
                  decoration: const InputDecoration(hintText: '端口号', isDense: true),
                  onSubmitted: (_) => _busy ? null : _add(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const Key('share-note'),
                  controller: _note,
                  decoration: const InputDecoration(hintText: '备注，可不填', isDense: true),
                  onSubmitted: (_) => _busy ? null : _add(),
                ),
              ),
              const SizedBox(width: 8),
              RappButton.secondary(key: const Key('share-add'), label: '分享', onPressed: _busy ? null : _add),
            ],
          ),
          if (_setError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_setError!, key: const Key('share-error'), style: TextStyle(color: t.accent)),
            ),
        ],
      );
}

class _ShareRowView extends StatelessWidget {
  const _ShareRowView({
    required this.row,
    required this.t,
    required this.openEnabled,
    required this.warn,
    required this.busy,
    required this.onOpen,
    required this.onUnshare,
    required this.onAllow,
    required this.onNote,
  });
  final ShareRow row;
  final RappTokens t;
  final bool openEnabled;
  final String? warn;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onUnshare;
  final VoidCallback onAllow;
  final ValueChanged<String> onNote;

  TextStyle get _mono => TextStyle(fontFamily: t.mono, fontFamilyFallback: t.monoFallback, fontSize: 12, color: t.muted);

  String get _scope {
    if (row.allow.isEmpty) return '所有设备';
    final names = row.allow.map((d) => d.name).join('、');
    return row.mine ? '只给 $names' : '只给 $names（不含本机）';
  }

  @override
  Widget build(BuildContext context) {
    final addr = row.addr;
    // No address: the share is not for this computer (the scope button says so), or the
    // service has no local port left for it.
    final shown = addr.isNotEmpty ? addr : (row.mine ? '没有本机端口可用' : '');
    return Container(
      key: Key('share-row-${row.port}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: t.panelBox(border: t.line),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusLamp(row.listening ? Lamp.active : Lamp.idle),
              const SizedBox(width: 10),
              SizedBox(width: 56, child: Text('${row.port}', style: _mono.copyWith(color: t.text))),
              Expanded(
                child: InlineEdit(
                  key: Key('share-note-${row.port}'),
                  text: row.note,
                  placeholder: '备注',
                  onCommit: onNote,
                  style: TextStyle(color: t.muted),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: SelectableText(shown, style: _mono)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: RappButton.secondary(key: Key('share-allow-${row.port}'), label: _scope, oneLine: true, onPressed: busy ? null : onAllow),
                ),
                if (row.web)
                  RappButton.secondary(key: Key('share-open-${row.port}'), label: '打开', onPressed: openEnabled ? onOpen : null),
                RappButton.secondary(
                  key: Key('share-copy-${row.port}'),
                  label: '复制',
                  onPressed: addr.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: addr)),
                ),
                ConfirmButton(
                  key: Key('share-unshare-${row.port}'),
                  label: '取消分享',
                  onConfirmed: busy ? null : onUnshare,
                ),
              ],
            ),
          ),
          if (warn != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(warn!, key: Key('share-warn-${row.port}'), style: TextStyle(color: t.accent)),
            ),
        ],
      ),
    );
  }
}
