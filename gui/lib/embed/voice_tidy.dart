// 长语音先让 AI 整理 (spec 2026-11-20-rapp-voice-ai-tidy-design.md §5.2): a voice text longer than 10 characters
// goes through the gateway's `dictation` before it is sent or put in the panel. The user can send or edit the
// original at any time; a failure stops and waits for them, nothing is sent on its own.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../llm_api.dart';
import 'composer_model.dart' show VoiceAi, VoiceOrigin;
import 'voice_ring.dart' show VoicePick;

const tidyApp = 'dictation';
const tidyNoResult = 'AI 没有给出结果';
const tidyTooSlow = 'LLM 没有及时回应';
const tidySent = '已用 AI 整理';

enum TidyPhase { idle, tidying, failed, note }

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
    this.log,
    this.held,
    this.failed,
  });

  final LlmEndpoint Function() endpoint;
  final LlmApi api;

  /// The switch is on, an endpoint is set and the focus is not a password field.
  final bool Function(Object sid) allowed;

  /// Sends the text as a voice send; returns the hint to show, or null when it went.
  final String? Function(Object sid, String text, VoiceOrigin voice) send;

  /// Puts the text in the draft (with [VoiceAi] when it is the AI's) and opens the panel.
  final void Function(Object sid, String text, VoiceAi? ai) edit;

  /// Puts the text at the end of the draft, nothing else.
  final void Function(Object sid, String text) keep;

  /// From the start of the tidy to its end, whatever the stream does.
  final Duration overall;
  final void Function(String line)? log;

  /// The original while it waits (tidying or failed), null once it went somewhere. Not on [dispose]: a quit
  /// leaves it held, for the next open to put back.
  final void Function(Object sid, String? original)? held;

  /// The tidy failed and waits for a click.
  final void Function(Object sid, String reason)? failed;

  static const _sentLife = Duration(milliseconds: 1500);
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

  /// Why it failed (failed only).
  String? get reason => _reason;
  String? _reason;

  /// The line shown after the end (note only).
  String? get note => _note;
  String? _note;

  /// The release's pick: what a good result does.
  VoicePick get pick => _pick;
  VoicePick _pick = VoicePick.send;

  LlmCall? _call;
  Timer? _cap;
  Timer? _noteTimer;
  final _watch = Stopwatch();
  bool _disposed = false;

  /// More than 10 characters, not counting white space.
  static bool long(String text) => text.replaceAll(RegExp(r'\s'), '').runes.length > 10;

  /// Takes [text] when it is long and the tidy is allowed: starts the call and shows the card. False: the caller
  /// sends or edits as before.
  bool begin(String text, VoicePick pick) {
    if (_disposed || !long(text) || !allowed(sid)) return false;
    if (_phase == TidyPhase.tidying || _phase == TidyPhase.failed) interrupt();
    _clearNote();
    _original = text.trim();
    _shown = '';
    _reason = null;
    _pick = pick;
    _phase = TidyPhase.tidying;
    _watch
      ..reset()
      ..start();
    late final LlmCall call;
    call = api.run(endpoint(), tidyApp, _original, onText: (t) {
      if (!identical(_call, call)) return;
      _shown = t;
      notifyListeners();
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
        final ai = VoiceAi(app: tidyApp, original: _original, result: t);
        if (_pick == VoicePick.edit) {
          _phase = TidyPhase.idle;
          edit(sid, t, ai);
          _release();
          notifyListeners();
        } else {
          final hint = send(sid, t, VoiceOrigin(ai: ai));
          _release();
          _showNote(hint ?? tidySent, hint == null ? _sentLife : _hintLife);
        }
    }
  }

  void _fail(String reason) {
    _phase = TidyPhase.failed;
    _reason = reason;
    failed?.call(sid, reason);
    notifyListeners();
  }

  void _release() => held?.call(sid, null);

  /// 直接发送: the original goes, as heard.
  void sendOriginal() {
    if (!_waiting) return;
    _stop();
    _log('send original');
    final hint = send(sid, _original, const VoiceOrigin());
    _release();
    if (hint != null) {
      _showNote(hint, _hintLife);
    } else {
      _phase = TidyPhase.idle;
      notifyListeners();
    }
  }

  /// 编辑: the original goes in the panel.
  void editOriginal() {
    if (!_waiting) return;
    _stop();
    _log('edit original');
    _phase = TidyPhase.idle;
    edit(sid, _original, null);
    _release();
    notifyListeners();
  }

  /// A new press, or anything that takes the card away: the original stays in the draft, nothing is sent.
  void interrupt() {
    if (_phase == TidyPhase.note) {
      _clearNote();
      _phase = TidyPhase.idle;
      notifyListeners();
      return;
    }
    if (!_waiting) return;
    _stop();
    _log('interrupted');
    _phase = TidyPhase.idle;
    keep(sid, _original);
    _release();
    notifyListeners();
  }

  /// The session is going for good: as [interrupt].
  void closed() => interrupt();

  /// The session is going for good: stops without keeping anything itself, and hands back the
  /// original it was waiting with (null: nothing waiting), for the caller to put where the session's
  /// text goes. ([closed] keeps it through the composer, which an editor makes asynchronous.)
  String? end() {
    if (!_waiting) {
      interrupt();
      return null;
    }
    _stop();
    _log('ended');
    _phase = TidyPhase.idle;
    _release();
    notifyListeners();
    return _original;
  }

  /// A reconnect's swap: the session is [sid] now.
  void moveTo(Object to) => sid = to;

  bool get _waiting => _phase == TidyPhase.tidying || _phase == TidyPhase.failed;

  void _stop() {
    _cap?.cancel();
    _cap = null;
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
