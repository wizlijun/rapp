import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/term_model.dart';
import 'package:rapp/term/term_wire.dart';

TermScreen scr(List<String> rows,
        {int rev = 1,
        int? hist,
        int? limit,
        bool full = true,
        bool more = false,
        bool alt = false,
        int cols = 80,
        Set<int> wrapped = const {},
        String pane = '%1'}) =>
    TermScreen(
      pane: pane,
      rev: rev,
      cols: cols,
      rows: rows.length,
      cx: 0,
      cy: 0,
      cursor: true,
      alt: alt,
      full: full,
      more: more,
      lines: [for (var i = 0; i < rows.length; i++) (i, rows[i])],
      hist: hist,
      limit: limit,
      wrapped: wrapped,
    );

TermScreen scrRows(Map<int, String> lines,
        {required int rows,
        int rev = 1,
        int? hist,
        int? limit,
        bool full = false,
        bool more = false,
        int cols = 80,
        String pane = '%1'}) =>
    TermScreen(
      pane: pane,
      rev: rev,
      cols: cols,
      rows: rows,
      cx: 0,
      cy: 0,
      cursor: true,
      alt: false,
      full: full,
      more: more,
      lines: [for (final e in lines.entries) (e.key, e.value)],
      hist: hist,
      limit: limit,
    );

void main() {
  test('parts are put together and only the last one is acked', () {
    final m = TermModel()..expect('%1');
    expect(m.apply(scr(['a', 'b'], rev: 1, more: true)), isNull);
    expect(m.screen.map((l) => l.text), isEmpty); // 还没换屏
    expect(m.apply(scrRows({1: 'B'}, rows: 2, rev: 1, full: false)), 1);
    expect(m.screen.map((l) => l.text), ['a', 'B']);
  });
  test('a screen of another pane is acked and ignored', () {
    final m = TermModel()..expect('%2');
    expect(m.apply(scr(['x'], rev: 4, pane: '%1')), 4);
    expect(m.screen, isEmpty);
  });
  test('a screen before any view is acked and ignored', () {
    final m = TermModel();
    expect(m.apply(scr(['x'], rev: 3, more: true)), isNull);
    expect(m.apply(scr(['x'], rev: 3)), 3);
    expect(m.screen, isEmpty);
  });
  test('a partial update replaces only its rows and keeps the other line objects', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['a', 'b', 'c'], rev: 1));
    final before = m.screen;
    m.apply(scrRows({1: 'X'}, rows: 3, rev: 2));
    expect(m.screen.map((l) => l.text), ['a', 'X', 'c']);
    expect(identical(m.screen[0], before[0]), isTrue);
    expect(identical(m.screen[1], before[1]), isFalse);
    expect(identical(m.screen[2], before[2]), isTrue);
  });
  test('new output does not move the view while reading history', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['1', '2', '3'], rev: 1, hist: 10, limit: 2000));
    m.scrollBy(5);
    m.apply(scr(['2', '3', '4'], rev: 2, hist: 11, limit: 2000));
    expect((m.offset, m.newOutput), (6.0, true));
    expect(m.lineAt(-1)?.text, '1'); // 移进历史的那一行从旧屏来
  });
  test('at the bottom new output neither scrolls nor flags', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['1', '2', '3'], rev: 1, hist: 10, limit: 2000));
    m.apply(scr(['2', '3', '4'], rev: 2, hist: 11, limit: 2000));
    expect((m.offset, m.newOutput), (0.0, false));
  });
  test('a full history still shifts by the overlap', () {
    final m = TermModel()..expect('%1');
    final shifts = <int>[];
    m.onShift = shifts.add;
    m.apply(scr(['a', 'b', 'c', 'd'], rev: 1, hist: 2000, limit: 2000));
    m.scrollBy(10);
    m.apply(scr(['c', 'd', 'e', 'f'], rev: 2, hist: 2000, limit: 2000));
    // Split: a record holding a List compares the list by identity.
    expect(shifts, [2]);
    expect(m.offset, 12.0);
    expect([m.lineAt(-2)?.text, m.lineAt(-1)?.text], ['a', 'b']);
  });
  test('a full history with no overlap does not shift', () {
    final m = TermModel()..expect('%1');
    final shifts = <int>[];
    m.onShift = shifts.add;
    m.apply(scr(['a', 'b', 'c'], rev: 1, hist: 2000, limit: 2000));
    m.apply(scr(['x', 'y', 'z'], rev: 2, hist: 2000, limit: 2000));
    m.apply(scr(['x', '', ''], rev: 3, hist: 2000, limit: 2000));
    m.apply(scr(['', '', 'q'], rev: 4, hist: 2000, limit: 2000)); // 只有空行对得上，不算
    expect(shifts, isEmpty);
  });
  test('rows that do not line up move into history as unknown and are fetched', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['a', 'b'], rev: 1, hist: 10, limit: 2000));
    m.apply(scr(['z', 'w'], rev: 2, hist: 11, limit: 2000));
    expect(m.lineAt(-1), isNull);
    m.scrollBy(1);
    expect(m.wantHistory(), (before: 0, lines: 1));
    m.applyHistory(const TermHistory(pane: '%1', before: 0, lines: ['q'], hist: 11));
    expect(m.lineAt(-1)?.text, 'q');
    expect(m.wantHistory(), (before: 1, lines: 500));
  });
  test('history is asked for in batches and placed above the screen', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['s'], rev: 1, hist: 600, limit: 2000));
    m.scrollBy(1);
    expect(m.wantHistory(), (before: 0, lines: 500));
    expect(m.wantHistory(), isNull); // 一个在途
    m.applyHistory(const TermHistory(pane: '%1', before: 0, lines: ['h2', 'h1'], hist: 600, wrapped: {}));
    expect([m.lineAt(-1)?.text, m.lineAt(-2)?.text], ['h1', 'h2']);
  });
  test('history is placed by how much the history grew since', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['s'], rev: 1, hist: 12, limit: 2000));
    m.wantHistory();
    m.applyHistory(const TermHistory(pane: '%1', before: 0, lines: ['x'], hist: 11));
    expect([m.lineAt(-1)?.text, m.lineAt(-2)?.text], [null, 'x']);
  });
  test('a history reply of another pane is dropped but ends the request', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['s'], rev: 1, hist: 600, limit: 2000));
    expect(m.wantHistory(), isNotNull);
    m.applyHistory(const TermHistory(pane: '%2', before: 0, lines: ['o'], hist: 600));
    expect(m.lineAt(-1), isNull);
    expect(m.wantHistory(), (before: 0, lines: 500));
  });
  test('the whole history fetched is the top', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['s'], rev: 1, hist: 2, limit: 2000));
    m.wantHistory();
    m.applyHistory(const TermHistory(pane: '%1', before: 0, lines: ['b', 'a'], hist: 2));
    expect((m.historyTop, m.scrollMax), (true, 2));
    m.scrollBy(5);
    expect(m.offset, 2.0);
    expect(m.wantHistory(), isNull);
  });
  test('an old device without hist still scrolls until the top', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['s'], rev: 1));
    expect(m.scrollMax, 1);
    m.scrollBy(1);
    m.applyHistory(const TermHistory(pane: '%1', before: 0, lines: ['h'], hist: null, wrapped: {}));
    m.applyHistory(const TermHistory(pane: '%1', before: 1, lines: [], hist: null, wrapped: {}));
    expect((m.historyTop, m.scrollMax), (true, 1));
  });
  test('wrapped rows are known on the screen and in history', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['a', 'b'], rev: 1, hist: 3, limit: 2000, wrapped: {0}));
    expect([m.wrappedAt(0), m.wrappedAt(1)], [true, false]);
    m.wantHistory();
    m.applyHistory(const TermHistory(pane: '%1', before: 0, lines: ['h3', 'h2', 'h1'], hist: 3, wrapped: {0, 2}));
    expect([m.wrappedAt(-3), m.wrappedAt(-2), m.wrappedAt(-1)], [true, false, false]);
  });
  test('a size change clears history and returns to the bottom', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['a', 'b'], rev: 1, hist: 10, limit: 2000));
    m.apply(scr(['b', 'c'], rev: 2, hist: 11, limit: 2000));
    m.scrollBy(3);
    expect(m.lineAt(-1)?.text, 'a');
    m.apply(scr(['b', 'c', 'd'], rev: 3, hist: 11, limit: 2000));
    expect(m.offset, 0.0);
    expect(m.lineAt(-1), isNull);
  });
  test('switching panes clears history and the view', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['a', 'b'], rev: 1, hist: 10, limit: 2000));
    m.apply(scr(['b', 'c'], rev: 2, hist: 11, limit: 2000));
    m.scrollBy(3);
    m.expect('%2');
    expect((m.offset, m.lineAt(-1)), (0.0, null));
    expect(m.screen, isEmpty);
  });
  test('alternate screen: nothing moves into history', () {
    final m = TermModel()..expect('%1');
    final shifts = <int>[];
    m.onShift = shifts.add;
    m.apply(scr(['a', 'b'], rev: 1, hist: 10, limit: 2000, alt: true));
    m.apply(scr(['b', 'c'], rev: 2, hist: 11, limit: 2000, alt: true));
    expect(shifts, isEmpty);
    expect(m.lineAt(-1), isNull);
  });
  test('scrolling is clamped and toBottom clears new output', () {
    final m = TermModel()..expect('%1');
    m.apply(scr(['1', '2'], rev: 1, hist: 4, limit: 2000));
    m.scrollBy(-3);
    expect(m.offset, 0.0);
    m.scrollBy(2.5);
    m.apply(scr(['1', 'x'], rev: 2, hist: 4, limit: 2000));
    expect((m.offset, m.newOutput), (2.5, true));
    m.toBottom();
    expect((m.offset, m.newOutput), (0.0, false));
  });
}
