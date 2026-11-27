/// The phone home page's list of things, as a pure function of what the app already knows (V1b, N3, I1, C17).
///
/// Where each kind comes from:
/// - waiting / session dropped / device offline / resource warning: only from [needs]. `MainState.needs` already
///   merges the two sources (this machine computes what it can; the center service only fills devices this machine has
///   no terminal list for), so the phone does not merge them a second time.
/// - error / done-unseen: one rule for both sources. A device in [lists] uses its [TermRow]: `ps.state` is `error` or
///   `done`, and `unread`. A device not in [lists] counts only when [fromService]; then [serviceSessions] rows count:
///   `state` is `error` / `done` and `seen` is missing or older than `at`.
/// - message: only when [fromService]; `emit` rows of [serviceRows] with `level` ask / info / done, not `handled`,
///   and not followed by a `clear` with the same `key`.
/// - [lists] covers terminals only, so a device in [lists] still gets its app sessions from [needs] alone; service
///   app-session rows of such a device are dropped on purpose.
/// - One terminal, one item (C17): a terminal that is waiting never also shows its error / done.
///
/// Ids are stable while the state changes (C17): `term\n<device>\n<term>`, `app\n<record key>`,
/// `session\n<record key>`, `device\n<device>`, `resource\n<device>\n<item>`, `msg\n<eid>`.
///
/// "Got it" ([gotIt]) is remembered by the phone for this run only, because without a center service the
/// terminal's own unread can only be cleared by looking at it. An entry is `'<item id>\n<seq>'`, where seq is the
/// program status `seq` (a terminal's `ps.seq`, a service session row's `seq`) or, for device offline and resource,
/// the need's `seq`. Message, dropped session and app have none and use their id alone. A new seq brings the item back.
/// The UI stores `HomeItem.gotItKey`. `recentDone` holds only the unseen done items that are shown.
library;

import '../hub_client.dart';
import '../ui/lamp.dart';
import '../ui/main_state.dart';

enum HomeKind { waiting, error, done, disconnected, device, resource, message }

enum HomeButton { goLook, reconnect, gotIt }

/// What a card says when the program gave no message.
const goLookLine = '它没说要做什么。点上面的字进去看。';

class HomeItem {
  const HomeItem({
    required this.kind,
    required this.id,
    required this.lamp,
    required this.what,
    required this.program,
    required this.device,
    required this.line,
    required this.since,
    required this.button,
    this.sessionKey,
    this.need,
    this.eid,
    this.seq,
  });

  final HomeKind kind;

  /// One per thing; does not change when its state changes.
  final String id;
  final Lamp lamp;

  /// Which kind of thing: 在等确认 / 在问你 / 出错了 / 做完了 / 断开了 / 离线 / 资源 / 消息.
  final String what;
  final String program, device, line;

  /// Unix seconds, for ordering: smaller first.
  final int since;

  /// The MainState entry key to open; null when it cannot be opened.
  final String? sessionKey;
  final NeedItem? need;
  final HomeButton button;

  /// The queue row of a message, for 「知道了」.
  final String? eid;

  /// The status seq in the [HomeModel] `gotIt` key; null when the item has none.
  final int? seq;

  /// What 「知道了」 stores.
  String get gotItKey => seq == null ? id : '$id\n$seq';
}

class WorkRow {
  const WorkRow(this.id, this.program, this.device, this.since, {this.progress, this.sessionKey});
  final String id, program, device;
  final int since;
  final double? progress;
  final String? sessionKey;
}

class DoneRow {
  const DoneRow(this.id, this.program, this.device, this.line, this.at, {this.sessionKey});
  final String id, program, device, line;
  final int at;
  final String? sessionKey;
}

class HomeModel {
  const HomeModel(this.items, this.waiting, this.working, this.doneUnseen, this.recentDone);
  final List<HomeItem> items;
  final int waiting;
  final List<WorkRow> working;
  final int doneUnseen;
  final List<DoneRow> recentDone;
}

typedef _Row = Map<String, Object?>;

int _int(Object? v) => v is num ? v.toInt() : 0;
String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;

String _whatWaiting(String? kind) => switch (kind) {
      'permission' => '在等确认',
      'question' => '在问你',
      'auth' => '要登录',
      _ => '在等你',
    };

/// The kind of an ask from the word `termAskWord` put in a need's text (an app's inferred block has no ps).
String? _kindOfText(String text) {
  if (text.contains('等确认')) return 'permission';
  if (text.contains('在提问')) return 'question';
  if (text.contains('要登录')) return 'auth';
  return null;
}

HomeModel buildHome({
  required List<NeedItem> needs,
  required Map<String, TermList> lists,
  required Iterable<(String id, Map<String, Object?> row)> serviceSessions,
  required Iterable<Map<String, Object?>> serviceRows,
  required bool fromService,
  required Set<String> offline,
  required Set<String> gotIt,
  required String Function(String id) deviceName,
  required String? Function(String device, String term) sessionKeyOf,
}) {
  final svc = fromService ? serviceSessions.toList() : const <(String, _Row)>[];
  _Row? svcRow(String device, String session) {
    for (final (id, r) in svc) {
      if (id == device && r['session'] == session) return r;
    }
    return null;
  }

  // (item, group order) so the final sort is by group, then since, then arrival.
  final out = <(HomeItem, int)>[];
  final taken = <String>{};
  void add(HomeItem it, int group) {
    if (gotIt.contains(it.gotItKey)) return;
    out.add((it, group));
  }

  // 1. Needs.
  for (final n in needs) {
    switch (n.kind) {
      case NeedKind.terminal:
      case NeedKind.app:
        final isTerm = n.kind == NeedKind.terminal;
        final dev = n.device ?? '';
        final id = isTerm ? 'term\n$dev\n${n.target}' : 'app\n${n.target}';
        TermRow? local;
        if (isTerm) {
          for (final r in lists[dev]?.terms ?? const <TermRow>[]) {
            if (r.id == n.target) local = r;
          }
        }
        final sr = isTerm && local == null ? svcRow(dev, n.target) : null;
        final psKind = local?.ps?.kind ?? _s(sr?['kind']) ?? _kindOfText(n.text);
        final msg = local?.ps?.msg ?? _s(sr?['msg']) ?? '';
        final program = isTerm
            ? (local?.ps?.app ?? local?.fg ?? _s(sr?['app']) ?? _s(sr?['fg']) ?? n.title ?? '')
            : (n.title ?? '');
        final seq = isTerm ? (local?.ps?.seq ?? (sr != null ? _int(sr['seq']) : null)) : null;
        // The program's own since first: `n.at` is when this app first saw the need, equal for all after a cold start.
        final psSince = local?.ps?.since ?? _int(sr?['since']);
        final since = psSince > 0 ? psSince : n.at;
        taken.add(id);
        add(
          HomeItem(
            kind: HomeKind.waiting,
            id: id,
            lamp: Lamp.waiting,
            what: _whatWaiting(psKind),
            program: program,
            device: deviceName(dev),
            line: msg.isEmpty ? goLookLine : msg,
            since: since,
            sessionKey: isTerm ? sessionKeyOf(dev, n.target) : n.target,
            need: n,
            button: HomeButton.goLook,
            seq: seq,
          ),
          0,
        );
      case NeedKind.session:
        final at = n.text.indexOf(' @ ');
        final reason = n.text.indexOf('已断开：');
        final dev = n.device ?? (n.target.contains('/') ? n.target.substring(0, n.target.indexOf('/')) : '');
        add(
          HomeItem(
            kind: HomeKind.disconnected,
            id: 'session\n${n.target}',
            lamp: Lamp.disconnected,
            what: '断开了',
            program: at > 0 ? n.text.substring(0, at) : '',
            device: deviceName(dev),
            line: reason >= 0 ? n.text.substring(reason + 4) : n.text,
            since: n.at,
            sessionKey: n.target,
            need: n,
            button: HomeButton.reconnect,
          ),
          3,
        );
      case NeedKind.device:
        add(
          HomeItem(
            kind: HomeKind.device,
            id: 'device\n${n.target}',
            lamp: Lamp.offline,
            what: '离线',
            program: '',
            device: deviceName(n.target),
            line: n.text,
            since: n.at,
            need: n,
            button: HomeButton.gotIt,
            seq: n.seq,
          ),
          5,
        );
      case NeedKind.resource:
        add(
          HomeItem(
            kind: HomeKind.resource,
            id: 'resource\n${n.target}',
            lamp: Lamp.idle,
            what: '资源',
            program: n.title ?? '',
            device: deviceName(n.device ?? ''),
            line: n.text,
            since: n.at,
            need: n,
            button: HomeButton.gotIt,
            seq: n.seq,
          ),
          5,
        );
    }
  }

  // 2. Error / done / working, from one list of candidates per terminal.
  final working = <WorkRow>[];

  void candidate({
    required String id,
    required String state,
    required bool unseen,
    required String program,
    required String dev,
    required String msg,
    required int since,
    required int seq,
    required String? key,
    int? progress,
  }) {
    final device = deviceName(dev);
    if (state == 'working') {
      working.add(WorkRow(id, program, device, since, progress: progress?.toDouble(), sessionKey: key));
      return;
    }
    if (!unseen || taken.contains(id)) return;
    final isErr = state == 'error';
    add(
      HomeItem(
        kind: isErr ? HomeKind.error : HomeKind.done,
        id: id,
        lamp: isErr ? Lamp.disconnected : Lamp.idle,
        what: isErr ? '出错了' : '做完了',
        program: program,
        device: device,
        line: msg.isEmpty ? (isErr ? '出错了' : '做完了') : msg,
        since: since,
        sessionKey: key,
        button: isErr ? HomeButton.goLook : HomeButton.gotIt,
        seq: seq,
      ),
      isErr ? 1 : 2,
    );
  }

  for (final e in lists.entries) {
    if (offline.contains(e.key)) continue;
    for (final r in e.value.terms) {
      final ps = r.ps;
      if (r.dead || ps == null) continue;
      final since = ps.since > 0 ? ps.since : r.activity;
      candidate(
        id: 'term\n${e.key}\n${r.id}',
        state: ps.state,
        unseen: (ps.state == 'error' || ps.state == 'done') && r.unread,
        program: ps.app ?? r.fg ?? '',
        dev: e.key,
        msg: ps.msg ?? '',
        since: since,
        seq: ps.seq,
        key: sessionKeyOf(e.key, r.id),
        progress: ps.progress,
      );
    }
  }
  for (final (dev, r) in svc) {
    if (lists.containsKey(dev) || offline.contains(dev)) continue;
    final session = _s(r['session']);
    final state = r['state'];
    if (session == null || state is! String) continue;
    final at = _int(r['at']);
    final seen = r['seen'];
    final isApp = r['src'] == 'app';
    candidate(
      id: isApp ? 'app\n$dev/$session' : 'term\n$dev\n$session',
      state: state,
      unseen: (state == 'error' || state == 'done') && (seen == null || _int(seen) < at),
      program: _s(r['app']) ?? _s(r['fg']) ?? _s(r['name']) ?? '',
      dev: dev,
      msg: _s(r['msg']) ?? '',
      since: _int(r['since']) > 0 ? _int(r['since']) : at,
      seq: _int(r['seq']),
      key: isApp ? '$dev/$session' : sessionKeyOf(dev, session),
    );
  }

  // 3. Messages from the center service.
  if (fromService) {
    final rows = serviceRows.where((r) => r['t'] == 'emit').toList();
    for (final r in rows) {
      final level = r['level'];
      final eid = _s(r['eid']);
      if (eid == null || (level != 'ask' && level != 'info' && level != 'done')) continue;
      if (r['handled'] == true) continue;
      final key = _s(r['key']);
      if (key != null &&
          rows.any((c) => c['level'] == 'clear' && c['key'] == key && _int(c['at']) >= _int(r['at']) && c != r)) {
        continue;
      }
      final dev = _s(r['id']) ?? '';
      final session = _s(r['session']);
      final text = _s(r['text']) ?? '';
      add(
        HomeItem(
          kind: HomeKind.message,
          id: 'msg\n$eid',
          lamp: level == 'ask' ? Lamp.waiting : Lamp.idle,
          what: '消息',
          program: '',
          device: _s(r['device']) ?? (dev.isEmpty ? '' : deviceName(dev)),
          line: text.isEmpty ? (level == 'done' ? '做完了' : goLookLine) : text,
          since: _int(r['at']),
          sessionKey: session == null || dev.isEmpty ? null : sessionKeyOf(dev, session),
          button: level == 'ask' ? HomeButton.goLook : HomeButton.gotIt,
          eid: eid,
        ),
        4,
      );
    }
  }

  // Sort by group, then since (smaller first), then arrival.
  final indexed = [for (var i = 0; i < out.length; i++) (out[i].$1, out[i].$2, i)];
  indexed.sort((a, b) {
    final g = a.$2.compareTo(b.$2);
    if (g != 0) return g;
    final s = a.$1.since.compareTo(b.$1.since);
    return s != 0 ? s : a.$3.compareTo(b.$3);
  });
  final items = [for (final x in indexed) x.$1];
  working.sort((a, b) => a.since.compareTo(b.since));
  // 做完没看的 (H7): the unseen done items that show, newest first.
  final doneAll = [
    for (final i in items)
      if (i.kind == HomeKind.done) DoneRow(i.id, i.program, i.device, i.line, i.since, sessionKey: i.sessionKey),
  ]..sort((a, b) => b.at.compareTo(a.at));
  return HomeModel(
    items,
    items.where((i) => i.kind == HomeKind.waiting).length,
    working,
    doneAll.length,
    doneAll.take(3).toList(),
  );
}
