// On-device voice fixing (L1): exact replacement from rules the user confirmed, before anything is sent.
// No fuzzy matching: the worst a rule can do is what the rule says. All offsets are rune (code point) offsets.

enum FixAction { replace, preserve }

/// Where a rule came from (D9): decides whether flipping a fix back to the heard words can be learned.
enum FixSource { vocabulary, learned }

class FixRule {
  const FixRule.replace(this.observed, String this.output, this.source) : action = FixAction.replace;
  const FixRule.preserve(this.observed, this.source)
      : action = FixAction.preserve,
        output = null;

  final FixAction action;
  final String observed;
  final String? output;
  final FixSource source;

  /// The gateway's `{"action","observed","output"?,"source"}`. Throws [FormatException] on anything it does not
  /// know, so the caller skips that one rule.
  factory FixRule.fromJson(Map<String, Object?> j) {
    final observed = j['observed'], output = j['output'];
    final source = FixSource.values.where((s) => s.name == j['source']).firstOrNull;
    if (observed is! String || source == null) throw FormatException('bad voice rule', j);
    return switch (j['action']) {
      'replace' when output is String => FixRule.replace(observed, output, source),
      'preserve' => FixRule.preserve(observed, source),
      _ => throw FormatException('bad voice rule', j),
    };
  }

  Map<String, Object?> toJson() => {
        'action': action.name,
        'observed': observed,
        if (output != null) 'output': output,
        'source': source.name,
      };

  @override
  bool operator ==(Object other) =>
      other is FixRule &&
      other.action == action &&
      other.observed == observed &&
      other.output == output &&
      other.source == source;

  @override
  int get hashCode => Object.hash(action, observed, output, source);

  @override
  String toString() => 'FixRule(${action == FixAction.replace ? '$observed→$output' : '不改：$observed'}, ${source.name})';
}

/// One fix. Offsets are runes in the fixed text, like TidyChange; `after` == fixed runes [start, end).
class FixChange {
  const FixChange(this.start, this.end, this.before, this.after, this.source);
  final int start, end;
  final String before, after;
  final FixSource source;

  @override
  bool operator ==(Object other) =>
      other is FixChange &&
      other.start == start &&
      other.end == end &&
      other.before == before &&
      other.after == after &&
      other.source == source;

  @override
  int get hashCode => Object.hash(start, end, before, after, source);

  @override
  String toString() => 'FixChange($start,$end,$before→$after, ${source.name})';
}

class FixResult {
  const FixResult(this.text, this.changes);
  final String text;
  final List<FixChange> changes;
  bool get changed => changes.isNotEmpty;
}

/// What the recognizer heard, and what L1 made of it.
class VoiceHeard {
  const VoiceHeard({required this.heard, required this.fixed});
  final String heard, fixed;
  bool get changed => heard != fixed;
}

final _latin = RegExp(r'^[A-Za-z0-9 ]+$');
final _space = RegExp(r'\s');

/// ASCII-only case fold: latin rules are ASCII, and folding only A–Z keeps every rune where it was.
int _fold(int r) => r >= 0x41 && r <= 0x5A ? r + 0x20 : r;

bool _isWordRune(int r) => (r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);

class _Rule {
  _Rule(this.rule)
      : latin = _latin.hasMatch(rule.observed),
        runes = rule.observed.runes.toList() {
    if (latin) runes.setAll(0, runes.map(_fold));
  }
  final FixRule rule;
  final bool latin;
  final List<int> runes; // folded when latin

  /// Whether this rule matches [text] at [i]; [folded] is [text] through [_fold].
  bool at(List<int> text, List<int> folded, int i) {
    final n = runes.length;
    if (i + n > text.length) return false;
    final t = latin ? folded : text;
    for (var k = 0; k < n; k++) {
      if (t[i + k] != runes[k]) return false;
    }
    return !latin || ((i == 0 || !_isWordRune(text[i - 1])) && (i + n == text.length || !_isWordRune(text[i + n])));
  }
}

/// Rules bucketed by (folded) first rune, longest first.
Map<int, List<_Rule>> _buckets(Iterable<_Rule> rules) {
  final m = <int, List<_Rule>>{};
  for (final r in rules) {
    (m[r.runes.first] ??= []).add(r);
  }
  for (final b in m.values) {
    b.sort((a, b) => b.runes.length - a.runes.length);
  }
  return m;
}

/// The longest rule in [buckets] matching at [i] that ends by [limit], or null.
_Rule? _longest(Map<int, List<_Rule>> buckets, List<int> text, List<int> folded, int i, int limit) {
  final b = buckets[folded[i]];
  if (b == null) return null;
  for (final r in b) {
    if (i + r.runes.length <= limit && r.at(text, folded, i)) return r;
  }
  return null;
}

/// Compiled once after the rules sync; [fix] is pure.
class VoiceRules {
  VoiceRules._(this.rules, this._preserve, this._replace);

  /// Drops rules under 2 chars without whitespace (D3); of the same observed (latin by case) the last one stays.
  factory VoiceRules.compile(List<FixRule> rules) {
    final kept = <String, _Rule>{};
    for (final rule in rules) {
      if (rule.observed.replaceAll(_space, '').runes.length < 2) continue;
      final r = _Rule(rule);
      final key = String.fromCharCodes(r.runes);
      kept.remove(key);
      kept[key] = r;
    }
    final all = kept.values;
    return VoiceRules._(
      List.unmodifiable(all.map((r) => r.rule)),
      _buckets(all.where((r) => r.rule.action == FixAction.preserve)),
      _buckets(all.where((r) => r.rule.action == FixAction.replace)),
    );
  }

  static final VoiceRules empty = VoiceRules.compile(const []);

  /// The rules that survived [VoiceRules.compile].
  final List<FixRule> rules;
  final Map<int, List<_Rule>> _preserve, _replace;

  bool get isEmpty => rules.isEmpty;

  /// Spec 7.1: first hold every preserve (left to right, longest), then replace left to right with the longest
  /// rule that does not overlap a held range.
  FixResult fix(String text) {
    if (isEmpty) return FixResult(text, const []);
    final t = text.runes.toList();
    final f = t.map(_fold).toList();
    final n = t.length;

    // free[i]: the first held rune at or after i (n when none), so a match at i must end by free[i].
    final free = List<int>.filled(n + 1, n);
    if (_preserve.isNotEmpty) {
      final held = List<bool>.filled(n, false);
      for (var i = 0; i < n;) {
        final r = _longest(_preserve, t, f, i, n);
        if (r == null) {
          i++;
          continue;
        }
        held.fillRange(i, i + r.runes.length, true);
        i += r.runes.length;
      }
      for (var i = n - 1; i >= 0; i--) {
        free[i] = held[i] ? i : free[i + 1];
      }
    }

    final out = StringBuffer();
    final changes = <FixChange>[];
    var outLen = 0, copied = 0;
    for (var i = 0; i < n;) {
      final r = _longest(_replace, t, f, i, free[i]);
      if (r == null) {
        i++;
        continue;
      }
      final end = i + r.runes.length;
      final before = String.fromCharCodes(t, i, end), after = r.rule.output!;
      if (before != after) {
        out.write(String.fromCharCodes(t, copied, i));
        outLen += i - copied;
        out.write(after);
        final len = after.runes.length;
        changes.add(FixChange(outLen, outLen + len, before, after, r.rule.source));
        outLen += len;
        copied = end;
      }
      i = end;
    }
    if (changes.isEmpty) return FixResult(text, const []);
    out.write(String.fromCharCodes(t, copied, n));
    return FixResult(out.toString(), changes);
  }

  /// Whether a vocabulary replace explains [avoid]: its observed is in [observed] (by the matching rules) and its
  /// output is in [avoid]. Flipping such a fix back to the heard words is not learned (D9).
  bool fromVocabulary(String observed, String avoid) {
    final t = observed.runes.toList();
    final f = t.map(_fold).toList();
    for (final b in _replace.values) {
      for (final r in b) {
        if (r.rule.source != FixSource.vocabulary || !avoid.contains(r.rule.output!)) continue;
        for (var i = 0; i < t.length; i++) {
          if (r.at(t, f, i)) return true;
        }
      }
    }
    return false;
  }
}
