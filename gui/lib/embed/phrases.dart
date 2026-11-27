// 常用语 (iOS): long-kept replies sent in one tap — the text, then Return — without touching the draft.
// Spec: docs/superpowers/specs/2026-11-22-rapp-ios-phrases-design.md.

/// One entry of the 常用语条: a [Phrase] or a StripCmd (strip_cmds.dart). Not sealed: StripCmd lives in another library.
abstract interface class StripItem {
  Map<String, Object?> toJson();
}

/// [all] with the items of kind [T] replaced by [items], in order (cmd-menu design): the slots [T] holds take [items] one
/// by one, slots left over are dropped (a delete removes the item from [all] itself), and any extra go right after [T]'s last slot (or at the end when [T] has none).
/// The other kind stays where it was. The 命令 and 常用语 pages edit their own kind of the one 常用语 doc through this.
List<StripItem> withKind<T extends StripItem>(List<StripItem> all, List<T> items) {
  final out = <StripItem>[];
  var k = 0;
  int? after;
  for (final it in all) {
    if (it is! T) {
      out.add(it);
    } else if (k < items.length) {
      out.add(items[k++]);
      after = out.length;
    }
  }
  out.insertAll(after ?? out.length, items.skip(k));
  return out;
}

/// One 常用语. [put] (放进输入框) appends it to the draft instead of sending. [id] names it for stars, counts and sync
/// (quick-row spec §9); it is not part of `==`, and QuickPrefs gives every phrase one.
class Phrase implements StripItem {
  const Phrase(this.text, {this.put = false, this.id});
  final String text;
  final bool put;
  final String? id;

  Phrase copyWith({String? text, bool? put}) => Phrase(text ?? this.text, put: put ?? this.put, id: id);

  Phrase withId(String id) => Phrase(text, put: put, id: id);

  @override
  Map<String, Object> toJson() => {'text': text, if (put) 'put': true, 'id': ?id};

  /// Null when [j] is not a phrase with a non-blank text. A blank or non-string id reads as none.
  static Phrase? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['text'];
    if (t is! String || t.trim().isEmpty) return null;
    final id = j['id'];
    return Phrase(t, put: j['put'] == true, id: id is String && id.isNotEmpty ? id : null);
  }

  @override
  bool operator ==(Object other) => other is Phrase && other.text == text && other.put == put;

  @override
  int get hashCode => Object.hash(text, put);
}

/// The seven a fresh install starts with, after the six commands (strip-commands spec §7).
const defaultPhrases = [
  Phrase('继续'),
  Phrase('按你推荐来'),
  Phrase('进度'),
  Phrase('全做完别问我'),
  Phrase('先写方案别改代码'),
  Phrase('跑下测试'),
  Phrase('提交并推送'),
];

/// A second tap inside this window after a send is ignored (spec §4.3).
const phraseRepeatWindow = Duration(seconds: 1);

/// How long a sent chip shows its green ✓.
const phraseTickTime = Duration(milliseconds: 800);

/// How long the reason for a refused tap stays on the strip.
const phraseHintTime = Duration(seconds: 2);

/// The strip's height inside the key bar: the 30-point chips and the 6-point gap to the keys.
const phraseStripChip = 30.0;
const phraseStripGap = 6.0;
const phraseStripHeight = phraseStripChip + phraseStripGap;
