// Pure comparison for voice tidy: which words the AI changed (so each can
// flip back to what was heard), and what a user's edit after the AI teaches.
// All offsets are rune (code point) offsets, never UTF-16 units.
import 'dart:typed_data';

/// A span of the AI's text that can flip back to what was heard.
class TidyChange {
  const TidyChange({required this.start, required this.end, required this.before, required this.after});

  /// Rune offsets in the AI's text.
  final int start, end;

  /// The heard words, and the AI's words (`after` == result runes [start, end)).
  final String before, after;

  @override
  bool operator ==(Object other) =>
      other is TidyChange && other.start == start && other.end == end && other.before == before && other.after == after;

  @override
  int get hashCode => Object.hash(start, end, before, after);

  @override
  String toString() => 'TidyChange($start,$end,$before→$after)';
}

enum LearnAction { replace, preserve }

class LearnItem {
  const LearnItem.replace({required this.observed, required String this.output, required this.excerpt})
      : action = LearnAction.replace,
        avoid = null;
  const LearnItem.preserve({required this.observed, required String this.avoid, required this.excerpt})
      : action = LearnAction.preserve,
        output = null;

  final LearnAction action;
  final String observed;
  final String? output, avoid;
  final String excerpt;

  Map<String, Object> toJson() => action == LearnAction.replace
      ? {'action': 'replace', 'observed': observed, 'output': output!, 'excerpt': excerpt}
      : {'action': 'preserve', 'observed': observed, 'avoid': avoid!, 'excerpt': excerpt};

  String get label => action == LearnAction.replace ? '$observed → $output' : '不改：$observed';

  @override
  bool operator ==(Object other) =>
      other is LearnItem &&
      other.action == action &&
      other.observed == observed &&
      other.output == output &&
      other.avoid == avoid &&
      other.excerpt == excerpt;

  @override
  int get hashCode => Object.hash(action, observed, output, avoid, excerpt);

  @override
  String toString() => 'LearnItem($label)';
}

const _maxSide = 12;
const _maxChanges = 8;
const _maxCells = 4000000;
const _maxLearns = 3;

final _spaceOrPunct = RegExp(r'^[\s\p{P}\p{S}]$', unicode: true);
final _dropChars = RegExp(r'[\s\p{P}\p{S}]', unicode: true);
final _numbering = RegExp(r'^\s*\d+[.、]');

bool _isSpaceOrPunct(int rune) => _spaceOrPunct.hasMatch(String.fromCharCode(rune));

String _norm(String s) => s.replaceFirst(_numbering, '').replaceAll(_dropChars, '').toLowerCase();

/// The gateway refuses an excerpt over 2000 code points, so a long text is cut to about [window] runes either
/// side of [observed] (by runes: a surrogate pair is never split). The cut always holds [observed].
String learnExcerpt(String text, String observed, {int window = 200}) {
  final r = text.runes.toList();
  if (r.length <= 2 * window + observed.runes.length) return text;
  final at = text.indexOf(observed);
  if (at < 0) return text;
  final from = text.substring(0, at).runes.length;
  final to = from + observed.runes.length;
  final lo = from - window < 0 ? 0 : from - window;
  final hi = to + window > r.length ? r.length : to + window;
  return String.fromCharCodes(r.sublist(lo, hi));
}

String _str(List<int> r, int from, int to) => String.fromCharCodes(r.sublist(from, to));

class _Hunk {
  const _Hunk(this.i0, this.i1, this.j0, this.j1);
  final int i0, i1, j0, j1; // a [i0,i1) ↔ b [j0,j1)
}

class _Align {
  _Align(this.aToB, this.bToA, this.hunks, this.lcs);
  final List<int> aToB, bToA; // -1 where not an equal char
  final List<_Hunk> hunks;
  final int lcs;
}

_Align? _align(List<int> a, List<int> b) {
  final n = a.length, m = b.length;
  if (n * m > _maxCells) return null;
  final w = m + 1;
  final t = Int32List((n + 1) * w);
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      t[i * w + j] = a[i] == b[j]
          ? t[(i + 1) * w + j + 1] + 1
          : (t[(i + 1) * w + j] >= t[i * w + j + 1] ? t[(i + 1) * w + j] : t[i * w + j + 1]);
    }
  }
  final aToB = List<int>.filled(n, -1), bToA = List<int>.filled(m, -1);
  final hunks = <_Hunk>[];
  var i = 0, j = 0, pi = 0, pj = 0;
  void match(int mi, int mj) {
    if (mi > pi || mj > pj) hunks.add(_Hunk(pi, mi, pj, mj));
    aToB[mi] = mj;
    bToA[mj] = mi;
    pi = mi + 1;
    pj = mj + 1;
  }

  while (i < n && j < m) {
    if (a[i] == b[j]) {
      match(i, j);
      i++;
      j++;
    } else if (t[(i + 1) * w + j] >= t[i * w + j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  if (n > pi || m > pj) hunks.add(_Hunk(pi, n, pj, m));
  return _Align(aToB, bToA, hunks, t[0]);
}

/// The switchable changes between a and b, as a range in each.
List<_Hunk> _changes(List<int> a, List<int> b) {
  if (a.isEmpty) return const [];
  final al = _align(a, b);
  if (al == null || al.lcs * 2 < a.length) return const [];
  final out = <_Hunk>[];
  for (final h in al.hunks) {
    final before = _str(a, h.i0, h.i1), after = _str(b, h.j0, h.j1);
    final nb = _norm(before), na = _norm(after);
    if (nb == na || nb.isEmpty || na.isEmpty) continue;
    var i0 = h.i0, i1 = h.i1, j0 = h.j0, j1 = h.j1;
    var trimL = false, trimR = false;
    while (i0 < i1 && _isSpaceOrPunct(a[i0])) {
      i0++;
      trimL = true;
    }
    while (i1 > i0 && _isSpaceOrPunct(a[i1 - 1])) {
      i1--;
      trimR = true;
    }
    while (j0 < j1 && _isSpaceOrPunct(b[j0])) {
      j0++;
      trimL = true;
    }
    while (j1 > j0 && _isSpaceOrPunct(b[j1 - 1])) {
      j1--;
      trimR = true;
    }
    if (i1 - i0 > _maxSide || j1 - j0 > _maxSide) continue;
    // Widen a short AI side: to the left first, then to the right.
    while (j1 - j0 < 2) {
      if (!trimL && i0 > 0 && j0 > 0 && a[i0 - 1] == b[j0 - 1] && !_isSpaceOrPunct(a[i0 - 1])) {
        i0--;
        j0--;
      } else if (!trimR && i1 < a.length && j1 < b.length && a[i1] == b[j1] && !_isSpaceOrPunct(a[i1])) {
        i1++;
        j1++;
      } else {
        break;
      }
    }
    if (out.isNotEmpty && j0 < out.last.j1) {
      final p = out.removeLast();
      out.add(_Hunk(p.i0, i1 > p.i1 ? i1 : p.i1, p.j0, j1 > p.j1 ? j1 : p.j1));
    } else {
      out.add(_Hunk(i0, i1, j0, j1));
    }
  }
  return out.length > _maxChanges ? const [] : out;
}

/// Which words of [result] the AI changed from [original].
List<TidyChange> tidyChanges(String original, String result) {
  final a = original.runes.toList(), b = result.runes.toList();
  return [
    for (final h in _changes(a, b))
      TidyChange(start: h.j0, end: h.j1, before: _str(a, h.i0, h.i1), after: _str(b, h.j0, h.j1)),
  ];
}

/// What the user's edit ([sent]) of [result] (the AI's text, or the device's fixed words) teaches about the
/// heard [original]: a change to new words teaches replace; putting a change of [result] back as heard teaches
/// preserve, avoiding what [result] had there. At most 3 items.
List<LearnItem> editLearns(String original, String result, String sent) {
  final o = original.runes.toList(), r = result.runes.toList(), s = sent.runes.toList();
  final oa = _align(o, r), rs = _align(r, s);
  if (oa == null || rs == null) return const [];
  final out = <LearnItem>[];
  for (final c in _changes(r, s)) {
    // c: r [i0,i1) ↔ s [j0,j1)
    var rFrom = c.i0, rTo = c.i1, sFrom = c.j0, sTo = c.j1;
    final overlapping = [
      for (final h in oa.hunks)
        if (h.j0 == h.j1 ? (c.i0 < h.j0 && h.j0 < c.i1) : (h.j0 < c.i1 && c.i0 < h.j1)) h,
    ];
    final oIdx = <int>{};
    for (var k = c.i0; k < c.i1; k++) {
      if (oa.bToA[k] >= 0) oIdx.add(oa.bToA[k]);
    }
    if (overlapping.length > 1) continue;
    if (overlapping.length == 1) {
      final h = overlapping.single;
      if (h.i0 == h.i1) continue;
      if (h.j0 < rFrom) {
        final p = _leftBoundary(rs, h.j0);
        if (p == null) continue;
        rFrom = h.j0;
        sFrom = p;
      }
      if (h.j1 > rTo) {
        final p = _rightBoundary(rs, h.j1, s.length);
        if (p == null) continue;
        rTo = h.j1;
        sTo = p;
      }
      for (var k = h.i0; k < h.i1; k++) {
        oIdx.add(k);
      }
    }
    if (oIdx.isEmpty) continue;
    final lo = oIdx.reduce((x, y) => x < y ? x : y), hi = oIdx.reduce((x, y) => x > y ? x : y);
    if (oIdx.length != hi - lo + 1) continue; // must be contiguous
    final observed = _str(o, lo, hi + 1).trim();
    final output = _str(s, sFrom, sTo).trim();
    if (observed.isEmpty || observed.runes.length > _maxSide) continue;
    if (observed == output) {
      // Put back as heard: a fix (the AI's, or the device's) the user does not want — keep [observed] (D8).
      if (overlapping.isEmpty) continue;
      final avoid = _str(r, rFrom, rTo).trim();
      if (avoid.isEmpty || avoid == observed) continue;
      out.add(LearnItem.preserve(observed: observed, avoid: avoid, excerpt: learnExcerpt(original, observed)));
    } else {
      out.add(LearnItem.replace(observed: observed, output: output, excerpt: learnExcerpt(original, observed)));
    }
    if (out.length == _maxLearns) break;
  }
  return out;
}

// The s position of a cut just before r[q].
int? _leftBoundary(_Align rs, int q) {
  final n = rs.aToB.length;
  if (q < n && rs.aToB[q] >= 0) return rs.aToB[q];
  if (q > 0 && rs.aToB[q - 1] >= 0) return rs.aToB[q - 1] + 1;
  if (q == 0) return 0;
  return null;
}

// The s position of a cut just after r[q-1].
int? _rightBoundary(_Align rs, int q, int sLen) {
  final n = rs.aToB.length;
  if (q > 0 && rs.aToB[q - 1] >= 0) return rs.aToB[q - 1] + 1;
  if (q < n && rs.aToB[q] >= 0) return rs.aToB[q];
  if (q == n) return sLen;
  return null;
}
