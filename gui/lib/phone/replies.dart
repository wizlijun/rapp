/// The phone's reply controller: the local "is the question still current" check, the send through the hub, the 3 s
/// watch of the terms push that judges success, and the per-card outcome word (which a later question takes away).
/// It never resends.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../hub_client.dart' show HubException, TermRow;
import '../ui/main_state.dart';
import 'reply_model.dart';

/// How long the terms push gets to show the session left the question.
const replySettle = Duration(seconds: 3);

/// How long 「它已经不在等这一问了」 stays on the card before the card shows the session as it is now (C12, F-11).
const replyGoneFor = Duration(seconds: 3);

const _gone = '它已经不在等这一问了';
const _goLook = '没成功，进去看看';
const _oldRun = '这个会话是升级前开的，进去看看';
const _noLink = '连不上 A，没发';
const _cardFirst = '先点上面卡片的按钮';

/// What a card says about the reply it just sent.
class ReplyOutcome {
  const ReplyOutcome(this.word, {this.pending = false, this.failed = false});
  final String word;

  /// Sent, and the 3 s watch is still running.
  final bool pending;

  /// The word tells the person to go and look.
  final bool failed;
}

/// A word kept on a card, with what the session looked like when it was set: a later question shows its buttons.
class _Kept {
  const _Kept(this.o, this.t, this.base, this.row, {this.timed = false});
  final ReplyOutcome o;
  final ReplyTarget? t;

  /// The row's `(state, seq)` the word is about: for a failure, the question the person pressed on (F-9), else the
  /// row when the word was set.
  final (String, int)? base;

  /// The row itself, for 连不上 A: the next row update takes that word away.
  final TermRow? row;

  /// 「它已经不在等这一问了」: shown for [replyGoneFor] whatever the row does, then gone.
  final bool timed;
}

typedef ReplySender = Future<void> Function(ReplyTarget t, {int? seq, String? text, bool enter, List<String> keys});

class PhoneReplies extends ChangeNotifier {
  PhoneReplies(this.state, {ReplySender? send, this.settle = replySettle, this.reviseGap = const Duration(milliseconds: 400)})
      : _send = send; // ignore: prefer_initializing_formals

  final MainState state;
  final Duration settle, reviseGap;
  final ReplySender? _send;
  final Map<String, _Kept> _outcomes = {};
  final Map<String, ({Timer timer, VoidCallback off})> _watches = {};
  final Map<String, Timer> _goneTimers = {};
  bool _disposed = false;

  /// The word on card [itemId]. A word that is not pending lasts only while the session is where it was when the
  /// word was set: a new state or seq (a new question) drops it, and 连不上 A goes with the next row update.
  /// 「它已经不在等这一问了」 is the exception: it shows for [replyGoneFor], then the card shows the new state.
  ReplyOutcome? outcomeOf(String itemId) {
    final k = _outcomes[itemId];
    if (k == null) return null;
    final t = k.t;
    if (k.o.pending || k.timed || t == null) return k.o;
    final moved = k.o.word == _noLink ? !identical(_row(t), k.row) : _base(t) != k.base;
    if (moved) {
      _outcomes.remove(itemId);
      return null;
    }
    return k.o;
  }

  Future<void> _go(ReplyTarget t, {int? seq, String? text, bool enter = false, List<String> keys = const []}) {
    final s = _send;
    if (s != null) return s(t, seq: seq, text: text, enter: enter, keys: keys);
    return state.hub!.replyTerm(t.device, t.term, seq: seq, text: text, enter: enter, keys: keys);
  }

  TermRow? _row(ReplyTarget t) => state.hub?.termLists[t.device]?.terms.where((r) => r.id == t.term).firstOrNull;

  void _set(String id, ReplyOutcome? o, [ReplyTarget? t]) {
    if (_disposed) return;
    _goneTimers.remove(id)?.cancel();
    if (o == null) {
      _outcomes.remove(id);
    } else {
      _outcomes[id] = _Kept(o, t, t == null ? null : _base(t), t == null ? null : _row(t));
    }
    notifyListeners();
  }

  /// A failure word about the question [pressed] (the `(state, seq)` the person pressed on), not the row now: the
  /// push of a newer question may land before the error of the older send, and the word must not cover its buttons.
  /// 「它已经不在等这一问了」 instead stays [replyGoneFor] (C12): the card says so, then shows the new question.
  void _fail(String id, ReplyOutcome o, ReplyTarget t, (String, int)? pressed) {
    if (_disposed) return;
    _goneTimers.remove(id)?.cancel();
    final timed = o.word == _gone;
    final k = _outcomes[id] = _Kept(o, t, pressed, _row(t), timed: timed);
    if (timed) {
      _goneTimers[id] = Timer(replyGoneFor, () {
        _goneTimers.remove(id);
        if (_disposed || !identical(_outcomes[id], k)) return;
        _outcomes.remove(id);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// A button of the card: [keys] go with the question's [seq]; [doneWord] says it went.
  /// Returns true only when the keys were sent (not refused up front, not failed).
  Future<bool> keys(String itemId, ReplyTarget t, int? seq, List<String> keys, {required String doneWord}) async {
    if (!_ready(itemId, t, seq, 'blocked')) return false;
    final base = _base(t);
    if (!await _sendOnce(itemId, t, base, doneWord, () => _go(t, seq: seq, keys: keys))) return false;
    _watch(itemId, t, base, doneWord);
    return true;
  }

  /// A spoken or typed reply: the text and Enter. With [seq] (a done card's) it is for that status snapshot only:
  /// the holder refuses a moved one. Blank text sends nothing. Returns true only when it was sent.
  /// Said to a working or idle session it went when the hub took it (the program may queue it and stay as it is);
  /// only a waiting or done one is watched for 3 s.
  Future<bool> say(String itemId, ReplyTarget t, String text, {int? seq}) async {
    if (text.trim().isEmpty || !_ready(itemId, t, seq, 'done')) return false;
    final base = _base(t);
    if (!await _sendOnce(itemId, t, base, '已发出', () => _go(t, seq: seq, text: text, enter: true))) return false;
    _record(t, text);
    if (base != null && (base.$1 == 'blocked' || base.$1 == 'done')) {
      _watch(itemId, t, base, '已发出');
    } else {
      _set(itemId, null);
    }
    return true;
  }

  /// The session's reply bar. While the session waits on a question nothing goes (Enter would pick its first
  /// item): [barId] says to use the card. Otherwise as [say] on [itemId].
  Future<bool> sayFromBar(String barId, String itemId, ReplyTarget t, String text) async {
    if (text.trim().isEmpty) return false;
    if (_row(t)?.ps?.state == 'blocked') {
      _set(barId, const ReplyOutcome(_cardFirst), t);
      return false;
    }
    return say(itemId, t, text);
  }

  /// 「要改」: the key that opens the program's edit box (with the seq), a short gap, then the words and Enter.
  /// Blank text sends nothing. Returns true only when it was sent.
  Future<bool> revise(String itemId, ReplyTarget t, int seq, List<String> keys, String text) async {
    if (text.trim().isEmpty || !_ready(itemId, t, seq, 'blocked')) return false;
    final base = _base(t);
    final ok = await _sendOnce(itemId, t, base, '已发出', () async {
      await _go(t, seq: seq, keys: keys);
      await Future<void>.delayed(reviseGap);
      await _go(t, text: text, enter: true);
    });
    if (!ok) return false;
    _record(t, text);
    _watch(itemId, t, base, '已发出');
    return true;
  }

  /// After 「同意」 or 「要改」 went: the queue row [eid] is handled.
  void markEid(String eid) => unawaited(state.stateSync?.markHandled(eid));

  /// Offline, or the question is gone locally: the word, and nothing is sent. [card] is the state of the card that
  /// was pressed: 'blocked' (a [seq] must be a waiting question's) or 'done' (any snapshot's, a done card's).
  bool _ready(String id, ReplyTarget t, int? seq, String card) {
    if (_watches.containsKey(id) || _outcomes[id]?.o.pending == true) return false;
    if (!state.hubUsable || state.offlineWord(t.device, t.term) == '设备离线') {
      _set(id, const ReplyOutcome(_noLink, failed: true), t);
      return false;
    }
    final ps = _row(t)?.ps;
    if (seq != null && (ps == null || (card == 'blocked' && ps.state != 'blocked') || ps.seq != seq)) {
      // The pressed card is out of date: it says so for 3 s, then shows the session as it is now.
      _fail(id, const ReplyOutcome(_gone, failed: true), t, (card, seq));
      return false;
    }
    return true;
  }

  (String, int)? _base(ReplyTarget t) {
    final ps = _row(t)?.ps;
    return ps == null ? null : (ps.state, ps.seq);
  }

  /// [pressed]: the row's `(state, seq)` at the press; a failure word is kept against it.
  Future<bool> _sendOnce(String id, ReplyTarget t, (String, int)? pressed, String word, Future<void> Function() go) async {
    _set(id, ReplyOutcome(word, pending: true));
    try {
      await go();
      return true;
    } on HubException catch (e) {
      final m = e.message;
      final word = m.contains('older version')
          ? _oldRun
          : (m == 'changed' || m == 'typed' ? _gone : _goLook);
      _fail(id, ReplyOutcome(word, failed: true), t, pressed);
    } catch (_) {
      _fail(id, const ReplyOutcome(_goLook, failed: true), t, pressed);
    }
    return false;
  }

  void _record(ReplyTarget t, String text) {
    final row = _row(t);
    if (row == null) return;
    unawaited(state.recorder.replied(state.replyMeta(t.device, row), text, DateTime.now()));
  }

  /// 3 s on the terms push: the question left (state or seq moved, or the row went) is success.
  void _watch(String id, ReplyTarget t, (String, int)? base, String doneWord) {
    final hub = state.hub;
    bool left() {
      final ps = _row(t)?.ps;
      if (_row(t) == null || ps == null || base == null) return true;
      return ps.state != base.$1 || ps.seq != base.$2;
    }

    void end(ReplyOutcome? o) {
      final w = _watches.remove(id);
      w?.timer.cancel();
      w?.off();
      _set(id, o, t);
    }

    if (hub == null || left()) {
      _set(id, null);
      return;
    }
    _set(id, ReplyOutcome(doneWord, pending: true));
    void onPush() {
      if (left()) end(null); // the card leaves, or stays as it is now (a done one): the word goes
    }

    hub.addListener(onPush);
    _watches[id] = (
      timer: Timer(settle, () => end(const ReplyOutcome(_goLook, failed: true))),
      off: () => hub.removeListener(onPush),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    for (final w in _watches.values) {
      w.timer.cancel();
      w.off();
    }
    _watches.clear();
    for (final g in _goneTimers.values) {
      g.cancel();
    }
    _goneTimers.clear();
    super.dispose();
  }
}
