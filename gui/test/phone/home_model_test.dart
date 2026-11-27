import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/phone/home_model.dart';
import 'package:rapp/ui/main_state.dart';

TermRow row(String id, String state,
        {bool unread = false, bool dead = false, int since = 1, int seq = 1, String? kind, String? msg, int? progress}) =>
    TermRow(id, id, 'zsh', null, 1, 0, 100, dead, unread,
        ps: TermPs(state, kind: kind, msg: msg, since: since, seq: seq, progress: progress), fg: 'codex');

NeedItem blocked(String dev, String term, int at) =>
    NeedItem(NeedKind.terminal, term, '$term @ $dev：等确认', 1, device: dev, title: term, at: at);

HomeModel build({
  List<NeedItem> needs = const [],
  Map<String, TermList> lists = const {},
  List<(String, Map<String, Object?>)> sessions = const [],
  List<Map<String, Object?>> rows = const [],
  bool fromService = false,
  Set<String> offline = const {},
  Set<String> gotIt = const {},
}) =>
    buildHome(
      needs: needs,
      lists: lists,
      serviceSessions: sessions,
      serviceRows: rows,
      fromService: fromService,
      offline: offline,
      gotIt: gotIt,
      deviceName: (id) => 'name-$id',
      sessionKeyOf: (d, t) => '$d/$t',
    );

void main() {
  test('order follows H5', () {
    final m = build(
      needs: [
        blocked('A', 't30', 30),
        blocked('A', 't5', 5),
        const NeedItem(NeedKind.device, 'B', 'B 离线', 1, at: 7),
      ],
      lists: {
        'A': TermList('A', terms: [
          row('t30', 'blocked', since: 30),
          row('t5', 'blocked', since: 5),
          row('d', 'done', unread: true, since: 10),
          row('e', 'error', unread: true, since: 20),
        ]),
      },
    );
    expect(m.items.map((i) => i.kind), [HomeKind.waiting, HomeKind.waiting, HomeKind.error, HomeKind.done, HomeKind.device]);
    expect(m.items.take(2).map((i) => i.since), [5, 30]);
  });

  test('one terminal one item', () {
    final m = build(
      needs: [blocked('A', 't', 3)],
      lists: {
        'A': TermList('A', terms: [row('t', 'blocked', unread: true)]),
      },
    );
    expect(m.items.map((i) => i.kind), [HomeKind.waiting]);
    expect(m.items.single.id, 'term\nA\nt');
  });

  test('no service: local lists only', () {
    final m = build(
      sessions: [('B', {'session': 's', 'state': 'done', 'seq': 1, 'since': 1, 'at': 5})],
      rows: [
        {'t': 'emit', 'level': 'info', 'text': 'hi', 'eid': 'e1', 'at': 1},
      ],
      fromService: false,
    );
    expect(m.items, isEmpty);
    expect(m.doneUnseen, 0);
  });

  test('service fills devices without a list', () {
    final m = build(
      lists: {
        'A': TermList('A', terms: [row('t', 'idle')]),
      },
      sessions: [
        ('B', {'session': 's', 'state': 'error', 'seq': 2, 'since': 4, 'at': 5, 'msg': 'boom'}),
        ('A', {'session': 'x', 'state': 'done', 'seq': 2, 'since': 4, 'at': 5}),
      ],
      fromService: true,
    );
    expect(m.items.length, 1);
    expect(m.items.single.kind, HomeKind.error);
    expect(m.items.single.device, 'name-B');
    expect(m.items.single.line, 'boom');
  });

  test('service session already seen is not shown', () {
    final m = build(
      sessions: [('B', {'session': 's', 'state': 'done', 'seq': 1, 'since': 1, 'at': 5, 'seen': 6})],
      fromService: true,
    );
    expect(m.items, isEmpty);
  });

  test('empty msg gets the go-look line', () {
    final m = build(
      needs: [blocked('A', 't', 3)],
      lists: {
        'A': TermList('A', terms: [row('t', 'blocked', kind: 'permission', msg: ''), row('d', 'done', unread: true, msg: '')]),
      },
    );
    final w = m.items.firstWhere((i) => i.kind == HomeKind.waiting);
    expect(w.line, '它没说要做什么。点上面的字进去看。');
    expect(w.what, '在等确认');
    final d = m.items.firstWhere((i) => i.kind == HomeKind.done);
    expect(d.line, '做完了');
  });

  test('got it hides until seq changes', () {
    TermList list(int seq) => TermList('A', terms: [row('d', 'done', unread: true, seq: seq)]);
    final key = {'term\nA\nd\n3'};
    expect(build(lists: {'A': list(3)}, gotIt: key).items, isEmpty);
    expect(build(lists: {'A': list(4)}, gotIt: key).items.length, 1);
    expect(build(lists: {'A': list(3)}).items.single.gotItKey, 'term\nA\nd\n3');
  });

  test('items without a seq are hidden by id alone', () {
    final m = build(
      needs: [const NeedItem(NeedKind.session, 'B/app', 'App @ B 已断开：网络', 1, at: 7)],
      gotIt: {'session\nB/app'},
    );
    expect(m.items, isEmpty);
  });

  test('counts', () {
    final m = build(
      needs: [blocked('A', 'w1', 1), blocked('A', 'w2', 2), blocked('A', 'w3', 3)],
      lists: {
        'A': TermList('A', terms: [
          row('w1', 'blocked'),
          row('w2', 'blocked'),
          row('w3', 'blocked'),
          for (var i = 0; i < 5; i++) row('k$i', 'working', progress: 40),
          row('d1', 'done', unread: true, since: 100),
          row('d2', 'done', unread: true, since: 300),
          row('d3', 'done', since: 200),
          row('d4', 'done', since: 50),
        ]),
      },
    );
    expect(m.waiting, 3);
    expect(m.working.length, 5);
    expect(m.working.first.progress, 40);
    expect(m.doneUnseen, 2);
    expect(m.recentDone.map((d) => d.id), ['term\nA\nd2', 'term\nA\nd1']);
  });

  test('messages: only from service, cleared and handled ones leave', () {
    final m = build(
      fromService: true,
      rows: [
        {'t': 'emit', 'level': 'clear', 'key': 'k', 'at': 9, 'eid': 'c'},
        {'t': 'emit', 'level': 'ask', 'key': 'k', 'text': 'plan?', 'at': 5, 'eid': 'e1'},
        {'t': 'emit', 'level': 'info', 'text': 'hi', 'at': 6, 'eid': 'e2', 'handled': true},
        {'t': 'emit', 'level': 'done', 'text': '', 'at': 7, 'eid': 'e3'},
        {'t': 'emit', 'level': 'info', 'text': 'fyi', 'at': 8, 'eid': 'e4'},
      ],
    );
    expect(m.items.map((i) => i.id), ['msg\ne3', 'msg\ne4']);
    expect(m.items.first.line, '做完了');
    expect(m.items.every((i) => i.button == HomeButton.gotIt), isTrue);
  });

  test('seen error does not show', () {
    final m = build(
      lists: {
        'A': TermList('A', terms: [row('e', 'error', unread: false), row('e2', 'error', unread: true)]),
      },
      sessions: [('B', {'session': 's', 'state': 'error', 'seq': 1, 'since': 1, 'at': 5, 'seen': 6})],
      fromService: true,
    );
    expect(m.items.map((i) => i.id), ['term\nA\ne2']);
  });

  test('recent done is unseen only', () {
    final m = build(
      lists: {
        'A': TermList('A', terms: [
          row('d1', 'done', unread: true, since: 100),
          row('d2', 'done', since: 200),
          row('d3', 'done', unread: true, since: 300, seq: 9),
        ]),
      },
      sessions: [
        ('B', {'session': 's1', 'state': 'done', 'seq': 1, 'since': 150, 'at': 150}),
        ('B', {'session': 's2', 'state': 'done', 'seq': 1, 'since': 250, 'at': 250, 'seen': 260}),
      ],
      fromService: true,
      gotIt: {'term\nA\nd3\n9'},
    );
    expect(m.recentDone.map((d) => d.id), ['term\nB\ns1', 'term\nA\nd1']);
    expect(m.doneUnseen, 2);
  });

  test('waiting order uses ps.since, not the first-seen at', () {
    final m = build(
      needs: [blocked('A', 'late', 100), blocked('A', 'early', 100)],
      lists: {
        'A': TermList('A', terms: [row('late', 'blocked', since: 50), row('early', 'blocked', since: 10)]),
      },
    );
    expect(m.items.map((i) => i.id), ['term\nA\nearly', 'term\nA\nlate']);
  });

  test('got it on device and resource returns with a new seq', () {
    NeedItem dev(int seq) => NeedItem(NeedKind.device, 'B', 'B 离线', seq, at: 7);
    NeedItem res(int seq) => NeedItem(NeedKind.resource, 'B\ncpu', 'B cpu 高', seq, device: 'B', title: 'cpu', at: 7);
    final d = build(needs: [dev(1)]).items.single;
    expect(d.gotItKey, 'device\nB\n1');
    expect(build(needs: [dev(1)], gotIt: {d.gotItKey}).items, isEmpty);
    expect(build(needs: [dev(2)], gotIt: {d.gotItKey}).items.length, 1);
    final r = build(needs: [res(1)]).items.single;
    expect(build(needs: [res(1)], gotIt: {r.gotItKey}).items, isEmpty);
    expect(build(needs: [res(2)], gotIt: {r.gotItKey}).items.length, 1);
  });

  test('recent done keeps 3, newest first', () {
    final m = build(
      lists: {
        'A': TermList('A', terms: [for (var i = 1; i <= 5; i++) row('d$i', 'done', unread: true, since: i * 10)]),
      },
    );
    expect(m.doneUnseen, 5);
    expect(m.recentDone.map((d) => d.id), ['term\nA\nd5', 'term\nA\nd4', 'term\nA\nd3']);
  });

  test('buttons', () {
    final m = build(
      needs: [const NeedItem(NeedKind.session, 'B/app', 'App @ B 已断开：网络', 1, at: 3)],
      lists: {
        'A': TermList('A', terms: [row('e', 'error', unread: true)]),
      },
      fromService: true,
      rows: [
        {'t': 'emit', 'level': 'ask', 'text': 'ok?', 'at': 5, 'eid': 'a1'},
        {'t': 'emit', 'level': 'clear', 'key': 'k', 'at': 4, 'eid': 'c'},
        {'t': 'emit', 'level': 'info', 'key': 'k', 'text': 'after', 'at': 6, 'eid': 'i1'},
      ],
    );
    HomeButton of(HomeKind k, [String? id]) => m.items.firstWhere((i) => i.kind == k && (id == null || i.id == id)).button;
    expect(of(HomeKind.error), HomeButton.goLook);
    expect(of(HomeKind.disconnected), HomeButton.reconnect);
    expect(of(HomeKind.message, 'msg\na1'), HomeButton.goLook);
    expect(of(HomeKind.message, 'msg\ni1'), HomeButton.gotIt);
  });
}
