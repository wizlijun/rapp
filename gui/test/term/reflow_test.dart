import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/reflow.dart';
import 'package:rapp/term/sgr.dart';

const _b = '\x1b[1m', _r = '\x1b[0m';

List<ReadBlock> _rf(List<String> rows, {int cols = 40, int? screenFrom}) =>
    reflow(rows, cols: cols, screenFrom: screenFrom);

String _pad(String s, int w) => s + ' ' * (w - textWidth(s));

void main() {
  test('Chinese rows wrapped at the edge join with no space', () {
    final b = _rf([
      '⏺ 中位数对异常值不敏感，所以收入这种',
      '  偏态数据更适合用中位数来描述。',
    ]);
    expect(b, hasLength(1));
    expect(b.single.kind, ReadKind.prose);
    expect(b.single.speaker, Speaker.it);
    expect(b.single.text, '中位数对异常值不敏感，所以收入这种偏态数据更适合用中位数来描述。');
  });

  test('Latin rows join with a space; a row that left room ended for real', () {
    final b = _rf([
      '⏺ The median ignores the few huge values, so',
      '  it is robust.',
      '  Short line.',
    ], cols: 46);
    expect(b.single.lines, ['The median ignores the few huge values, so it is robust.', 'Short line.']);
  });

  test('protocol wrapped marks glue rows before guessing', () {
    final b = reflow(['⏺ abc', 'def'], wrapped: [true, false], cols: 5);
    expect(b.single.text, 'abcdef');
  });

  test('list items and headings start their own lines', () {
    final b = _rf([
      '⏺ $_b统计函数$_r',
      '',
      '  - mean(xs) 返回平均值，空列表时抛',
      '    ZeroDivisionError。',
      '  - median(xs) 返回中位数。',
    ]);
    expect(b.first.kind, ReadKind.heading);
    expect(b.first.text, '统计函数');
    // Each list item is its own block.
    expect(b.skip(1).map((x) => x.text), ['- mean(xs) 返回平均值，空列表时抛 ZeroDivisionError。', '- median(xs) 返回中位数。']);
  });

  test('code stays raw with its indentation', () {
    final b = _rf([
      '⏺ 示例：',
      '',
      '  def summary(xs):',
      '      return {',
      '          "mean": mean(xs),',
      '      }',
    ]);
    final raw = b.firstWhere((x) => x.kind == ReadKind.raw);
    expect(raw.lines, ['def summary(xs):', '    return {', '        "mean": mean(xs),', '    }']);
  });

  test('tables stay raw', () {
    final b = _rf([
      '  名称    │ 作用',
      '  ──────┼──────',
      '  mean  │ 平均',
    ]);
    expect(b.single.kind, ReadKind.raw);
    expect(b.single.lines.first, '名称    │ 作用');
  });

  test('a header-less diff stays raw', () {
    final b = _rf(['  -    return sum(xs) / len(xs)', '  +    n = len(xs)', '  +    if n == 0:']);
    expect(b.single.kind, ReadKind.raw);
  });

  test('spinners are dropped, timing lines kept as meta', () {
    final b = _rf([
      '⏺ 好的。',
      '',
      '✻ Pondering…',
      '⣯  Generating...',
      '• Working (3s • esc to interrupt)',
      '',
      '✻ Crunched for 27s',
    ]);
    expect(b.map((x) => x.kind), [ReadKind.prose, ReadKind.meta]);
    expect(b.last.text, '✻ Crunched for 27s');
  });

  test('the input box at the bottom of the screen is cut, and "me" / "it" follow turn marks', () {
    final rows = [
      '❯ 解释一下 stats.py',
      '',
      '⏺ 它有三个函数。',
      '',
      '─' * 40,
      '❯ ',
      '─' * 40,
      '  ? for shortcuts',
    ];
    final b = _rf(rows, screenFrom: 0);
    expect(b.map((x) => x.speaker), [Speaker.me, Speaker.it]);
    expect(b.map((x) => x.text), ['解释一下 stats.py', '它有三个函数。']);
  });

  test('a stretch printed twice into scrollback shows once', () {
    final part = ['⏺ 第一段。', '', '  第二段。', '  第三段。', '', '  第四段。', '  第五段。'];
    final b = _rf([...part, '', ...part]);
    expect(b.map((x) => x.text).join('|'), '第一段。|第二段。\n第三段。|第四段。\n第五段。');
  });

  test('a panel is unboxed', () {
    final b = _rf([
      '╭${'─' * 30}╮',
      '│${_pad(' Do you want to edit stats.py?', 30)}│',
      '│${_pad(' ❯ 1. Yes', 30)}│',
      '│${_pad('   2. No', 30)}│',
      '╰${'─' * 30}╯',
    ], cols: 32);
    expect(b.map((x) => x.text), ['Do you want to edit stats.py?', '❯ 1. Yes', '2. No']);
  });

  test('every sample reflows with no row lost to a crash', () {
    final dir = Directory('test/term/reflow_samples');
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    expect(files, isNotEmpty);
    for (final f in files) {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final ls = (j['lines'] as List).cast<List>();
      final b = reflow(
        [for (final l in ls) l[0] as String],
        wrapped: [for (final l in ls) l[1] as bool],
        cols: j['cols'] as int,
        screenFrom: ls.length - (j['rows'] as int),
      );
      expect(b, isNotEmpty, reason: f.path);
    }
  });

  test('reflowLines equals reflow on samples', () {
    final dir = Directory('test/term/reflow_samples');
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    expect(files, hasLength(17));
    for (final f in files) {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final ls = (j['lines'] as List).cast<List>();
      final rows = [for (final l in ls) l[0] as String];
      final from = ls.length - (j['rows'] as int);
      final a = reflow(rows, wrapped: [for (final l in ls) l[1] as bool], cols: j['cols'] as int, screenFrom: from);
      final b = reflowLines(
        [for (final r in rows) parseRow(r)],
        wrapped: {for (var i = 0; i < ls.length; i++) if (ls[i][1] as bool) i},
        cols: j['cols'] as int,
        screenFrom: from,
      );
      expect(b.map((x) => x.toString()).toList(), a.map((x) => x.toString()).toList(), reason: f.path);
    }
  });
}
