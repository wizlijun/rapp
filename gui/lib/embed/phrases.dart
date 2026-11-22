// 常用语 (iOS): long-kept replies sent in one tap — the text, then Return — without touching the draft.
// Spec: docs/superpowers/specs/2026-11-22-rapp-ios-phrases-design.md.

/// One 常用语. [put] (放进输入框) appends it to the draft instead of sending.
class Phrase {
  const Phrase(this.text, {this.put = false});
  final String text;
  final bool put;

  Phrase copyWith({String? text, bool? put}) => Phrase(text ?? this.text, put: put ?? this.put);

  Map<String, Object> toJson() => {'text': text, if (put) 'put': true};

  /// Null when [j] is not a phrase with a non-blank text.
  static Phrase? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['text'];
    if (t is! String || t.trim().isEmpty) return null;
    return Phrase(t, put: j['put'] == true);
  }

  @override
  bool operator ==(Object other) => other is Phrase && other.text == text && other.put == put;

  @override
  int get hashCode => Object.hash(text, put);
}

/// The ten a fresh install starts with (spec §3).
const defaultPhrases = [
  Phrase('继续'),
  Phrase('确认'),
  Phrase('听你的'),
  Phrase('按你推荐的来'),
  Phrase('进度'),
  Phrase('全部做完，中途不用问我'),
  Phrase('先出方案，别改代码'),
  Phrase('跑一下测试'),
  Phrase('提交并推送'),
  Phrase('总结一下改了什么'),
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
