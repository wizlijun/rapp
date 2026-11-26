// A device's load as its service says (device-load spec §5-§7): the snapshot, its warnings and the last hour.
// The rules live in the service; this only reads what it concluded (spec §6), it never recomputes a level.

/// Asks a device for its load once; [top] asks for the process list too.
typedef LoadNow = Future<Map<String, dynamic>> Function({bool top});

/// A warning's level; [normal] when a device has none.
enum LoadLevel { normal, warn, danger }

/// The level a warning or a disk row says (`warn`, `danger`); anything else is [LoadLevel.normal].
LoadLevel loadLevelOf(Object? v) => switch (v) {
      'warn' => LoadLevel.warn,
      'danger' => LoadLevel.danger,
      _ => LoadLevel.normal,
    };

int? _int(Object? v) => v is num ? v.toInt() : null;
double? _num(Object? v) => v is num ? v.toDouble() : null;

class LoadWarning {
  const LoadWarning(this.item, this.level, this.text, {this.etaMin});

  /// `cpu`, `gpu`, `mem`, `heat`, `battery`, `disk:<mount>` or `inode:<mount>`.
  final String item;
  final LoadLevel level;
  final String text;
  final int? etaMin;

  static LoadWarning? fromJson(Object? v) {
    if (v is! Map || v['item'] is! String) return null;
    return LoadWarning(v['item'] as String, loadLevelOf(v['level']), '${v['text'] ?? ''}', etaMin: _int(v['eta_min']));
  }
}

/// One sample of the hour's history: CPU / GPU busy %, the memory and the tightest disk's free share (0-1), and the
/// heat level (0 normal .. 3 critical). An item that could not be read is null.
class LoadPoint {
  const LoadPoint(this.at, {this.cpu, this.gpu, this.mem, this.disk, this.heat});
  final int at;
  final double? cpu, gpu, mem, disk;
  final int? heat;

  static LoadPoint? fromJson(Object? v) {
    if (v is! Map) return null;
    final at = _int(v['at']);
    if (at == null) return null;
    return LoadPoint(at, cpu: _num(v['cpu']), gpu: _num(v['gpu']), mem: _num(v['mem']), disk: _num(v['disk']), heat: _int(v['heat']));
  }
}

/// The points kept: one hour at one per 5 s, as the service keeps.
const loadKeep = 720;

class DeviceLoad {
  const DeviceLoad({
    required this.at,
    this.headroom,
    this.tightest,
    required this.term,
    this.items = const {},
    this.disks = const [],
    this.warnings = const [],
    this.history = const [],
    this.canTop = false,
  });

  /// Unix seconds of the sample.
  final int at;

  /// 0-100; null when no item could be read, [tightest] too.
  final int? headroom;
  final String? tightest;

  /// The device can open text terminals now.
  final bool term;

  /// `cpu`, `gpu`, `mem`, `heat`, `battery`, as the service sent them; an item it could not read is absent.
  final Map<String, dynamic> items;

  /// `{mount, total, avail, level, inode_free_pct?, eta_min?, paths}`, or `{mount, unreadable: true, paths}`.
  final List<Map<String, dynamic>> disks;
  final List<LoadWarning> warnings;

  /// Oldest first, at most [loadKeep].
  final List<LoadPoint> history;

  /// The device can list its busiest processes (「看占用最多的进程」): a line of its carried a `top` key. No service
  /// does yet (no sampler has a process list), so the action is offered nowhere until one says so.
  final bool canTop;

  /// The highest warning level; [LoadLevel.normal] when there is none.
  LoadLevel get level =>
      warnings.fold(LoadLevel.normal, (a, w) => w.level.index > a.index ? w.level : a);

  /// The highest level of the warnings on [item] (`disk` covers every `disk:` and `inode:` one).
  LoadLevel levelOf(String item) => warnings
      .where((w) => item == 'disk' ? w.item.startsWith('disk:') || w.item.startsWith('inode:') : w.item == item)
      .fold(LoadLevel.normal, (a, w) => w.level.index > a.index ? w.level : a);

  /// A watch's first line (with `history`), a later line (its `point` is the history), or a one-shot reply.
  static DeviceLoad fromJson(Map m) {
    final h = m['history'];
    final history = h is List ? [for (final p in h) ?LoadPoint.fromJson(p)] : [?LoadPoint.fromJson(m['point'])];
    return _fromJson(m, history, false);
  }

  static DeviceLoad _fromJson(Map m, List<LoadPoint> history, bool canTop) {
    final items = m['items'];
    final headroom = _int(m['headroom']);
    return DeviceLoad(
      at: _int(m['at']) ?? 0,
      headroom: headroom,
      tightest: headroom != null && m['tightest'] is String ? m['tightest'] as String : null,
      term: m['term'] == true,
      items: items is Map ? Map<String, dynamic>.from(items) : const {},
      disks: [
        for (final d in (m['disks'] is List ? m['disks'] as List : const []))
          if (d is Map && d['mount'] is String) Map<String, dynamic>.from(d),
      ],
      warnings: [
        for (final w in (m['warnings'] is List ? m['warnings'] as List : const [])) ?LoadWarning.fromJson(w),
      ],
      history: history.length > loadKeep ? history.sublist(history.length - loadKeep) : history,
      canTop: canTop || (m['top'] != null && m['top'] != false),
    );
  }

  /// The watch's next line: its snapshot replaces this one, its `point` joins the history; [canTop] stays.
  DeviceLoad next(Map line) {
    final p = LoadPoint.fromJson(line['point']);
    return _fromJson(line, [...history, ?p], canTop);
  }
}

String _pct(double f) => '${(f * 100).clamp(0, 100).round()}%';

/// The share of [avail] in [total], when both are numbers and [total] is not 0.
double? loadShare(Object? avail, Object? total) {
  final a = _num(avail), t = _num(total);
  return a == null || t == null || t <= 0 ? null : a / t;
}

/// The tightest readable disk's free share.
double? tightestDiskFree(DeviceLoad l) {
  double? out;
  for (final d in l.disks) {
    if (d['unreadable'] == true) continue;
    final f = loadShare(d['avail'], d['total']);
    if (f != null && (out == null || f < out)) out = f;
  }
  return out;
}

/// 「正常」「偏热」「严重」「危急」 for a `heat.level`.
String? heatWord(Object? level) => switch (level) {
      'normal' => '正常',
      'hot' => '偏热',
      'serious' => '严重',
      'critical' => '危急',
      _ => null,
    };

/// The tightest item and its value: 「磁盘 剩 6%」「CPU 42%」「内存 剩 25%」「热度 偏热」; 「—」 when none.
String tightestWord(DeviceLoad l) {
  final items = l.items;
  Map? item(String k) => items[k] is Map ? items[k] as Map : null;
  final (String label, String? value) = switch (l.tightest) {
    'cpu' => ('CPU', _num(item('cpu')?['pct']).let((p) => '${p.round()}%')),
    'gpu' => ('GPU', _num(item('gpu')?['pct']).let((p) => '${p.round()}%')),
    'mem' => ('内存', loadShare(item('mem')?['avail'], item('mem')?['total']).let((f) => '剩 ${_pct(f)}')),
    'disk' => ('磁盘', tightestDiskFree(l).let((f) => '剩 ${_pct(f)}')),
    'heat' => ('热度', heatWord(item('heat')?['level'])),
    'battery' => (
        '电池',
        item('battery')?['plugged'] == true ? '接着电源' : _num(item('battery')?['pct']).let((p) => '${p.round()}%'),
      ),
    _ => ('—', null),
  };
  return value == null ? label : '$label $value';
}

extension _Let<T extends Object> on T? {
  R? let<R>(R Function(T) f) {
    final v = this;
    return v == null ? null : f(v);
  }
}

/// The device to start work on, the same rule as `rapp load pick` (Task 6 `pick_of`): online, with a load, can open
/// terminals and has no 危险 warning; the highest headroom, then the lower CPU use (unknown counts as 100), then the
/// earlier in [loads].
String? pickDevice(Map<String, DeviceLoad> loads, Set<String> online) {
  String? best;
  var bh = -1;
  var bc = 0.0;
  for (final MapEntry(key: id, value: l) in loads.entries) {
    final h = l.headroom;
    if (!online.contains(id) || h == null || !l.term || l.warnings.any((w) => w.level == LoadLevel.danger)) continue;
    final cpu = _num(l.items['cpu'] is Map ? (l.items['cpu'] as Map)['pct'] : null) ?? 100.0;
    if (best == null || h > bh || (h == bh && cpu < bc)) {
      best = id;
      bh = h;
      bc = cpu;
    }
  }
  return best;
}
