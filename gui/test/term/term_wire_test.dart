import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/term_id.dart';
import 'package:rapp/term/term_wire.dart';

void main() {
  test('term ids parse once, names with colons kept', () {
    expect(parseTermId('term:tmux@gpu1:a:b'), (backend: 'tmux', host: 'gpu1', name: 'a:b'));
    expect(parseTermId('term:tmux:work')?.host, isNull);
    expect(parseTermId('com.apple.Terminal'), isNull);
    expect(isTermApp('term:tmux:work'), isTrue);
    expect(termDisplayName('train', 'gpu1'), 'train @gpu1');
  });
  test('a screen from an old device parses with defaults', () {
    final m = parseTermOut({'t': 'screen', 'pane': '%1', 'rev': 3, 'cols': 80, 'rows': 2, 'cx': 0, 'cy': 0,
        'cursor': true, 'alt': false, 'full': true, 'more': false, 'lines': [[0, 'a'], [1, 'b']]}) as TermScreen;
    expect((m.hist, m.limit, m.shape), (null, null, ''));
    expect(m.wrapped, isEmpty);
    expect(m.lines, [(0, 'a'), (1, 'b')]);
  });
  test('bad messages are null, not exceptions', () {
    expect(parseTermOut({'t': 'screen', 'pane': '%1'}), isNull);
    expect(parseTermOut({'t': 'nope'}), isNull);
    expect(parseTermOut('x'), isNull);
    expect(parseTermOut({'t': 'pasted', 'ok': 'yes'}), isNull);
  });
  test('tab labels number windows and panes from 1', () {
    TermPane p(String id, String win, String cmd, {bool dead = false}) => TermPane(id: id, win: win, window: 'w',
        title: '', command: cmd, cols: 80, rows: 24, dead: dead, active: false);
    expect(tabLabels([p('%1', '@1', 'claude'), p('%2', '@2', 'nvim'), p('%3', '@2', 'logs', dead: true)]),
        {'%1': '1 claude', '%2': '2.1 nvim', '%3': '2.2 logs · 已退出'});
  });
  test('tab labels group by window name when the device sends no win', () {
    TermPane p(String id, String window) => TermPane(
        id: id, window: window, title: '', command: 'sh', cols: 80, rows: 24, dead: false);
    expect(tabLabels([p('%1', 'a'), p('%2', 'b'), p('%3', 'b')]), {'%1': '1 sh', '%2': '2.1 sh', '%3': '2.2 sh'});
  });
  test('messages to the worker use the wire names', () {
    expect(viewMsg('%1', 120, 40), {'t': 'view', 'pane': '%1', 'cols': 120, 'rows': 40});
    expect(historyReq('%1', 500, 500), {'t': 'history', 'pane': '%1', 'before': 500, 'lines': 500});
    expect(ackMsg(7), {'t': 'ack', 'rev': 7});
    expect(refitMsg('%1', 80, 24), {'t': 'refit', 'pane': '%1', 'cols': 80, 'rows': 24});
  });
  test('every output message parses with its fields', () {
    final h = parseTermOut({'t': 'history', 'pane': '%1', 'before': 5, 'lines': ['x', 'y'], 'hist': 9, 'wrapped': [0]})
        as TermHistory;
    expect((h.pane, h.before, h.hist), ('%1', 5, 9));
    expect(h.lines, ['x', 'y']);
    expect(h.wrapped, {0});
    final ps = parseTermOut({'t': 'panes', 'panes': [
      {'id': '%12', 'window': 'w', 'title': 't', 'command': 'sh', 'cols': 80, 'rows': 24, 'dead': false, 'win': '@3', 'active': true},
      {'id': '%2', 'window': 'w', 'title': 't', 'command': 'sh', 'cols': 80, 'rows': 24, 'dead': true},
    ]}) as TermPanes;
    expect((ps.panes[0].number, ps.panes[0].win, ps.panes[0].active), (12, '@3', true));
    expect((ps.panes[1].win, ps.panes[1].active, ps.panes[1].dead), ('', false, true));
    final pa = parseTermOut({'t': 'pasted', 'ok': false, 'error': 'no'}) as TermPasted;
    expect((pa.ok, pa.error), (false, 'no'));
    expect((parseTermOut({'t': 'error', 'error': 'boom'}) as TermError).error, 'boom');
    final he = parseTermOut({'t': 'hello', 'v': 1, 'backend': 'tmux'}) as TermHello;
    expect((he.v, he.backend), (1, 'tmux'));
    final s = parseTermOut({'t': 'screen', 'pane': '%1', 'rev': 3, 'cols': 80, 'rows': 1, 'cx': 2, 'cy': 0,
        'cursor': true, 'alt': false, 'full': true, 'more': false, 'lines': [], 'hist': 4, 'limit': 100,
        'shape': 'bar', 'wrapped': [0, 2]}) as TermScreen;
    expect((s.hist, s.limit, s.shape), (4, 100, 'bar'));
    expect(s.wrapped, {0, 2});
  });
}
