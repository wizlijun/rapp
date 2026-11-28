// Reading view (phone V1a, probe 3): turn what the text terminal protocol hands a viewer — scrollback rows oldest
// first, then the screen rows, each an SGR string with a "the next row continues this one" mark — into blocks a
// phone can show: prose paragraphs it may rewrap to its own width, and raw blocks (code, tables, diffs, tool output)
// that keep their columns and scroll sideways.
//
// Pure Dart, no Flutter: depends only on sgr.dart and char_width.dart.
//
// The three agent CLIs measured (Claude Code, Codex, agy) wrap their own text and end every row with a real
// newline, so the protocol's `wrapped` mark is almost never set for them; most of the work below is guessing which
// newlines were the CLI's own wrapping. See docs/superpowers/measurements/2026-11-27-rapp-phone-v1a-3-reading.md.
library;

import 'char_width.dart';
import 'sgr.dart';

enum ReadKind {
  /// Text the viewer may rewrap. [ReadBlock.lines] holds real line breaks; wrapped rows are already joined.
  prose,

  /// A short bold or `#` line: a heading.
  heading,

  /// Keep as is, one entry per terminal row, scroll sideways: code, tables, diffs, aligned program output.
  raw,

  /// One line naming a tool call ("Update(stats.py)", "Ran git diff").
  tool,

  /// Timing and thinking lines ("Crunched for 27s", "Thought for 14s").
  meta,
}

/// Who a block belongs to, from the CLI's own turn marks. [unknown] before the first mark (banner, sticky header).
enum Speaker { unknown, me, it }

class ReadBlock {
  ReadBlock(this.kind, this.speaker, this.lines);
  final ReadKind kind;
  final Speaker speaker;
  final List<String> lines;

  String get text => lines.join('\n');

  /// Widest line in terminal cells: how far a raw block scrolls sideways.
  int get columns => lines.fold(0, (n, l) => n > textWidth(l) ? n : textWidth(l));

  @override
  String toString() => '${kind.name}/${speaker.name}: $text';
}

/// One rejoin decision, for measuring the wrap guess: [a] ended a row, [b] began the next, [joined] says whether
/// they were taken as one wrapped line.
typedef JoinTrace = void Function(String a, String b, bool joined);

/// Cells a string takes on the terminal grid.
int textWidth(String s) {
  var w = 0;
  for (final r in s.runes) {
    w += cellWidth(r);
  }
  return w;
}

bool _wide(int rune) => cellWidth(rune) == 2;

/// [rows]: scrollback oldest first, then the screen, as the protocol sends them (SGR strings).
/// [wrapped]: per row, the protocol's "next row continues this one" mark (`screen.wrapped`, `history.wrapped`).
/// [cols]: the terminal width the rows were laid out at.
/// [screenFrom]: index of the first screen row, or null when [rows] has no live screen (then no input box is cut).
List<ReadBlock> reflow(
  List<String> rows, {
  List<bool>? wrapped,
  required int cols,
  int? screenFrom,
  JoinTrace? trace,
}) {
  return _run([for (final r in rows) parseRow(r).cells], wrapped, cols, screenFrom, trace);
}

/// The same as [reflow], for the terminal model's lines. [wrapped]: indexes of lines the next line continues.
List<ReadBlock> reflowLines(
  List<TermLine> lines, {
  Set<int>? wrapped,
  required int cols,
  int? screenFrom,
}) {
  return _run(
    [for (final l in lines) l.cells],
    wrapped == null ? null : [for (var i = 0; i < lines.length; i++) wrapped.contains(i)],
    cols,
    screenFrom,
    null,
  );
}

List<ReadBlock> _run(List<List<TermCell>> rows, List<bool>? wrapped, int cols, int? screenFrom, JoinTrace? trace) {
  final lines = _parse(rows, wrapped);
  if (screenFrom != null) _cutFooter(lines, screenFrom);
  _dedupe(lines);
  return _Builder(lines, cols, trace).build();
}

class _Line {
  _Line(this.text, this.indent, this.width, this.bold);
  String text; // indent removed, trailing blanks removed
  int indent; // leading cells
  int width; // cells up to the last non-blank one, indent included (inside a panel: up to its text, not its side)
  final bool bold; // every non-blank cell bold
  bool get blank => text.isEmpty;
}

List<_Line> _parse(List<List<TermCell>> rows, List<bool>? wrapped) {
  final out = <_Line>[];
  var i = 0;
  while (i < rows.length) {
    // Rows the terminal itself wrapped (protocol mark) are one logical line: glue them first, losslessly.
    final cells = <TermCell>[];
    while (true) {
      cells.addAll(rows[i]);
      final more = wrapped != null && i < wrapped.length && wrapped[i] && i + 1 < rows.length;
      i++;
      if (!more) break;
    }
    var end = cells.length;
    while (end > 0 && cells[end - 1].ch.trim().isEmpty) {
      end--;
    }
    var start = 0;
    var indent = 0;
    while (start < end && cells[start].ch.trim().isEmpty) {
      indent += cells[start].width;
      start++;
    }
    final sb = StringBuffer();
    var width = indent;
    var bold = start < end;
    // A turn mark in front of a bold heading ("⏺ **统计函数**") is not itself bold.
    final mark = indent == 0 && end - start > 2 && '⏺•●'.contains(cells[start].ch) && cells[start + 1].ch == ' ';
    for (var k = start; k < end; k++) {
      final c = cells[k];
      sb.write(c.ch == '\t' ? ' ' : c.ch);
      width += c.width;
      if (mark && k < start + 2) continue;
      if (c.ch.trim().isNotEmpty && c.style.flags & 1 == 0) bold = false;
    }
    out.add(_Line(sb.toString(), start < end ? indent : 0, width, bold));
  }
  return out;
}

// Turn marks at column 0. An option row ("❯ 1. Yes", "› 1. Trust") is not a turn.
final _me = RegExp(r'^(?:❯|›|>)(?: (?!\d+\. )|$)');
final _it = RegExp(r'^(?:⏺|•|●) ');

/// The CLI's own input box at the bottom of the live screen: drop it, the phone has its own reply box.
/// Rule: the last turn-mark row within the screen's last 6 non-blank rows, and a rule line just above it.
void _cutFooter(List<_Line> lines, int screenFrom) {
  var n = lines.length;
  while (n > screenFrom && lines[n - 1].blank) {
    n--;
  }
  for (var k = n - 1; k >= screenFrom && k >= n - 6; k--) {
    final l = lines[k];
    if (l.indent == 0 && _me.hasMatch(l.text)) {
      var cut = k;
      if (cut - 1 >= screenFrom && _rule.hasMatch(lines[cut - 1].text)) cut--;
      lines.removeRange(cut, lines.length);
      return;
    }
  }
}

/// Claude Code's classic renderer reprints part of the conversation when a permission dialog comes and goes, so
/// scrollback holds the same stretch twice. Drop a run of [_dupRun] or more rows (at least 4 of them non-blank)
/// that repeats an earlier run row for row. Would also drop a reply that really repeats six rows of itself.
const _dupRun = 6;

void _dedupe(List<_Line> lines) {
  String key(int i) => '${lines[i].indent}\u0000${lines[i].text}';
  final hs = [for (var i = 0; i < lines.length; i++) key(i).hashCode];
  bool same(int x, int y) {
    for (var k = 0; k < _dupRun; k++) {
      if (key(x + k) != key(y + k)) return false;
    }
    return true;
  }

  // Window hash -> first start; a hash hit is checked row by row.
  final seen = <int, int>{};
  final drop = List.filled(lines.length, false);
  var i = 0;
  while (i + _dupRun <= lines.length) {
    var solid = 0;
    for (var k = i; k < i + _dupRun; k++) {
      if (!lines[k].blank) solid++;
    }
    if (solid < 4) {
      i++;
      continue;
    }
    var w = 0;
    for (var k = i; k < i + _dupRun; k++) {
      w = Object.hash(w, hs[k]);
    }
    final at = seen[w];
    if (at != null && at + _dupRun <= i && same(at, i)) {
      var n = _dupRun;
      while (i + n < lines.length && key(at + n) == key(i + n) && at + n < i) {
        n++;
      }
      for (var k = i; k < i + n; k++) {
        drop[k] = true;
      }
      i += n;
      continue;
    }
    seen.putIfAbsent(w, () => i);
    i++;
  }
  var o = 0;
  for (var k = 0; k < lines.length; k++) {
    if (!drop[k]) lines[o++] = lines[k];
  }
  lines.length = o;
}

final _rule = RegExp(r'^[╭╰┌└├]?[─━═╌┄┈▔▁]{6,}[╮╯┐┘┤]?$');
final _gapRule = RegExp(r'^[─━═]{3,}(?: +[─━═]{3,})+$');
// "✻ Pondering…", "⣯ Generating...", or any row with "esc to interrupt" (Codex: "• Working (3s • esc to interrupt)").
// One word only, so a list item or a Codex "• " reply ending in "…" stays.
final _spinner = RegExp(r'^(?:[✢✳✶✻✽✺·*⠀-⣿] +\S+(?:…|\.\.\.)$|.*\besc to interrupt\b)');
final _meta = RegExp(r'^(?:(?:[✢✳✶✻✽✺○▸] +)?[A-Z][a-z]+|Worked) for \d');
final _toolHead = RegExp(
  r'^(?:[A-Z][A-Za-z]+\(|(?:Ran|Called|Explored|Edited|Read|Wrote|Updated|Searched|Listed|Waited)\b)',
);
final _toolBody = RegExp(r'^[⎿└]|ctrl\+o to expand|⌃t to view|^… \+\d+ lines|^\+\d+ lines');
// List items, and option rows with the selection cursor in front ("❯ 1. Yes", "› 2. No").
final _marker = RegExp(r'^(?:[-*•◦▪]|(?:[❯›>] )?\d+[.)]|[☐☒✔✓✗]) ');
final _hash = RegExp(r'^#{1,6} ');
final _diffHead = RegExp(r'^(?:diff --git |index [0-9a-f]{6,}|--- a/|\+\+\+ b/|@@ .+ @@)');
final _code = <RegExp>[
  RegExp(r'^(?:async +)?(?:def|class) +\w+.*:$'),
  RegExp(r'^(?:import +[\w.]+|from +[\w.]+ +import )'),
  RegExp(r'^(?:if|elif|else|for|while|with|try|except|finally)\b.*:$'),
  RegExp(r'^(?:return|raise|yield|await)\b[\x20-\x7e]*$'),
  RegExp(r'^(?:const|let|var|function|fn|pub|use|impl|struct|func|package) '),
  RegExp(r'^[A-Za-z_][\w.]*(?:\[[^\]]*\])?(?: *, *[A-Za-z_][\w.]*)* *[+\-*/%|&]?=(?!=) *\S'),
  RegExp(r'^[A-Za-z_][\w.]*\(.*\)[;,]?$'),
  RegExp(r'^[\]\)\}]+[,;)]*$'),
  RegExp(r'^[\{\[]'),
  RegExp(r'^"""|"""$'),
  RegExp(r'^(?:\$ |#!|// )'),
  RegExp(r'^\d+ {1,2}[ +\-]'),
  RegExp(r'^\d+$'),
  RegExp(r'^⋮$'),
];
final _blockArt = RegExp(r'[▀▄█▌▐▛▜▝▘▗▖▟▙]{2,}');

enum _K { sep, drop, meta, tool, toolBody, table, code, weak, text }

class _Builder {
  _Builder(this.lines, this.cols, this.trace);
  final List<_Line> lines;
  final int cols;
  final JoinTrace? trace;
  final out = <ReadBlock>[];
  var who = Speaker.unknown;
  var inDiff = false;
  late final int wrapAt;

  List<ReadBlock> build() {
    final kinds = lines.map(_classify).toList();
    // The right edge the CLI wraps prose at: the widest prose row seen (CLIs keep a margin of 0–3 cells).
    var w = 0;
    for (var i = 0; i < lines.length; i++) {
      if (kinds[i] == _K.text && lines[i].width > w) w = lines[i].width;
    }
    // Too little text to have reached the edge (a fresh screen): use the width. Errs toward keeping newlines.
    wrapAt = w >= cols * 0.85 ? w : cols;
    var i = 0;
    while (i < lines.length) {
      if (kinds[i] == _K.sep) {
        // A blank or a rule ends the turn mark's reach only for "me": the CLI's reply follows.
        if (who == Speaker.me && lines[i].blank) who = Speaker.it;
        i++;
        continue;
      }
      var j = i;
      while (j < lines.length && kinds[j] != _K.sep) {
        j++;
      }
      _group(i, j, kinds);
      i = j;
    }
    return _mergeRaw(out);
  }

  _K _classify(_Line l) {
    if (l.blank) return _K.sep;
    var t = l.text;
    // A panel row "│ … │": take the inside; "│ …" alone is a gutter (questions, command continuations).
    final inner = t.length > 2 ? t.substring(1, t.length - 1).trim() : '';
    if (t.length >= 2 && t.startsWith('│') && t.endsWith('│') && inner.isEmpty) return _K.sep;
    if (t.startsWith('│') &&
        t.endsWith('│') &&
        inner.isNotEmpty &&
        (!inner.contains('│') || RegExp('^[┌├└│]').hasMatch(inner))) {
      t = t.substring(1, t.length - 1);
      final lead = t.length - t.trimLeft().length;
      l.indent += 1 + lead;
      l.text = t.trim();
      l.width = l.indent + textWidth(l.text);
      if (l.text.isEmpty) return _K.sep;
      t = l.text;
    } else if (t.startsWith('│ ') && !t.substring(1).contains('│')) {
      l.text = t.substring(2).trimLeft();
      l.indent += 2;
      l.width = l.indent + textWidth(l.text);
      t = l.text;
    }
    if (_rule.hasMatch(t)) return _K.sep;
    if (_spinner.hasMatch(t)) return _K.drop;
    if (_meta.hasMatch(t)) return _K.meta;
    if (_toolBody.hasMatch(t)) return _K.toolBody; // before tables: Codex hangs tool output off "└ "
    if (_gapRule.hasMatch(t) || '│'.allMatches(t).length >= 2 || t.contains(RegExp('[┼┬┴├┤┌┐└┘]'))) {
      return _K.table;
    }
    if (_blockArt.hasMatch(t)) return _K.code;
    if (l.indent == 0 && _it.hasMatch(t)) {
      final rest = t.substring(2);
      if (_toolHead.hasMatch(rest)) return _K.tool;
    }
    if (_toolBody.hasMatch(t)) return _K.toolBody;
    if (_diffHead.hasMatch(t)) {
      inDiff = true;
      return _K.code;
    }
    if (inDiff && RegExp(r'^[+\-@ ]').hasMatch(t)) return _K.code;
    inDiff = false;
    for (final r in _code) {
      if (r.hasMatch(t)) return _K.code;
    }
    // A diff row whose header scrolled away: "+" / "-" and then code.
    if (t == '+' || t == '-') return _K.code;
    if (t.startsWith('+') || t.startsWith('-')) {
      final rest = t.substring(1).trimLeft();
      for (final r in _code) {
        if (r.hasMatch(rest)) return _K.code;
      }
    }
    if (t.startsWith('#')) return _K.weak; // "# comment" in code, or a "## heading"; the group decides
    return _K.text;
  }

  void _group(int a, int b, List<_K> kinds) {
    // A tool line whose next row hangs off it ("└", "⎿") is a header even when its verb is not in the list.
    for (var k = a; k < b - 1; k++) {
      if (kinds[k] == _K.text &&
          lines[k].indent == 0 &&
          _it.hasMatch(lines[k].text) &&
          kinds[k + 1] == _K.toolBody) {
        kinds[k] = _K.tool;
      }
    }
    var start = a;
    for (var k = a; k <= b; k++) {
      final edge = k == b || kinds[k] == _K.tool || kinds[k] == _K.meta || kinds[k] == _K.drop;
      if (!edge) continue;
      if (k > start) _run(start, k, kinds);
      if (k < b && kinds[k] != _K.drop) {
        final l = lines[k];
        var t = l.text;
        _turn(l);
        if (kinds[k] == _K.tool) {
          t = t.substring(2);
          who = Speaker.it;
        }
        out.add(ReadBlock(kinds[k] == _K.tool ? ReadKind.tool : ReadKind.meta, who, [t]));
      }
      start = k + 1;
    }
  }

  /// Rows between edges inside one blank-separated group: all raw, or prose.
  void _run(int a, int b, List<_K> kinds) {
    var strong = 0, prose = 0, table = false, marked = false;
    for (var k = a; k < b; k++) {
      switch (kinds[k]) {
        case _K.table:
          table = true;
        case _K.code || _K.toolBody:
          strong++;
        case _K.text:
          final t = lines[k].text;
          if (_marker.hasMatch(t) || (lines[k].indent == 0 && (_me.hasMatch(t) || _it.hasMatch(t)))) {
            marked = true;
          }
          if (t.runes.any(_wide) || ' '.allMatches(t).length >= 3) prose++;
        default:
      }
    }
    if (table || (strong > 0 && strong >= prose)) {
      _turn(lines[a]);
      _raw(a, b);
      return;
    }
    // Aligned program output: three or more short rows, none a list item, none joining the next.
    if (b - a >= 3 && !marked) {
      var short = true;
      for (var k = a; k < b; k++) {
        if (lines[k].width > wrapAt * 0.7) short = false;
      }
      if (short && !_anyJoin(a, b)) {
        _raw(a, b);
        return;
      }
    }
    _prose(a, b);
  }

  void _raw(int a, int b) {
    // Full indent for now: the common indent comes off once blank-split pieces are merged (_mergeRaw).
    out.add(ReadBlock(ReadKind.raw, who, [
      for (var k = a; k < b; k++) '${' ' * lines[k].indent}${_strip(lines[k].text)}',
    ]));
  }

  static String _strip(String t) =>
      t.startsWith('⎿ ') || t.startsWith('└ ') ? t.substring(2).trimLeft() : t;

  /// A turn mark at column 0 sets the speaker for what follows.
  void _turn(_Line l) {
    if (l.indent != 0) return;
    if (_me.hasMatch(l.text)) {
      who = Speaker.me;
    } else if (_it.hasMatch(l.text)) {
      who = Speaker.it;
    }
  }

  /// Claude Code and agy draw headings bold with no `#`. A long bold row is a bold prompt (agy), not a heading.
  bool _heading(_Line l) => l.bold && l.width < wrapAt * 0.6;

  bool _anyJoin(int a, int b) {
    for (var k = a + 1; k < b; k++) {
      if (_wraps(lines[k - 1], lines[k])) return true;
    }
    return false;
  }

  /// The guess: row [a] was wrapped by the CLI if the first word of [b] would not have fit after it.
  /// A CLI wrapping greedily never leaves room for the next word, so a row that did leave room ended for real.
  bool _wraps(_Line a, _Line b) {
    final t = b.text;
    if (_marker.hasMatch(t) || _hash.hasMatch(t) || _heading(a)) return false;
    if (b.indent == 0 && (_me.hasMatch(t) || _it.hasMatch(t))) return false;
    final sp = t.indexOf(' ');
    final word = sp < 0 ? t : t.substring(0, sp);
    final sep = _wide(a.text.runes.last) && _wide(t.runes.first) ? 0 : 1;
    return a.width + sep + textWidth(word) > wrapAt;
  }

  void _prose(int a, int b) {
    var cur = <String>[];
    var buf = StringBuffer();
    var kind = ReadKind.prose;
    void flushLine() {
      if (buf.isNotEmpty) cur.add(buf.toString());
      buf = StringBuffer();
    }

    void flush() {
      flushLine();
      if (cur.isNotEmpty) out.add(ReadBlock(kind, who, cur));
      cur = <String>[];
      kind = ReadKind.prose;
    }

    for (var k = a; k < b; k++) {
      final l = lines[k];
      var t = l.text;
      final startsTurn = l.indent == 0 && (_me.hasMatch(t) || _it.hasMatch(t));
      if (k > a) {
        final prev = lines[k - 1];
        final joined = _wraps(prev, l);
        trace?.call(prev.text, t, joined);
        if (joined) {
          final sep = _wide(prev.text.runes.last) && _wide(t.runes.first) ? '' : ' ';
          buf.write(sep);
          buf.write(t);
          continue;
        }
        if (startsTurn || _marker.hasMatch(t) || _hash.hasMatch(t) || _heading(prev) || kind == ReadKind.heading) {
          flush();
        } else {
          flushLine();
        }
      }
      if (startsTurn) {
        _turn(l);
        t = t.length > 2 ? t.substring(2) : '';
      }
      if (_hash.hasMatch(t)) {
        kind = ReadKind.heading;
        t = t.replaceFirst(RegExp(r'^#+ '), '');
      } else if (_heading(l)) {
        kind = ReadKind.heading;
      }
      buf.write(t);
    }
    flush();
  }

  /// Raw blocks split only by blank rows (a code block with an empty line in it) become one block again.
  static List<ReadBlock> _mergeRaw(List<ReadBlock> blocks) {
    final out = <ReadBlock>[];
    for (final b in blocks) {
      if (b.kind == ReadKind.raw &&
          out.isNotEmpty &&
          out.last.kind == ReadKind.raw &&
          out.last.speaker == b.speaker) {
        out[out.length - 1] = ReadBlock(ReadKind.raw, b.speaker, [...out.last.lines, '', ...b.lines]);
      } else {
        out.add(b);
      }
    }
    for (var i = 0; i < out.length; i++) {
      final b = out[i];
      if (b.kind != ReadKind.raw) continue;
      var base = 1 << 30;
      for (final l in b.lines) {
        if (l.isEmpty) continue;
        final n = l.length - l.trimLeft().length;
        if (n < base) base = n;
      }
      out[i] = ReadBlock(ReadKind.raw, b.speaker, [for (final l in b.lines) l.isEmpty ? l : l.substring(base)]);
    }
    return out;
  }
}
