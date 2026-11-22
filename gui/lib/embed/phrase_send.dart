// What one 常用语 tap does (phrases spec §4): its own round with Return after, or the text put at the end of the
// draft; refused, never queued, while the session cannot take it.
import 'dart:async';

import '../ui/main_state.dart';
import 'composer_model.dart';
import 'phrases.dart';
import 'remote_session.dart';
import 'session_port.dart';

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
}

/// The strip's words for a refused tap; null when there is nothing to say.
String? phraseHint(PhraseOutcome o) => switch (o) {
      PhraseOutcome.offline => '连接已断开',
      PhraseOutcome.busy => '上一条还在发',
      _ => null,
    };

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
