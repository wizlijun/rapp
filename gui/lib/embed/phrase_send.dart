// What one 常用语 tap does (phrases spec §4): its own round with Return after, or the text put at the end of the
// draft; refused, never queued, while the session cannot take it.
import 'dart:async';

import '../ui/main_state.dart';
import 'composer_model.dart';
import 'phrases.dart';
import '../quick/key_actions.dart';
import '../term/term_session_port.dart';
import 'key_bar.dart';
import 'key_bar_keys.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'strip_cmds.dart';
import 'strip_tools.dart';

/// How a tap ended.
enum PhraseOutcome {
  /// It went (its Return follows once A has it all).
  sent,

  /// 放进输入框: it is at the end of the draft, the panel open.
  put,

  /// Within [phraseRepeatWindow] of the last one sent: ignored.
  tooSoon,

  /// Offline, frozen or detaching.
  offline,

  /// A round is still going.
  busy,

  /// A strip command this tool does not have (or cannot be sent here).
  missing,
}

/// The strip's words for a refused tap; null when there is nothing to say.
String? phraseHint(PhraseOutcome o) => switch (o) {
      PhraseOutcome.offline => '连接已断开',
      PhraseOutcome.busy => '上一条还在发',
      _ => null,
    };

/// [phraseHint], and the strip command that [tool] does not have.
String? stripHint(PhraseOutcome o, {AgentTool? tool}) =>
    o == PhraseOutcome.missing ? '${tool!.name} 没有这个命令' : phraseHint(o);

/// Why a tap would be refused right now, or null when one may go; the strip greys while it is not null.
PhraseOutcome? phraseBlock(MainState state, RemoteSession session) {
  if (state.isDetaching(session.sid) || state.sendBlocked(session.sid)) return PhraseOutcome.offline;
  if (session.composer.busy) return PhraseOutcome.busy;
  return null;
}

/// When a phrase last went, per session: a second tap within [phraseRepeatWindow] is ignored.
final Expando<DateTime> _lastPhrase = Expando('phrase');

/// One tap on [p] for [session]. [now] is for tests.
PhraseOutcome sendPhrase({
  required MainState state,
  required RemoteSession session,
  required SessionPort port,
  required Phrase p,
  DateTime Function() now = DateTime.now,
}) {
  final c = session.composer;
  if (p.put) {
    c.open = true;
    unawaited(c.keep(p.text).then((_) => c.wantFocus()));
    return PhraseOutcome.put;
  }
  final t = now();
  final last = _lastPhrase[session];
  if (last != null && t.difference(last) < phraseRepeatWindow) return PhraseOutcome.tooSoon;
  final blocked = phraseBlock(state, session);
  if (blocked != null) return blocked;
  switch (c.submitText(p.text, phrase: true)) {
    case SubmitPieces(:final pieces):
      _lastPhrase[session] = t;
      session.prepareInput();
      port.composerSend(session.sid, pieces);
      return PhraseOutcome.sent;
    case _:
      return PhraseOutcome.busy;
  }
}

/// One tap on the command [c] for [session], read as [tool] spells it. Shares [phraseBlock] and the repeat window with
/// [sendPhrase]; a text command is its own round (Return after, never recorded), a key goes straight to the terminal.
PhraseOutcome sendStripCmd({
  required MainState state,
  required RemoteSession session,
  required SessionPort port,
  required StripCmd c,
  required AgentTool tool,
  DateTime Function() now = DateTime.now,
}) {
  final t = now();
  final last = _lastPhrase[session];
  if (last != null && t.difference(last) < phraseRepeatWindow) return PhraseOutcome.tooSoon;
  final blocked = phraseBlock(state, session);
  if (blocked != null) return blocked;
  switch (actionFor(c, tool)) {
    case CmdText(:final text):
      switch (session.composer.submitText(text, command: true)) {
        case SubmitPieces(:final pieces):
          _lastPhrase[session] = t;
          session.prepareInput();
          port.composerSend(session.sid, pieces);
          return PhraseOutcome.sent;
        case _:
          return PhraseOutcome.busy;
      }
    case CmdKey(:final key):
      // Only a pty terminal shows commands; the modifier latch is neither read nor cleared.
      final wire = barKeys[key]?.wire;
      if (port is! TermSessionPort || wire == null) return PhraseOutcome.missing;
      _lastPhrase[session] = t;
      port.sendKeys(session.sid, [termWire(wire, 0)]);
      return PhraseOutcome.sent;
    case null:
      return PhraseOutcome.missing;
  }
}

/// Whether [a] can go on [tool] at all: it has a chord there, and a terminal can express it (a wire name, or one of
/// rApp's own ⌘ letters; whether the stage has registered that callback is checked when it is sent). An app takes any.
bool keyActionUsable(KeyAction a, {required bool term, AgentTool? tool}) {
  final c = chordFor(a, tool);
  if (c == null) return false;
  return !term || c.termWire != null || c.termCommand != null;
}

/// One tap on the key action [a] for [session], read as [tool] has it. Shares the repeat window and the offline check
/// with [sendPhrase]; a busy round does not matter (a key does not go through the composer), and the modifier latch is
/// neither read nor cleared.
PhraseOutcome sendKeyAction({
  required MainState state,
  required RemoteSession session,
  required SessionPort port,
  required KeyAction a,
  AgentTool? tool,
  DateTime Function() now = DateTime.now,
}) {
  final t = now();
  final last = _lastPhrase[session];
  if (last != null && t.difference(last) < phraseRepeatWindow) return PhraseOutcome.tooSoon;
  if (state.isDetaching(session.sid) || state.sendBlocked(session.sid)) return PhraseOutcome.offline;
  final chord = chordFor(a, tool);
  if (chord == null) return PhraseOutcome.missing;
  if (port is TermSessionPort) {
    final letter = chord.termCommand;
    final wire = chord.termWire;
    if (letter != null) {
      final run = session.termCommand;
      if (run == null) return PhraseOutcome.missing;
      run(letter);
    } else if (wire != null) {
      port.sendKeys(session.sid, [termWire(wire, 0)]);
    } else {
      return PhraseOutcome.missing;
    }
  } else {
    final k = chord.macKey;
    port.key(session.sid, k.code, k.mods);
  }
  _lastPhrase[session] = t;
  return PhraseOutcome.sent;
}
