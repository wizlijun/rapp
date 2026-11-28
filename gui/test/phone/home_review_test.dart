import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/phone/home_model.dart';
import 'package:rapp/ui/main_state.dart';

TermRow row(String id, String state, {int since = 1, String? msg}) =>
    TermRow(id, id, 'zsh', null, 1, 0, 100, false, false,
        ps: TermPs(state, kind: state == 'blocked' ? 'permission' : null, msg: msg, since: since, seq: 1), fg: 'claude');

NeedItem blocked(String dev, String term, int at) =>
    NeedItem(NeedKind.terminal, term, '$term @ $dev：等确认', 1, device: dev, title: term, at: at);

Map<String, Object?> emit(String key, String text, int at, {String eid = 'e1', String session = 't'}) =>
    {'t': 'emit', 'level': 'info', 'id': 'A', 'key': key, 'session': session, 'text': text, 'at': at, 'eid': eid};

HomeModel build(List<Map<String, Object?>> rows, String state, {int since = 1000, String? msg = 'approve plan'}) =>
    buildHome(
      needs: state == 'blocked' ? [blocked('A', 't', since)] : const [],
      lists: {
        'A': TermList('A', terms: [row('t', state, since: since, msg: state == 'blocked' ? msg : null)]),
      },
      serviceSessions: const [],
      serviceRows: rows,
      fromService: true,
      offline: const {},
      gotIt: const {},
      deviceName: (id) => 'name-$id',
      sessionKeyOf: (d, t) => '$d/$t',
    );

void main() {
  test('agent points attach to the plan card', () {
    final m = build([emit('plan:t', '- a\n- b\n- c', 1010)], 'blocked');
    final it = m.items.single;
    expect(it.kind, HomeKind.waiting);
    expect(it.points, ['a', 'b', 'c']);
    expect(it.pointsBy, PointsBy.agent);
    expect(it.pointsEid, 'e1');
    expect(it.line, '出了计划，等你点头');
    expect(m.items.where((i) => i.kind == HomeKind.message), isEmpty);
  });

  test('rule points used only without agent points', () {
    var m = build([emit('plan-rule:t', 'r1\nr2', 1010, eid: 'r')], 'blocked');
    expect(m.items.single.pointsBy, PointsBy.rule);
    expect(m.items.single.points, ['r1', 'r2']);
    m = build([emit('plan-rule:t', 'r1', 1010, eid: 'r'), emit('plan:t', 'a1', 1005, eid: 'a')], 'blocked');
    expect(m.items.single.pointsBy, PointsBy.agent);
    expect(m.items.single.points, ['a1']);
    expect(m.items.length, 1);
  });

  test('points within 120 s before the wait still attach; older ones show as a message', () {
    var m = build([emit('plan:t', 'a', 900)], 'blocked');
    expect(m.items.first.points, ['a']);
    m = build([emit('plan:t', 'a', 879)], 'blocked');
    expect(m.items.first.points, isNull);
    expect(m.items.last.kind, HomeKind.message);
  });

  test('stale plan points are hidden', () {
    final m = build([emit('plan:t', 'a', 500)], 'working', since: 1000);
    expect(m.items, isEmpty);
  });

  test('plan points of a session not waiting show as a message', () {
    final m = build([emit('plan:t', 'a', 1500)], 'working', since: 1000);
    expect(m.items.single.kind, HomeKind.message);
    expect(m.items.single.line, 'a');
  });

  test('pointLines keeps three', () {
    expect(pointLines('- a\n* b\n\n1. c\n2) d\n3. e'), ['a', 'b', 'c']);
    expect(pointLines('  \n'), isEmpty);
  });

  test('bare approve plan reads 出了计划，等你点头', () {
    final m = build(const [], 'blocked');
    expect(m.items.single.line, '出了计划，等你点头');
    expect(m.items.single.points, isNull);
  });
}
