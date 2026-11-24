// 长语音先让 AI 整理 (spec 2026-11-20-rapp-voice-ai-tidy-design.md §5.2): a voice text longer than 10 characters
// goes through the gateway's `dictation` before it is sent or put in the panel. The user can send or edit the
// original at any time. A good result on a send waits [VoiceTidy.settle] in the bubble before it goes, time to click
// 编辑 or 还原 (user 2026-11-20). A failure goes on quietly as if there had been no tidy: the original is sent or
// put in the panel, the reason only in the log (§8.1 D3).
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import '../llm_api.dart';
import 'composer_model.dart' show VoiceAi, VoiceOrigin;
import 'tidy_diff.dart';
import 'tidy_mode.dart';
import 'voice_ring.dart' show VoicePick;

const tidyNoResult = 'AI 没有给出结果';
const tidyTooSlow = 'LLM 没有及时回应';

/// tidying: the AI is writing; ready: it is done and the send waits [VoiceTidy.settle]; note: a hint after the end.
enum TidyPhase { idle, tidying, ready, note }

/// A question "remember this correction?" next to the tidy: [items] are what would be learned, [picked] the
/// indexes that will be. [inBubble]: it sits in the bubble while it is on screen; otherwise it is the small box
/// that lives [VoiceTidy.offerLife]. [done]: it was answered ("记住了").
class LearnOffer {
  LearnOffer({required this.items, required this.inBubble, Set<int>? picked, this.done = false})
      : picked = picked ?? {for (var i = 0; i < items.length; i++) i};
  final List<LearnItem> items;
  final bool inBubble;
  final Set<int> picked;
  bool done;
}

/// One session's tidy: at most one runs at a time. The card shows [phase]; the callbacks do the sending and the
/// keeping in whatever session [sid] is now (a reconnect moves it, [moveTo]).
class VoiceTidy extends ChangeNotifier {
  VoiceTidy({
    required this.sid,
    required this.endpoint,
    required this.api,
    required this.allowed,
    required this.send,
    required this.edit,
    required this.keep,
    this.overall = const Duration(seconds: 30),
    this.settle = const Duration(milliseconds: 1500),
    this.revealRate = 40,
    this.revealMax = const Duration(milliseconds: 600),
    this.log,
    this.held,
    this.learn,
    this.offerLife = const Duration(seconds: 8),
    bool Function()? think,
    TidyMode Function(Object sid)? mode,
    this.setMode,
  })  : think = think ?? _no,
        mode = mode ?? _prompt;

  static bool _no() => false;
  static TidyMode _prompt(Object _) => TidyMode.prompt;

  final LlmEndpoint Function() endpoint;
  final LlmApi api;

  /// The switch is on, an endpoint is set and the focus is not a password field.
  final bool Function(Object sid) allowed;

  /// 「AI 整理时先思考」, read at each start.
  final bool Function() think;

  /// The mode the session's tidy runs in: by its app, or what the user chose for it.
  final TidyMode Function(Object sid) mode;

  /// Remembers the mode the user switched to.
  final void Function(Object sid, TidyMode m)? setMode;

  /// Sends the text as a voice send; returns the hint to show, or null when it went.
  final String? Function(Object sid, String text, VoiceOrigin voice) send;

  /// Puts the text in the draft (with [VoiceAi] when it is the AI's) and opens the panel.
  final void Function(Object sid, String text, VoiceAi? ai) edit;

  /// Puts the text at the end of the draft, nothing else.
  final void Function(Object sid, String text) keep;

  /// From the start of the tidy to its end, whatever the stream does.
  final Duration overall;

  /// A done send's wait before it goes, counted from when its last word is out.
  final Duration settle;

  /// The AI's words come out at least this many characters a second, faster when more are waiting: whatever has
  /// arrived is out within [revealMax]. The gateway thinks for seconds and then the whole answer lands in a
  /// fraction of one (measured 2026-11-21); shown as it lands it reads as all at once. Zero: at once.
  final double revealRate;
  final Duration revealMax;
  static const _tick = Duration(milliseconds: 16);
  final void Function(String line)? log;

  /// The original while it waits (tidying or ready), null once it went somewhere. Not on [dispose]: a quit
  /// leaves it held, for the next open to put back.
  final void Function(Object sid, String? original)? held;

  /// Keeps what the user taught: null for a session that must not learn (a password field), and then no offer
  /// ever shows.
  final void Function(Object sid, List<LearnItem> items)? learn;

  /// How long an offer outside the bubble stays.
  final Duration offerLife;
  static const _doneLife = Duration(milliseconds: 1500);

  static const _hintLife = Duration(seconds: 2);

  /// The mode of the tidy that is running or last ran.
  TidyMode get running => _running;
  TidyMode _running = TidyMode.prompt;

  /// The session it belongs to; a reconnect's swap changes it ([moveTo]).
  Object sid;
  TidyPhase get phase => _phase;
  TidyPhase _phase = TidyPhase.idle;
  String get original => _original;
  String _original = '';

  /// What the recognizer heard for [original] (before the device fix); [original] when [begin] was not told.
  /// Kept for comparing and learning (spec D6); not used yet.
  String get heard => _heard;
  String _heard = '';

  /// The AI's text so far; empty until its first chunk.
  String get shown => _shown;
  String _shown = '';

  /// The line shown after the end (note only).
  String? get note => _note;
  String? _note;

  /// The release's pick: what a good result does.
  VoicePick get pick => _pick;
  VoicePick _pick = VoicePick.send;

  /// Where the voice bubble stood at the release (global), for the card to take its place; null: its own place.
  Rect? get at => _at;
  Rect? _at;

  /// The original is open under the AI's words to compare (user 2026-11-20): a done send waits for a click.
  bool get comparing => _comparing;
  bool _comparing = false;

  /// The words the AI changed, each one can flip back to what was heard. Only a done send has them.
  List<TidyChange> get changes => _changes;
  List<TidyChange> _changes = const [];
  final _flips = <int>{};

  bool flipped(int i) => _flips.contains(i);

  /// A flip holds the send for good, like [comparing].
  bool get stopped => _stopped;
  bool _stopped = false;

  /// The AI's text with each flipped change back to the heard words; what goes out and what [editNow] puts in
  /// the panel. Empty before the result.
  String get text {
    final r = _result;
    if (r == null) return '';
    if (_flips.isEmpty) return r;
    final runes = r.runes.toList();
    final b = StringBuffer();
    var at = 0;
    for (var i = 0; i < _changes.length; i++) {
      final c = _changes[i];
      if (!_flips.contains(i)) continue;
      b
        ..write(String.fromCharCodes(runes.sublist(at, c.start)))
        ..write(c.before);
      at = c.end;
    }
    b.write(String.fromCharCodes(runes.sublist(at)));
    return b.toString();
  }

  /// The question to remember a correction, if any.
  LearnOffer? get offer => _offer;
  LearnOffer? _offer;
  int? _offerFor; // the change an in-bubble offer is about
  Timer? _offerTimer;

  /// True while arrived words are still coming out.
  bool get writing => _n < _target.length;

  /// The AI's finished text (from done until it goes somewhere).
  String? _result;

  // The reveal: [_target] is what has arrived, its first [_n] characters are [shown].
  List<int> _target = const [];
  int _n = 0;
  double _speed = 0, _carry = 0;
  Timer? _ticker;

  LlmCall? _call;
  _Ahead? _ahead;
  Timer? _cap;
  Timer? _settleTimer;
  Timer? _noteTimer;
  final _watch = Stopwatch();
  bool _disposed = false;

  /// Flips change [i] between the AI's words and the heard words, and holds the send. Only on a finished text.
  void flip(int i) {
    if (_phase != TidyPhase.ready || writing || i < 0 || i >= _changes.length) return;
    _stopped = true;
    _settleTimer?.cancel();
    _settleTimer = null;
    if (_flips.remove(i)) {
      _log('flip back');
      if (_offerFor == i && _offer != null && _offer!.inBubble) _clearOffer();
    } else {
      _flips.add(i);
      _log('flip');
      final c = _changes[i];
      if (learn != null) {
        _setOffer(
          LearnOffer(items: [LearnItem.preserve(observed: c.before, avoid: c.after, excerpt: learnExcerpt(_original, c.before))], inBubble: true),
          null,
        );
        _offerFor = i;
      }
    }
    notifyListeners();
  }

  /// A small box to remember [items] (at most 3, all picked), gone after [offerLife].
  void offerLearn(List<LearnItem> items) {
    if (learn == null || items.isEmpty || _disposed) return;
    _setOffer(LearnOffer(items: items.take(3).toList(), inBubble: false), offerLife);
    notifyListeners();
  }

  void togglePick(int i) {
    final o = _offer;
    if (o == null || o.done || i < 0 || i >= o.items.length) return;
    if (!o.picked.remove(i)) o.picked.add(i);
    notifyListeners();
  }

  /// Hands the picked items to [learn] and shows "done" a moment.
  void remember() {
    final o = _offer;
    final l = learn;
    if (o == null || o.done || l == null) return;
    final items = [for (var i = 0; i < o.items.length; i++) if (o.picked.contains(i)) o.items[i]];
    if (items.isEmpty) return dismissOffer();
    l(sid, items);
    _log('remember');
    o.done = true;
    _offerTimer?.cancel();
    _offerTimer = Timer(_doneLife, () {
      _clearOffer();
      notifyListeners(); // the 已记住 goes off the screen too
    });
    notifyListeners();
  }

  void dismissOffer() {
    if (_offer == null) return;
    _clearOffer();
    notifyListeners();
  }

  void _setOffer(LearnOffer o, Duration? life) {
    _offerTimer?.cancel();
    _offerTimer = null;
    _offer = o;
    _offerFor = null;
    if (life != null) {
      _offerTimer = Timer(life, () {
        _offerTimer = null;
        _clearOffer();
        notifyListeners();
      });
    }
  }

  void _clearOffer() {
    _offerTimer?.cancel();
    _offerTimer = null;
    _offer = null;
    _offerFor = null;
  }

  // The bubble is going: an unanswered in-bubble question moves to the small box instead of being dropped.
  void _moveOffer() {
    final o = _offer;
    if (o == null || !o.inBubble || o.done) return;
    _setOffer(LearnOffer(items: o.items, inBubble: false, picked: o.picked), offerLife);
  }

  /// More than 10 characters, not counting white space.
  static bool long(String text) => text.replaceAll(RegExp(r'\s'), '').runes.length > 10;

  /// Takes [text] when it is long and the tidy is allowed: starts the call and shows the card. False: the caller
  /// sends or edits as before.
  /// [begin] would take [text] now.
  bool would(String text) => !_disposed && long(text) && allowed(sid);

  /// 边说边整理 (user 2026-11-21): while the words are still being said, a call on them so far, unseen; [begin]
  /// takes it when the release's words are the same, punctuation and white space aside, and the AI is seconds
  /// ahead. New words replace it; null, short words or a tidy not allowed drop it.
  void prefetch(String? text) {
    final a = _ahead;
    if (text == null || _disposed || !long(text) || !allowed(sid)) return _dropAhead();
    final key = _key(text);
    if (a != null && a.key == key && a.result is! LlmFailed) return;
    _dropAhead();
    final m = mode(sid);
    _ahead = _Ahead(key, m, _run(text.trim(), m));
    _log('prefetch (${text.trim().runes.length} chars)');
  }

  static String _key(String t) => t.replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '').toLowerCase();

  void _dropAhead() {
    final a = _ahead;
    _ahead = null;
    a?.call.cancel();
  }

  // The prefetch, when it is on [text] and has not failed; it is no longer a prefetch either way.
  _Ahead? _takeAhead(String text, TidyMode m) {
    final a = _ahead;
    if (a == null || a.key != _key(text) || a.mode != m || a.result is LlmFailed || a.result is LlmCancelled) {
      _dropAhead();
      return null;
    }
    _ahead = null;
    return a;
  }

  // One call to the gateway: its words and its end go to the tidy when it is [_call], else to the prefetch.
  LlmCall _run(String input, TidyMode m) {
    late final LlmCall call;
    call = api.run(endpoint(), m.app, input, think: think(), onText: (t) {
      if (identical(_call, call)) {
        _aim(t);
      } else if (identical(_ahead?.call, call)) {
        _ahead!.text = t;
      }
    });
    unawaited(call.result.then((r) {
      if (identical(_call, call)) {
        _ended(call, r);
      } else if (identical(_ahead?.call, call)) {
        _ahead!.result = r;
      }
    }));
    return call;
  }

  bool begin(String text, VoicePick pick, {Rect? at, String? heard}) {
    if (_disposed || !long(text) || !allowed(sid)) {
      _dropAhead();
      return false;
    }
    if (_phase != TidyPhase.idle) interrupt();
    _clearNote();
    _original = text.trim();
    _heard = (heard ?? text).trim();
    _shown = '';
    _result = null;
    _clearChanges();
    _resetReveal();
    _comparing = false;
    _pick = pick;
    _at = at;
    _phase = TidyPhase.tidying;
    _watch
      ..reset()
      ..start();
    _running = mode(sid);
    final ahead = _takeAhead(_original, _running);
    final call = ahead?.call ?? _run(_original, _running);
    _call = call;
    _startCap(call);
    held?.call(sid, _original);
    _log('start (${_original.runes.length} chars${ahead == null ? '' : ', prefetched ${ahead.age.elapsedMilliseconds} ms ahead'})');
    notifyListeners();
    if (ahead != null) {
      if (ahead.text.isNotEmpty) _aim(ahead.text);
      final r = ahead.result;
      if (r != null) _ended(call, r);
    }
    return true;
  }

  void _startCap(LlmCall call) {
    _cap?.cancel();
    _cap = Timer(overall, () {
      if (!identical(_call, call)) return;
      _stop();
      _log('timeout');
      _fail(tidyTooSlow);
    });
  }

  /// [switchMode] would act now (the card offers ⇄ only then).
  bool get canSwitch => !_disposed && _waiting && !_comparing && !(_pick == VoicePick.edit && _phase == TidyPhase.ready);

  /// 点用途: tidies the original again in the other mode and remembers the choice. The call in flight, the
  /// result, its changes and flips and an offer in the bubble are dropped; nothing is sent. While comparing
  /// nothing changes.
  void switchMode() {
    if (!canSwitch) return;
    final next = _running.other;
    final inBubble = _offer?.inBubble ?? false; // a box from offerLearn is not the bubble's: it stays
    _stop();
    if (inBubble) _clearOffer();
    _shown = '';
    _stopped = false;
    _resetReveal();
    _running = next;
    setMode?.call(sid, next);
    _log('switch mode');
    _phase = TidyPhase.tidying;
    final call = _run(_original, next);
    _call = call;
    _startCap(call);
    held?.call(sid, _original);
    notifyListeners();
  }

  void _ended(LlmCall call, LlmResult r) {
    if (_disposed || !identical(_call, call)) return;
    _cap?.cancel();
    _call = null;
    switch (r) {
      case LlmCancelled():
        return;
      case LlmFailed(:final reason, log: final l):
        _log('failed $l');
        _fail(reason);
      case LlmDone(:final text):
        final t = text.trim();
        if (t.isEmpty) {
          _log('blank');
          _fail(tidyNoResult);
          return;
        }
        _log('done');
        _result = t;
        _changes = _pick == VoicePick.send ? tidyChanges(_original, t) : const [];
        if (_pick != VoicePick.edit) {
          _phase = TidyPhase.ready;
          held?.call(sid, t);
        }
        notifyListeners();
        _aim(t);
    }
  }

  // [text] is what has arrived so far (all of it, not a chunk); it comes out from where [shown] got to.
  void _aim(String text) {
    final runes = text.trimLeft().runes.toList();
    var n = math.min(_n, runes.length);
    for (var i = 0; i < n; i++) {
      if (runes[i] != _target[i]) {
        n = i;
        break;
      }
    }
    _target = runes;
    if (n != _n) {
      _n = n;
      _shown = String.fromCharCodes(_target.take(_n));
      notifyListeners();
    }
    final waiting = _target.length - _n;
    if (waiting > 0 && revealMax <= Duration.zero) {
      _n = _target.length;
      _shown = String.fromCharCodes(_target);
      notifyListeners();
      return _caughtUp();
    }
    if (waiting == 0) return _caughtUp();
    _speed = math.max(revealRate, waiting / (revealMax.inMicroseconds / 1e6));
    _ticker ??= Timer.periodic(_tick, (_) => _step());
  }

  void _step() {
    _carry += _speed * _tick.inMicroseconds / 1e6;
    final k = _carry.floor();
    if (k > 0) {
      _carry -= k;
      _n = math.min(_n + k, _target.length);
      _shown = String.fromCharCodes(_target.take(_n));
      notifyListeners();
    }
    if (!writing) {
      _ticker?.cancel();
      _ticker = null;
      _carry = 0;
      _caughtUp();
    }
  }

  // Every arrived word is out: a done tidy goes on to what its pick does.
  void _caughtUp() {
    final t = _result;
    if (t == null || _call != null) return;
    if (_pick == VoicePick.edit && _phase == TidyPhase.tidying) {
      _phase = TidyPhase.idle;
      _result = null;
      edit(sid, t, _ai(t));
      _release();
      notifyListeners();
    } else if (_phase == TidyPhase.ready && !_comparing && !_stopped && _settleTimer == null) {
      _settleTimer = Timer(settle, () {
        _settleTimer = null;
        if (_phase == TidyPhase.ready) _sendResult();
      });
      notifyListeners();
    }
  }

  void _resetReveal() {
    _ticker?.cancel();
    _ticker = null;
    _target = const [];
    _n = 0;
    _carry = 0;
  }

  VoiceAi _ai(String t) => VoiceAi(app: _running.app, original: _original, result: t);

  void _sendResult() {
    final r = _result!;
    final t = text;
    _stop();
    _log('send result');
    final hint = send(sid, t, VoiceOrigin(ai: _ai(r)));
    _release();
    _endWith(hint);
  }

  // The original as heard, as the release's pick would have done without a tidy.
  void _goOriginal() {
    _stop();
    if (_pick == VoicePick.edit) {
      _phase = TidyPhase.idle;
      edit(sid, _original, null);
      _release();
      notifyListeners();
      return;
    }
    final hint = send(sid, _original, const VoiceOrigin());
    _release();
    _endWith(hint);
  }

  // After a send: a hint shows a while; otherwise the card goes.
  void _endWith(String? hint) {
    if (hint != null) {
      _showNote(hint, _hintLife);
    } else {
      _phase = TidyPhase.idle;
      notifyListeners();
    }
  }

  // Quietly (§8.1 D3): [reason] is for the log only.
  void _fail(String reason) {
    _log('gave up: $reason');
    _goOriginal();
  }

  void _release() => held?.call(sid, null);

  /// 发送 / 直接发送: what the card shows goes now — the AI's text once it is done, else the original as heard.
  void sendNow() {
    if (_phase == TidyPhase.ready || _result != null) return _sendResult();
    if (!_waiting) return;
    _stop();
    _log('send original');
    final hint = send(sid, _original, const VoiceOrigin());
    _release();
    _endWith(hint);
  }

  /// The original opens under the AI's words; a done send no longer goes on its own.
  void compare() {
    if (!_waiting || _comparing) return;
    _comparing = true;
    _settleTimer?.cancel();
    _settleTimer = null;
    _log('compare');
    notifyListeners();
  }

  /// 还原 while a done send waits: the original goes instead, unmarked.
  void restore() {
    if (_phase != TidyPhase.ready) return;
    _log('restore');
    _goOriginal();
  }

  /// 编辑: what the card shows goes in the panel (the AI's text with its mark once it is done).
  void editNow() {
    if (!_waiting) return;
    final r = _result;
    final t = r != null ? text : _original;
    _stop();
    _log(r != null ? 'edit result' : 'edit original');
    _phase = TidyPhase.idle;
    edit(sid, t, r != null ? _ai(r) : null);
    _release();
    notifyListeners();
  }

  /// A new press: a done send goes first (it was about to); anything else waiting stays in the draft, unsent.
  void interrupt() {
    if (_phase == TidyPhase.ready || (_result != null && _pick == VoicePick.send)) return _sendResult();
    closed();
  }

  /// The session is going for good, or something takes the card away: what waits stays in the draft, nothing
  /// is sent.
  void closed() {
    if (_phase == TidyPhase.note) {
      _clearNote();
      _phase = TidyPhase.idle;
      notifyListeners();
      return;
    }
    if (!_waiting) return;
    final kept = _result != null ? text : _original;
    final inBubble = _offer?.inBubble ?? false; // a box from offerLearn is not the bubble's: a new press keeps it
    _stop();
    if (inBubble) _clearOffer();
    _log('interrupted');
    _phase = TidyPhase.idle;
    keep(sid, kept);
    _release();
    notifyListeners();
  }

  /// The session is going for good: stops without keeping anything itself, and hands back the
  /// original it was waiting with (null: nothing waiting), for the caller to put where the session's
  /// text goes. ([closed] keeps it through the composer, which an editor makes asynchronous.)
  String? end() {
    if (!_waiting) {
      closed();
      return null;
    }
    final kept = _result != null ? text : _original;
    _stop();
    _clearOffer();
    _log('ended');
    _phase = TidyPhase.idle;
    _release();
    notifyListeners();
    return kept;
  }

  /// A reconnect's swap: the session is [sid] now.
  void moveTo(Object to) => sid = to;

  bool get _waiting => _phase == TidyPhase.tidying || _phase == TidyPhase.ready;

  void _stop() {
    _cap?.cancel();
    _cap = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    _result = null;
    _clearChanges();
    _moveOffer();
    _ticker?.cancel();
    _ticker = null;
    final c = _call;
    _call = null;
    c?.cancel();
  }

  void _clearChanges() {
    _changes = const [];
    _flips.clear();
    _stopped = false;
  }

  void _showNote(String note, Duration life) {
    _phase = TidyPhase.note;
    _note = note;
    _noteTimer?.cancel();
    _noteTimer = Timer(life, () {
      _note = null;
      _noteTimer = null;
      if (_phase == TidyPhase.note) _phase = TidyPhase.idle;
      notifyListeners();
    });
    notifyListeners();
  }

  void _clearNote() {
    _noteTimer?.cancel();
    _noteTimer = null;
    _note = null;
  }

  void _log(String what) => log?.call('voice tidy: ${_running.app} $what ${_watch.elapsedMilliseconds} ms');

  @override
  void dispose() {
    _disposed = true;
    _stop();
    _dropAhead();
    _clearNote();
    _clearOffer();
    super.dispose();
  }
}

/// A [VoiceTidy.prefetch]: the words it is on (as compared), its call, and what has come back so far.
class _Ahead {
  _Ahead(this.key, this.mode, this.call);
  final String key;
  final TidyMode mode;
  final LlmCall call;
  final age = Stopwatch()..start();
  String text = '';
  LlmResult? result;
}
