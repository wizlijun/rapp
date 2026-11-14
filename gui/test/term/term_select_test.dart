import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/sgr.dart';
import 'package:rapp/term/term_select.dart';

LineAt at(Map<int, String> rows) =>
    (y) => rows[y] == null ? null : parseRow(rows[y]!);

void main() {
  test(
    'a wrapped long command copies as one line, trailing spaces trimmed',
    () {
      final rows = {-1: 'cargo build --rel', 0: 'ease   ', 1: 'done  '};
      final s = select(const TermPoint(-1, 0), const TermPoint(1, 5), at(rows));
      expect(
        selectionText(s, at(rows), (y) => y == -1),
        'cargo build --release\ndone',
      );
    },
  );
  test('wide characters count by their first column', () {
    final rows = {0: '中文ab'};
    expect(
      selectionText(
        select(const TermPoint(0, 1), const TermPoint(0, 4), at(rows)),
        at(rows),
        (_) => false,
      ),
      '中文a',
    );
  });
  test('a block selection takes the same columns of every row', () {
    final rows = {0: '0123', 1: 'abcd'};
    final s = select(
      const TermPoint(0, 1),
      const TermPoint(1, 2),
      at(rows),
      block: true,
    );
    expect(selectionText(s, at(rows), (_) => true), '12\nbc');
  });
  test('the selection follows a shift and drops when its text changed', () {
    final before = {0: 'keep', 1: 'x'};
    final s = select(const TermPoint(0, 0), const TermPoint(0, 3), at(before));
    expect(shifted(s, 1, at({-1: 'keep'}))?.anchor.y, -1);
    expect(shifted(s, 1, at({-1: 'other'})), isNull);
  });
  test('select puts the earlier point first', () {
    final s = select(const TermPoint(1, 2), const TermPoint(0, 5), at({}));
    expect((s.anchor.y, s.anchor.x, s.head.y, s.head.x), (0, 5, 1, 2));
  });
  test('paths and urls are one word', () {
    final l = parseRow('see /usr/local/bin/tmux now');
    expect(wordAt(l, 8), (4, 23));
  });
  test('a url across a wrap is one link, trailing dot dropped', () {
    final rows = {0: 'go https://example.com/a', 1: 'b/c. ok'};
    final links = linksIn(0, 1, at(rows), (y) => y == 0);
    expect(links.map((l) => (l.y, l.x0, l.x1, l.url)).toList(), [
      (0, 3, 24, 'https://example.com/ab/c'),
      (1, 0, 3, 'https://example.com/ab/c'),
    ]);
  });
  test('an unpaired closing paren is dropped, a paired one kept', () {
    final rows = {0: '(see https://a.io/x) https://a.io/f(1)'};
    final links = linksIn(0, 0, at(rows), (_) => false);
    expect(links.map((l) => l.url).toList(), [
      'https://a.io/x',
      'https://a.io/f(1)',
    ]);
  });
  test('triple click takes the whole wrapped line', () {
    final rows = {0: 'aaaa', 1: 'bbbb', 2: 'cc'};
    final r = lineAtPoint(1, (y) => y == 0, at(rows));
    expect((r.$1.y, r.$1.x, r.$2.y, r.$2.x), (0, 0, 1, 3));
  });
  test(
    'selected characters exclude newlines',
    () => expect(selectedChars('中文\nab'), 4),
  );
}
