// A device column's 余力 row and its detail (device-load spec §7): the headroom bar and the tightest item, coloured by
// the service's warning level; a tap opens every item with its hour, the disks and what they cover, and the processes.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../load_model.dart';
import 'tokens.dart';

export '../load_model.dart' show LoadNow;

const _detailWidth = 380.0;
const _gap = 6.0;
const _edge = 8.0;

/// The colour of a warning level: 正常 is the secondary text colour, 注意 orange, 危险 red.
Color loadColour(RappTokens t, LoadLevel l) => switch (l) {
      LoadLevel.normal => t.muted,
      LoadLevel.warn => t.warn,
      LoadLevel.danger => t.danger,
    };

/// 「余力 ▓▓▓▓▓▓░░░░ 磁盘 剩 6%」; nothing while there is no load (offline, too old, no sample yet).
class LoadRow extends StatefulWidget {
  const LoadRow({super.key, required this.id, required this.load, this.loadNow});

  /// The device id, or `local`, for the keys.
  final String id;
  final DeviceLoad? load;

  /// Asks the device once; the detail's 「看占用最多的进程」 needs it.
  final LoadNow? loadNow;

  @override
  State<LoadRow> createState() => _LoadRowState();
}

class _LoadRowState extends State<LoadRow> {
  /// What an open detail shows: it follows the row's load, and closes when the load goes.
  late final _live = ValueNotifier<DeviceLoad?>(widget.load);

  /// The open detail's route: closing it closes that route, never one pushed over it.
  Route<Object?>? _detail;

  @override
  void didUpdateWidget(LoadRow old) {
    super.didUpdateWidget(old);
    if (widget.load == null) return _closeDetail();
    // The detail is in another route: telling it now, inside this build, would rebuild it from the wrong place.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _live.value = widget.load;
    });
  }

  @override
  void dispose() {
    _closeDetail();
    _live.dispose();
    super.dispose();
  }

  void _closeDetail() {
    final r = _detail;
    _detail = null;
    // On top it is popped, so the dialog's future completes; under another route it is taken out from there.
    _closeAfterFrame(r);
  }

  Future<void> _open(BuildContext anchor) async {
    await showLoadDetail(anchor, load: _live, loadNow: widget.loadNow, onRoute: (r) => _detail = r);
    _detail = null;
  }

  @override
  Widget build(BuildContext context) {
    final load = widget.load;
    if (load == null) return const SizedBox.shrink();
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final colour = loadColour(t, load.level);
    final word = tightestWord(load);
    return Semantics(
      button: true,
      label: '余力 ${load.headroom ?? '—'}，$word',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: Builder(
          builder: (anchor) => InkWell(
            key: Key('load-row-${widget.id}'),
            onTap: () => _open(anchor),
            borderRadius: BorderRadius.circular(t.r),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: controlHeightOf(context)),
              child: Row(children: [
                Text('余力', style: small?.copyWith(color: t.muted)),
                const SizedBox(width: 6),
                _Bar(key: Key('load-bar-${widget.id}'), headroom: load.headroom, on: colour, off: t.line),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(word, maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: colour)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where [anchor] is in its navigator's overlay.
Rect _rectOf(BuildContext anchor) {
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay = Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  return MatrixUtils.transformRect(box.getTransformTo(overlay), Offset.zero & box.size);
}

/// Opens [LoadDetail] under [anchor] (above it when there is more room there): the 余力 row's tap, and 需要你's
/// 「看占用最多的进程」 ([top]: the process list is asked for at once). It follows [load], and closes when that goes.
/// [onRoute] is told the detail's route. Completes when the detail closes.
Future<void> showLoadDetail(
  BuildContext anchor, {
  required ValueListenable<DeviceLoad?> load,
  LoadNow? loadNow,
  bool top = false,
  void Function(Route<Object?>? route)? onRoute,
}) {
  final rect = _rectOf(anchor);
  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) {
      final route = ModalRoute.of(context);
      onRoute?.call(route);
      return CustomSingleChildLayout(
        delegate: _DetailLayout(rect, MediaQuery.viewInsetsOf(context).bottom),
        child: ValueListenableBuilder(
          valueListenable: load,
          builder: (context, l, _) {
            if (l == null) {
              _closeAfterFrame(route);
              return const SizedBox.shrink();
            }
            return LoadDetail(load: l, loadNow: loadNow, top: top);
          },
        ),
      );
    },
  );
}

/// The detail routes already being closed: the owner and the detail's own builder may both ask.
final _closing = Expando<bool>();

/// Closes [r] once this frame is built: popped when on top, else taken out from under what was pushed over it.
void _closeAfterFrame(Route<Object?>? r) {
  if (r == null || _closing[r] == true) return;
  _closing[r] = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final nav = r.navigator;
    if (nav == null || !r.isActive) return;
    r.isCurrent ? nav.pop() : nav.removeRoute(r);
  });
}

/// Ten segments, one per 10 of headroom.
class _Bar extends StatelessWidget {
  const _Bar({super.key, required this.headroom, required this.on, required this.off});
  final int? headroom;
  final Color on, off;

  @override
  Widget build(BuildContext context) {
    final lit = ((headroom ?? 0) / 10).round().clamp(0, 10);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < 10; i++)
        Container(
          width: 5,
          height: 10,
          margin: EdgeInsets.only(right: i == 9 ? 0 : 1),
          color: i < lit ? on : off,
        ),
    ]);
  }
}

/// Under the row (above it when there is more room there), left edges lined up.
class _DetailLayout extends SingleChildLayoutDelegate {
  _DetailLayout(this.anchor, this.inset);
  final Rect anchor;
  final double inset;

  double _height(Size s) => math.max(0, s.height - inset);
  double _below(Size s) => _height(s) - anchor.bottom - _gap - _edge;
  double _above() => anchor.top - _gap - _edge;
  bool _down(Size s) => _below(s) >= 320 || _below(s) >= _above();

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) {
    final room = _down(c.biggest) ? _below(c.biggest) : _above();
    final width = math.min(_detailWidth, math.max(0.0, c.maxWidth - 2 * _edge));
    return BoxConstraints(minWidth: width, maxWidth: width, maxHeight: math.max(0.0, room));
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = anchor.left.clamp(_edge, math.max(_edge, size.width - child.width - _edge));
    final y = _down(size) ? anchor.bottom + _gap : anchor.top - _gap - child.height;
    return Offset(x.toDouble(), y.clamp(_edge, math.max(_edge, _height(size) - child.height - _edge)).toDouble());
  }

  @override
  bool shouldRelayout(_DetailLayout old) => old.anchor != anchor || old.inset != inset;
}

/// Decimal units, as disks are sold: 「6.0 GB」「38 GB」「1.2 TB」.
String _bytes(num b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return '${v < 10 && i > 0 ? v.toStringAsFixed(1) : v.round()} ${units[i]}';
}

String _pct(double f) => '${(f * 100).clamp(0, 100).round()}%';

String _eta(int min) => min >= 120 ? '约 ${(min / 60).round()} 小时后写满' : '约 $min 分钟后写满';

Map? _map(Object? v) => v is Map ? v : null;
num? _num(Object? v) => v is num ? v : null;

/// Every item, one line each with its hour; the disks and what they cover; the processes on request.
class LoadDetail extends StatefulWidget {
  const LoadDetail({super.key, required this.load, this.loadNow, this.top = false});
  final DeviceLoad load;
  final LoadNow? loadNow;

  /// Asks for the process list as it opens (需要你's 「看占用最多的进程」).
  final bool top;

  @override
  State<LoadDetail> createState() => _LoadDetailState();
}

class _LoadDetailState extends State<LoadDetail> {
  /// null: not asked; `[]`: asked and unreadable; otherwise one line per process.
  List<String>? _top;
  var _asking = false;

  @override
  void initState() {
    super.initState();
    final ask = widget.loadNow;
    if (widget.top && ask != null) {
      _asking = true;
      _fetchTop(ask);
    }
  }

  Future<void> _askTop() async {
    final ask = widget.loadNow;
    if (ask == null || _asking) return;
    setState(() => _asking = true);
    await _fetchTop(ask);
  }

  Future<void> _fetchTop(LoadNow ask) async {
    List<String> lines;
    try {
      lines = _topLines((await ask(top: true))['top']);
    } catch (_) {
      lines = const [];
    }
    if (!mounted) return;
    setState(() {
      _asking = false;
      _top = lines;
    });
  }

  /// `{cpu: [{name, pct, term?}], mem: [{name, rss|pct, term?}]}`; anything else reads as nothing.
  static List<String> _topLines(Object? top) {
    if (top is! Map) return const [];
    return [
      for (final (key, label) in const [('cpu', 'CPU'), ('mem', '内存')])
        if (top[key] is List)
          for (final p in top[key] as List)
            if (p is Map && p['name'] != null)
              [
                label,
                '${p['name']}',
                if (_num(p['pct']) != null) '${_num(p['pct'])!.round()}%',
                if (_num(p['rss']) != null) _bytes(_num(p['rss'])!),
                if (p['term'] != null) '（终端 ${p['term']}）',
              ].join(' '),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.text);
    final load = widget.load;
    final items = load.items;
    final h = load.history;
    // Values read in the text colour until the service warns on them; the hour lines in the secondary one.
    Color c(String item) => load.levelOf(item) == LoadLevel.normal ? t.text : loadColour(t, load.levelOf(item));
    Color line(String item) => loadColour(t, load.levelOf(item));

    final cpu = _map(items['cpu']), gpu = _map(items['gpu']), mem = _map(items['mem']);
    final heat = _map(items['heat']), battery = _map(items['battery']);
    final cpuWord = _num(cpu?['pct']) == null
        ? null
        : [
            '${_num(cpu!['pct'])!.round()}%',
            if (_num(cpu['cores']) != null || _num(cpu['load1']) != null)
              '（${[
                if (_num(cpu['cores']) != null) '${cpu['cores']} 核',
                if (_num(cpu['load1']) != null) '负载 ${_num(cpu['load1'])!.toStringAsFixed(1)}',
              ].join('，')}）',
          ].join(' ');
    final gpuWord = _num(gpu?['pct']) == null ? null : '${_num(gpu!['pct'])!.round()}%';
    final memWord = _num(mem?['avail']) == null || _num(mem?['total']) == null
        ? null
        : [
            '剩 ${_bytes(_num(mem!['avail'])!)} / ${_bytes(_num(mem['total'])!)}',
            if (_num(mem['swap_used']) != null && _num(mem['swap_used'])! > 0) 'swap ${_bytes(_num(mem['swap_used'])!)}',
          ].join(' · ');
    final heatWord_ = heatWord(heat?['level']);
    final heatText = heatWord_ == null
        ? null
        : [heatWord_, if (_num(heat!['celsius']) != null) '${_num(heat['celsius'])!.round()}°C'].join(' · ');
    final batteryText = battery == null
        ? null
        : [
            if (_num(battery['pct']) != null) '${_num(battery['pct'])!.round()}%',
            if (battery['plugged'] == true) '接着电源',
          ].join(' · ');

    Widget row(String label, String? value, String item, {List<double?>? hist, double max = 1}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 40, child: Text(label, style: small?.copyWith(color: t.muted))),
            Expanded(
              child: Text(
                value == null || value.isEmpty ? '—' : value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: small?.copyWith(color: value == null ? t.muted : c(item)),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 80,
              height: 16,
              child: hist == null ? null : Sparkline(values: hist, max: max, colour: line(item)),
            ),
          ]),
        );

    // Shorten paths under the home folder, wherever the home folder's disk is.
    final home = [
      for (final d in load.disks)
        for (final p in (d['paths'] is List ? d['paths'] as List : const []))
          if (p is Map && p['kind'] == 'home' && p['path'] is String) p['path'] as String,
    ].firstOrNull;
    String short(String p) =>
        home != null && (p == home || p.startsWith('$home/')) ? '~${p.substring(home.length)}' : p;

    String covers(Map d) {
      final terms = <String, int>{};
      final others = <String>{};
      for (final p in (d['paths'] is List ? d['paths'] as List : const [])) {
        if (p is! Map) continue;
        switch (p['kind']) {
          case 'term' when p['path'] is String:
            terms.update(short(p['path'] as String), (n) => n + 1, ifAbsent: () => 1);
          case 'data':
            others.add('数据目录');
          case 'cache':
            others.add('升级缓存');
          case 'home':
            others.add('主目录');
        }
      }
      return [for (final MapEntry(:key, :value) in terms.entries) '$key（终端 $value 个）', ...others].join('、');
    }

    Widget disk(Map d, bool first) {
      final mount = '${d['mount']}';
      final warned = [
        load.levelOf('disk:$mount'),
        load.levelOf('inode:$mount'),
        loadLevelOf(d['level']),
      ].reduce((a, b) => a.index >= b.index ? a : b);
      final colour = warned == LoadLevel.normal ? t.text : loadColour(t, warned);
      final share = loadShare(d['avail'], d['total']);
      final inode = _num(d['inode_free_pct']);
      final eta = _num(d['eta_min']);
      final free = d['unreadable'] == true || _num(d['avail']) == null
          ? '读不到'
          : [
              '剩 ${_bytes(_num(d['avail'])!)}${share == null ? '' : ' (${_pct(share)})'}',
              if (eta != null) _eta(eta.round()),
              if (inode != null && load.levelOf('inode:$mount') != LoadLevel.normal) 'inode 剩 ${inode.round()}%',
            ].join(' · ');
      final cover = covers(d);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 40, child: first ? Text('磁盘', style: small?.copyWith(color: t.muted)) : null),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(mount, maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: colour))),
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: Text(free,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small?.copyWith(color: d['unreadable'] == true ? t.muted : colour)),
                ),
              ]),
              if (cover.isNotEmpty) Text('覆盖：$cover', style: small?.copyWith(color: t.muted)),
            ]),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            height: 16,
            child: first ? Sparkline(values: [for (final p in h) p.disk], max: 1, colour: line('disk')) : null,
          ),
        ]),
      );
    }

    final top = _top;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: t.floatBox(border: t.line).copyWith(
          boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 32, offset: Offset(0, 12))],
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            row('CPU', cpuWord, 'cpu', hist: [for (final p in h) p.cpu], max: 100),
            row('GPU', gpuWord, 'gpu', hist: [for (final p in h) p.gpu], max: 100),
            row('内存', memWord, 'mem', hist: [for (final p in h) p.mem]),
            row('热度', heatText, 'heat', hist: [for (final p in h) p.heat?.toDouble()], max: 3),
            row('电池', batteryText, 'battery'),
            if (load.disks.isEmpty) row('磁盘', null, 'disk'),
            for (final (i, d) in load.disks.indexed) disk(d, i == 0),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: widget.loadNow == null || _asking ? null : _askTop,
                child: const Text('看占用最多的进程'),
              ),
            ),
            if (top != null)
              if (top.isEmpty)
                Text('读不到', style: small?.copyWith(color: t.muted))
              else
                for (final l in top) Text(l, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
          ]),
        ),
      ),
    );
  }
}

/// One item's hour: a line over the points it could read, broken where it could not; [max] is the top of the scale.
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, required this.max, required this.colour});
  final List<double?> values;
  final double max;
  final Color colour;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _SparkPainter(values, max, colour), size: const Size(80, 16));
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.max, this.colour);
  final List<double?> values;
  final double max;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || max <= 0) return;
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final path = Path();
    var pen = false;
    for (final (i, v) in values.indexed) {
      if (v == null) {
        pen = false;
        continue;
      }
      final x = size.width * i / (values.length - 1);
      final y = size.height - 1 - (size.height - 2) * (v / max).clamp(0.0, 1.0);
      pen ? path.lineTo(x, y) : path.moveTo(x, y);
      pen = true;
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.colour != colour || old.max != max || !listEquals(old.values, values);
}
