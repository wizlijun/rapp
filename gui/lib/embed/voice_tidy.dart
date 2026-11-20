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
import 'voice_ring.dart' show VoicePick;

const tidyApp = 'dictation';
const tidyNoResult = 'AI 没有给出结果';
const tidyTooSlow = 'LLM 没有及时回应';

/// tidying: the AI is writing; ready: it is done and the send waits [VoiceTidy.settle]; note: a hint after the end.
enum TidyPhase { idle, tidying, ready, note }

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
    bool Function()? think,
  }) : think = think ?? _no;

  static bool _no() => false;

  final LlmEndpoint Function() endpoint;
  final LlmApi api;

  /// The switch is on, an endpoint is set and the focus is not a password field.
  final bool Function(Object sid) allowed;

  /// 「AI 整理时先思考」, read at each start.
  final bool Function() think;

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

  static const _hintLife = Duration(seconds: 2);

  /// The session it belongs to; a reconnect's swap changes it ([moveTo]).
  Object sid;
  TidyPhase get phase => _phase;
  TidyPhase _phase = TidyPhase.idle;
  String get original => _original;
  String _original = '';

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
  Timer? _cap;
  Timer? _settleTimer;
  Timer? _noteTimer;
  final _watch = Stopwatch();
  bool _disposed = false;

  /// More than 10 characters, not counting white space.
  static bool long(String text) => text.replaceAll(RegExp(r'\s'), '').runes.length > 10;

  /// Takes [text] when it is long and the tidy is allowed: starts the call and shows the card. False: the caller
  /// sends or edits as before.
  /// [begin] would take [text] now.
  bool would(String text) => !_disposed && long(text) && allowed(sid);

  bool begin(String text, VoicePick pick, {Rect? at}) {
    if (_disposed || !long(text) || !allowed(sid)) return false;
    if (_phase != TidyPhase.idle) interrupt();
    _clearNote();
    _original = text.trim();
    _shown = '';
    _result = null;
    _resetReveal();
    _comparing = false;
    _pick = pick;
    _at = at;
    _phase = TidyPhase.tidying;
    _watch
      ..reset()
      ..start();
    late final LlmCall call;
    call = api.run(endpoint(), tidyApp, _original, think: think(), onText: (t) {
      if (!identical(_call, call)) return;
      _aim(t);
    });
    _call = call;
    _cap = Timer(overall, () {
      if (!identical(_call, call)) return;
      _stop();
      _log('timeout');
      _fail(tidyTooSlow);
    });
    unawaited(call.result.then((r) => _ended(call, r)));
    held?.call(sid, _original);
    _log('start (${_original.runes.length} chars)');
    notifyListeners();
    return true;
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
    } else if (_phase == TidyPhase.ready && !_comparing && _settleTimer == null) {
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

  VoiceAi _ai(String t) => VoiceAi(app: tidyApp, original: _original, result: t);

  void _sendResult() {
    final t = _result!;
    _stop();
    _log('send result');
    final hint = send(sid, t, VoiceOrigin(ai: _ai(t)));
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
    _stop();
    _log(r != null ? 'edit result' : 'edit original');
    _phase = TidyPhase.idle;
    edit(sid, r ?? _original, r != null ? _ai(r) : null);
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
    final text = _result ?? _original;
    _stop();
    _log('interrupted');
    _phase = TidyPhase.idle;
    keep(sid, text);
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
    final text = _result ?? _original;
    _stop();
    _log('ended');
    _phase = TidyPhase.idle;
    _release();
    notifyListeners();
    return text;
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
    _ticker?.cancel();
    _ticker = null;
    final c = _call;
    _call = null;
    c?.cancel();
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

  void _log(String what) => log?.call('voice tidy: $tidyApp $what ${_watch.elapsedMilliseconds} ms');

  @override
  void dispose() {
    _disposed = true;
    _stop();
    _clearNote();
    super.dispose();
  }
}
