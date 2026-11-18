import 'dart:math' as math;

// 日志: the whole stage below the top bar — three cards, the merged timeline, rows that open in place
// (log screen spec §4).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../log_view.dart';
import 'controls.dart';
import 'lamp.dart';
import 'log_model.dart';
import 'tab_chip.dart';
import 'tokens.dart';

const _cardWords = {LogKind.unreachable: '连不上', LogKind.refused: '被拒绝', LogKind.fault: '服务出错'};
const _cardWidth = 220.0;
const _gap = 8.0;

String _two(int n) => n.toString().padLeft(2, '0');

DateTime? _tsOf(LogEntry e) => DateTime.tryParse('${e.fields['ts'] ?? ''}')?.toLocal();

/// A card's 「最近一次」: today the time, yesterday 「昨天」, earlier the date.
String _when(LogEntry e, DateTime now) {
  final t = _tsOf(e);
  if (t == null) return '';
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return hm;
  if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
  return '${_two(t.month)}-${_two(t.day)} $hm';
}

String _hms(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

class LogScreen extends StatefulWidget {
  const LogScreen({
    super.key,
    required this.model,
    required this.devices,
    required this.onBack,
    this.openFolder,
    this.logDir,
  });

  /// The caller owns it: it calls [LogModel.open] and disposes it.
  final LogModel model;

  /// The other devices, as the devices tab lists them.
  final List<(String id, String label, Lamp lamp)> devices;
  final VoidCallback onBack;

  /// 打开文件夹 (本机 only), the same as the 访问记录 button.
  final Future<void> Function(String dir)? openFolder;
  final String? logDir;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  ScrollController _scroll = ScrollController();
  final _aroundScroll = ScrollController();
  final _search = TextEditingController();
  final _focus = GlobalKey();

  /// Rows opened in place, by `at`.
  final _open = <String>{};
  bool _launchdOpen = false;

  /// Where the timeline was when 看前后 replaced it.
  double _saved = 0;
  LogEntry? _wasAround;
  bool _centered = false;
  late int _resets;

  LogModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _resets = m.resets;
    _wasAround = m.aroundOf;
    m.addListener(_onModel);
  }

  @override
  void didUpdateWidget(LogScreen old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
      _resets = m.resets;
      _wasAround = m.aroundOf;
    }
  }

  @override
  void dispose() {
    m.removeListener(_onModel);
    _scroll.dispose();
    _aroundScroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onModel() {
    if (!mounted) return;
    final around = m.aroundOf;
    if (around != null && _wasAround == null) {
      _saved = _scroll.hasClients ? _scroll.offset : 0;
    } else if (around == null && _wasAround != null) {
      // The timeline comes back where it was left.
      _scroll.removeListener(_onScroll);
      _scroll.dispose();
      _scroll = ScrollController(initialScrollOffset: _saved)..addListener(_onScroll);
    }
    if (around != null && !identical(around, _wasAround)) _centered = false;
    _wasAround = around;
    if (m.resets != _resets) {
      _resets = m.resets;
      _open.clear();
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    setState(() {});
  }

  void _onScroll() {
    final p = _scroll.position;
    m.setAtTop(p.pixels <= .5);
    if (p.extentAfter < 300) m.loadOlder();
  }

  String? _nameOf(String id) {
    for (final d in widget.devices) {
      if (d.$1 == id) return d.$2;
    }
    return null;
  }

  bool get _ios => Theme.of(context).platform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final around = m.aroundOf;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8), child: _header(t)),
        if (around != null) ...[
          _aroundBar(t, around),
          Expanded(child: _aroundView(t, around)),
        ] else
          // Cards, filters and rows scroll as one, so a short window still shows rows; 「有 N 条新的」 stays on top.
          Expanded(
            child: Stack(children: [
              Positioned.fill(child: _list(t)),
              if (m.pendingNew > 0) Positioned(top: 0, left: 0, right: 0, child: _pending(t)),
            ]),
          ),
      ],
    );
  }

  Widget _header(RappTokens t) {
    final err = m.error;
    final local = m.device == null;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
          RappButton.secondary(key: const Key('log-back'), label: '‹ 返回', onPressed: widget.onBack),
          Text('日志', style: TextStyle(color: t.text, fontWeight: FontWeight.w700)),
          _picker(t),
          if (err != null) Text(err, key: const Key('log-error'), style: TextStyle(color: t.accent)),
        ]),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [
          SizedBox(
            width: 200,
            child: TextField(
              key: const Key('log-search'),
              controller: _search,
              onChanged: m.setSearch,
              decoration: InputDecoration(
                hintText: '搜索…',
                prefixIcon: const Icon(Icons.search, size: 18),
              ),
            ),
          ),
          RappButton.secondary(key: const Key('log-refresh'), label: '刷新', icon: Icons.refresh, onPressed: m.refresh),
          if (local && widget.openFolder != null)
            RappButton.secondary(
              key: const Key('log-open-folder'),
              label: '打开文件夹',
              onPressed: widget.logDir == null ? null : () => widget.openFolder!(widget.logDir!),
            ),
        ]),
      ],
    );
  }

  Widget _picker(RappTokens t) {
    final sel = m.device;
    Lamp? lamp;
    var label = '本机';
    if (sel != null) {
      label = sel;
      for (final d in widget.devices) {
        if (d.$1 == sel) (label, lamp) = (d.$2, d.$3);
      }
    }
    return RappDropdown<String>(
      key: const Key('log-device-picker'),
      minWidth: 96,
      menuConstraints: (w) => BoxConstraints(minWidth: math.max(w, 200), maxWidth: math.max(w, 280)),
      selected: true,
      current: m.device ?? '',
      label: Row(mainAxisSize: MainAxisSize.min, children: [
        if (lamp != null) ...[StatusLamp(lamp), const SizedBox(width: 8)],
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: Text(label)),
      ]),
      // 本机 and every other device with its lamp, the way the devices tab's picker lists them.
      items: [
        const RappMenuItem<String>(
            key: Key('log-device-local'), value: '', label: '本机', lead: SizedBox.square(dimension: 13)),
        for (final d in widget.devices)
          RappMenuItem<String>(key: Key('log-device-${d.$1}'), value: d.$1, label: d.$2, lead: StatusLamp(d.$3)),
      ],
      onSelected: (pick) {
        _launchdOpen = false;
        m.open(pick.isEmpty ? null : pick);
      },
    );
  }

  Widget _cards(RappTokens t, Map<LogKind, int> counts) => LayoutBuilder(builder: (context, c) {
        final fits = c.maxWidth >= 3 * _cardWidth + 2 * _gap;
        final cards = [
          for (final k in LogKind.values) _card(t, k, counts[k] ?? 0, fits ? null : _cardWidth),
        ];
        final row = IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              fits ? Expanded(child: cards[i]) : cards[i],
            ],
          ]),
        );
        return fits ? row : SingleChildScrollView(scrollDirection: Axis.horizontal, child: row);
      });

  Widget _card(RappTokens t, LogKind k, int n, double? width) {
    final zero = n == 0;
    final selected = m.kind == k;
    final fg = zero ? t.muted : t.text;
    final last = m.latest?[k];
    final radius = BorderRadius.circular(t.r);
    final line = last == null ? null : logLine(last, nameOf: _nameOf);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: Key('log-card-${k.wire}'),
          onTap: () => m.toggleKind(k),
          borderRadius: radius,
          child: Container(
            width: width,
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.all(12),
            decoration: selected
                ? t.raiseBox(border: t.text)
                : BoxDecoration(borderRadius: radius, border: Border.all(color: zero ? t.line : t.muted)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(_cardWords[k]!, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                Text('$n', style: TextStyle(color: fg, fontSize: 22, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 4),
              if (zero || line == null)
                Text('24 小时内没有', style: TextStyle(color: t.muted))
              else ...[
                Text(line.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text)),
                Text(_when(last!, DateTime.now()), style: TextStyle(color: t.muted)),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _filters(RappTokens t) {
    // iPad 本机 has only hub.log: nothing to choose between.
    final showSrc = !(_ios && m.device == null);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip('log-problems', '只看问题', m.problemsOnly, () => m.setProblemsOnly(true)),
        _chip('log-all', '全部', !m.problemsOnly, () => m.setProblemsOnly(false)),
        if (showSrc) ...[
          const SizedBox(width: 8),
          Text('来源：', style: TextStyle(color: t.muted)),
          for (final s in const ['service', 'hub']) _chip('log-src-$s', s, m.sources.contains(s), () => m.toggleSource(s)),
        ],
        if (m.launchd != null) ...[
          const SizedBox(width: 8),
          _chip('log-launchd-toggle', '启动输出 ${_launchdOpen ? '▾' : '▸'}', _launchdOpen,
              () => setState(() => _launchdOpen = !_launchdOpen)),
        ],
      ],
    );
  }

  /// A [TabChip] as wide as its label (it fills its width otherwise).
  Widget _chip(String key, String label, bool selected, VoidCallback onTap) =>
      IntrinsicWidth(child: TabChip(key: Key(key), label: label, selected: selected, onTap: onTap));

  TextStyle _mono(RappTokens t, {Color? color}) =>
      TextStyle(fontFamily: t.mono, fontFamilyFallback: t.monoFallback, color: color ?? t.text);

  Widget _launchd(RappTokens t, List<String> lines) {
    final text = lines.join('\n');
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(8),
      decoration: t.panelBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          // Newest at the bottom, and that is where it opens.
          child: SingleChildScrollView(
            reverse: true,
            child: SelectableText(text, key: const Key('log-launchd-text'), style: _mono(t)),
          ),
        ),
        const SizedBox(height: 8),
        RappButton.secondary(
          key: const Key('log-launchd-copy'),
          label: '复制',
          onPressed: () => Clipboard.setData(ClipboardData(text: text)),
        ),
      ]),
    );
  }

  Widget _aroundBar(RappTokens t, LogEntry e) {
    final ts = _tsOf(e);
    final span = ts == null
        ? ''
        : ' · ${_hms(ts.subtract(const Duration(minutes: 1)))}–${_hms(ts.add(const Duration(minutes: 1)))}';
    return Container(
      key: const Key('log-around-bar'),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.only(left: 12),
      decoration: t.raiseBox(border: t.text),
      child: Row(children: [
        Expanded(child: Text('前后 1 分钟$span', style: TextStyle(color: t.text, fontWeight: FontWeight.w600))),
        RappButton.secondary(key: const Key('log-around-close'), label: '× 返回', onPressed: m.leaveAround),
      ]),
    );
  }

  Widget _pending(RappTokens t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const Key('log-pending'),
            borderRadius: BorderRadius.circular(t.r),
            onTap: () {
              m.showPending();
              if (_scroll.hasClients) _scroll.jumpTo(0);
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              alignment: Alignment.center,
              decoration: t.floatBox(border: t.accent),
              child: Text('有 ${m.pendingNew} 条新的', style: TextStyle(color: t.accent, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );

  Widget _list(RappTokens t) {
    final rows = m.rows;
    final counts = m.counts;
    const side = EdgeInsets.symmetric(horizontal: 16);
    return CustomScrollView(
      key: const Key('log-list'),
      controller: _scroll,
      slivers: [
        if (counts != null) SliverPadding(padding: side, sliver: SliverToBoxAdapter(child: _cards(t, counts))),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          sliver: SliverToBoxAdapter(child: _filters(t)),
        ),
        if (_launchdOpen && m.launchd != null) SliverToBoxAdapter(child: _launchd(t, m.launchd!)),
        SliverPadding(
          padding: side,
          sliver: SliverList.builder(itemCount: rows.length, itemBuilder: (context, i) => _row(t, rows[i])),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: SliverToBoxAdapter(child: _footer(t)),
        ),
      ],
    );
  }

  Widget _footer(RappTokens t) {
    final Widget child;
    if (m.rows.isEmpty && m.loading) {
      child = Text('读取中…', style: TextStyle(color: t.muted));
    } else if (m.error != null) {
      child = const SizedBox.shrink();
    } else if (m.more) {
      child = RappButton.secondary(key: const Key('log-load-older'), label: '加载更早的', onPressed: m.loadOlder);
    } else {
      child = Text('没有更早的了', key: const Key('log-end'), style: TextStyle(color: t.muted));
    }
    return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Center(child: child));
  }

  Widget _aroundView(RappTokens t, LogEntry focus) {
    final rows = m.rows;
    if (rows.isNotEmpty && !_centered) {
      _centered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _focus.currentContext;
        if (c != null && c.mounted) Scrollable.ensureVisible(c, alignment: .5);
      });
    }
    return SingleChildScrollView(
      controller: _aroundScroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final e in rows)
          e.at == focus.at ? KeyedSubtree(key: _focus, child: _row(t, e, lit: true)) : _row(t, e),
        if (rows.isEmpty && m.error == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(child: Text('读取中…', style: TextStyle(color: t.muted))),
          ),
      ]),
    );
  }

  Widget _row(RappTokens t, LogEntry e, {bool lit = false}) {
    final l = logLine(e, nameOf: _nameOf);
    final open = _open.contains(e.at);
    final warn = l.warn;
    final head = Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: Key('log-row-${e.at}'),
        onTap: () => setState(() => open ? _open.remove(e.at) : _open.add(e.at)),
        child: Container(
          constraints: BoxConstraints(minHeight: _ios ? 48 : 0),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: lit ? BoxDecoration(color: t.tint, borderRadius: BorderRadius.circular(t.r)) : null,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.time, style: _mono(t, color: t.muted)),
            const SizedBox(width: 10),
            // Monospace and padded to the longer name, so the summaries line up.
            Text(e.src.padRight(7), softWrap: false, style: _mono(t, color: t.muted)),
            SizedBox(width: 20, child: warn ? Text('⚠', style: TextStyle(color: t.accent)) : null),
            Expanded(child: Text(l.summary, style: TextStyle(color: warn ? t.accent : t.text))),
            Text(open ? '▴' : '', style: TextStyle(color: t.muted)),
          ]),
        ),
      ),
    );
    if (!open) return head;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head,
      Padding(
        padding: const EdgeInsets.fromLTRB(30, 4, 6, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (k, v) in l.fields)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 96, child: Text(k, style: TextStyle(color: t.muted))),
                Expanded(child: SelectableText(v, style: TextStyle(color: t.text))),
              ]),
            ),
          const SizedBox(height: 6),
          SelectableText(e.raw, style: _mono(t, color: t.muted)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            RappButton.secondary(
              key: Key('log-copy-${e.at}'),
              label: '复制',
              onPressed: () => Clipboard.setData(ClipboardData(text: e.raw)),
            ),
            RappButton.secondary(
              key: Key('log-around-${e.at}'),
              label: '看前后 ±1 分钟',
              onPressed: () => m.around(e),
            ),
          ]),
        ]),
      ),
    ]);
  }
}
