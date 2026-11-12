// Global resources: the clipboard entries of every session (newest first, 100 unpinned at most)
// and the transfers of this launch (running, and the last 50 ended). Pure Dart, no I/O.
import 'package:flutter/foundation.dart';

import '../embed/session_port.dart';

const maxUnpinned = 100;
const maxEnded = 50;

class ClipEntry {
  ClipEntry(this.seq, this.key, this.sid, this.clip, this.kind, this.title, this.source, this.at);

  /// Local, increasing; the UI and MainState point at entries by it.
  final int seq;
  final String key;
  final Object sid;
  final int clip;
  final ClipKind kind;
  final String title;
  final String source;
  final DateTime at;
  bool pinned = false;
  bool pinning = false;
  int? copy;
  bool ended = false;
}

class TransferRow {
  TransferRow(this.sid, this.id, this.key, this.down, this.name, this.source, this.done, this.total, this.state);
  final Object sid;
  final int id;
  final String key;
  final bool down;
  final String name;
  final String source;
  int done, total;
  TransferState state;
  String? path;
  String? error;
  DateTime? endedAt;
}

class ResourcesState extends ChangeNotifier {
  ResourcesState({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<ClipEntry> _clips = []; // newest first
  final Set<(Object, int)> _seen = {};
  final List<TransferRow> _running = [];
  final List<TransferRow> _ended = []; // newest first
  final Set<(Object, int)> _finished = {};
  int _nextSeq = 1;

  List<ClipEntry> get clips => List.unmodifiable(_clips);
  List<ClipEntry> clipsOf(String key) => _clips.where((e) => e.key == key).toList();
  ClipEntry? entry(int seq) {
    for (final e in _clips) {
      if (e.seq == seq) return e;
    }
    return null;
  }

  List<TransferRow> get running => List.unmodifiable(_running);
  List<TransferRow> get ended => List.unmodifiable(_ended);

  /// `rows` is the runner's whole table, newest first; only numbers this sid has not shown are added.
  void addClips(String key, Object sid, String source, List<ClipRow> rows) {
    var added = false;
    for (final r in rows.reversed) {
      if (!_seen.add((sid, r.id))) continue;
      _clips.insert(0, ClipEntry(_nextSeq++, key, sid, r.id, r.kind, r.title, source, _clock()));
      added = true;
    }
    if (!added) return;
    _evict();
    notifyListeners();
  }

  void _evict() {
    var n = _clips.where((e) => !e.pinned).length;
    for (var i = _clips.length - 1; i >= 0 && n > maxUnpinned; i--) {
      if (_clips[i].pinned) continue;
      _clips.removeAt(i);
      n--;
    }
  }

  void beginPin(int seq) {
    final e = entry(seq);
    if (e == null) return;
    e.pinning = true;
    notifyListeners();
  }

  void pinned(int seq, int copy) {
    final e = entry(seq);
    if (e == null) return;
    e.pinning = false;
    e.pinned = true;
    e.copy = copy;
    notifyListeners();
  }

  void pinFailed(int seq) {
    final e = entry(seq);
    if (e == null) return;
    e.pinning = false;
    e.pinned = false;
    notifyListeners();
  }

  /// The copy number to `drop_copy`, if any. A live entry stays (and counts again); an ended one goes.
  int? unpin(int seq, {required bool sessionEnded}) {
    final e = entry(seq);
    if (e == null) return null;
    final copy = e.copy;
    e.pinned = false;
    e.pinning = false;
    e.copy = null;
    if (sessionEnded) {
      _clips.remove(e);
    } else {
      _evict();
    }
    notifyListeners();
    return copy;
  }

  void transfer(String key, String source, TransferProgressEvent e) {
    final id = (e.sid, e.id);
    if (_finished.contains(id)) return;
    TransferRow? row;
    for (final r in _running) {
      if (r.sid == e.sid && r.id == e.id) row = r;
    }
    if (row == null) {
      row = TransferRow(e.sid, e.id, key, e.down, e.name, source, e.done, e.total, e.state);
      _running.add(row);
    }
    row
      ..done = e.done
      ..total = e.total
      ..state = e.state
      ..path = e.path
      ..error = e.error;
    if (e.state != TransferState.running) _finish(row);
    notifyListeners();
  }

  void _finish(TransferRow r) {
    _running.remove(r);
    r.endedAt = _clock();
    _finished.add((r.sid, r.id));
    _ended.insert(0, r);
    if (_ended.length > maxEnded) _ended.removeRange(maxEnded, _ended.length);
  }

  List<(Object, int)> sessionEnded(String key, Set<Object> sids) {
    _clips.removeWhere((e) => e.key == key && !e.pinned);
    for (final e in _clips) {
      if (e.key == key) e.ended = true;
    }
    _seen.removeWhere((s) => sids.contains(s.$1));
    final hit = _running.where((r) => sids.contains(r.sid)).toList();
    for (final r in hit) {
      r.state = TransferState.cancelled;
      _finish(r);
    }
    notifyListeners();
    return [for (final r in hit) (r.sid, r.id)];
  }

  void linkDown(Object sid) {
    final hit = _running.where((r) => r.sid == sid).toList();
    if (hit.isEmpty) return;
    for (final r in hit) {
      r.state = TransferState.failed;
      r.error = '没传完';
      _finish(r);
    }
    notifyListeners();
  }
}

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String sizeText(int bytes) {
  const kb = 1024, mb = 1024 * 1024, gb = 1024 * 1024 * 1024;
  if (bytes < kb) return '$bytes B';
  if (bytes < mb) return '${(bytes / kb).round()} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(1)} GB';
}

String kindWord(ClipKind k) => switch (k) {
      ClipKind.text => '文字',
      ClipKind.image => '图片',
      ClipKind.files => '文件',
      ClipKind.data => '数据',
      ClipKind.unsupported => '其他',
    };
