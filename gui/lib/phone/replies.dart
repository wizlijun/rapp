/// The phone's reply controller: the local "is the question still current" check, the send through the hub, the 3 s
/// watch of the terms push that judges success, and the per-card outcome word. It never resends.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../hub_client.dart' show HubException, TermRow;
import '../ui/main_state.dart';
import 'reply_model.dart';

/// How long the terms push gets to show the session left the question.
const replySettle = Duration(seconds: 3);

const _gone = '它已经不在等这一问了';
const _goLook = '没成功，进去看看';
const _oldRun = '这个会话是升级前开的，进去看看';
const _noLink = '连不上 A，没发';

/// What a card says about the reply it just sent.
class ReplyOutcome {
  const ReplyOutcome(this.word, {this.pending = false, this.failed = false});
  final String word;

  /// Sent, and the 3 s watch is still running.
  final bool pending;

  /// The word tells the person to go and look.
  final bool failed;
}

typedef ReplySender = Future<void> Function(ReplyTarget t, {int? seq, String? text, bool enter, List<String> keys});

class PhoneReplies extends ChangeNotifier {
  PhoneReplies(this.state, {ReplySender? send, this.settle = replySettle, this.reviseGap = const Duration(milliseconds: 400)})
      : _send = send; // ignore: prefer_initializing_formals

  final MainState state;
  final Duration settle, reviseGap;
  final ReplySender? _send;
  final Map<String, ReplyOutcome> _outcomes = {};
  final Map<String, ({Timer timer, VoidCallback off})> _watches = {};
  bool _disposed = false;

  ReplyOutcome? outcomeOf(String itemId) => _outcomes[itemId];

  Future<void> _go(ReplyTarget t, {int? seq, String? text, bool enter = false, List<String> keys = const []}) {
    final s = _send;
    if (s != null) return s(t, seq: seq, text: text, enter: enter, keys: keys);
    return state.hub!.replyTerm(t.device, t.term, seq: seq, text: text, enter: enter, keys: keys);
  }

  TermRow? _row(ReplyTarget t) => state.hub?.termLists[t.device]?.terms.where((r) => r.id == t.term).firstOrNull;

  void _set(String id, ReplyOutcome? o) {
    if (_disposed) return;
    if (o == null) {
      _outcomes.remove(id);
    } else {
      _outcomes[id] = o;
    }
    notifyListeners();
  }

  /// A button of the card: [keys] go with the question's [seq]; [doneWord] says it went.
  /// Returns true only when the keys were sent (not refused up front, not failed).
  Future<bool> keys(String itemId, ReplyTarget t, int? seq, List<String> keys, {required String doneWord}) async {
    if (!_ready(itemId, t, seq)) return false;
    final base = _base(t);
    if (!await _sendOnce(itemId, doneWord, () => _go(t, seq: seq, keys: keys))) return false;
    _watch(itemId, t, base, doneWord);
    return true;
  }

  /// A spoken or typed reply: the text and Enter, with no seq.
  /// Blank text sends nothing. Returns true only when it was sent.
  Future<bool> say(String itemId, ReplyTarget t, String text) async {
    if (text.trim().isEmpty || !_ready(itemId, t, null)) return false;
    final base = _base(t);
    if (!await _sendOnce(itemId, '已发出', () => _go(t, text: text, enter: true))) return false;
    _record(t, text);
    _watch(itemId, t, base, '已发出');
    return true;
  }

  /// 「要改」: the key that opens the program's edit box (with the seq), a short gap, then the words and Enter.
  /// Blank text sends nothing. Returns true only when it was sent.
  Future<bool> revise(String itemId, ReplyTarget t, int seq, List<String> keys, String text) async {
    if (text.trim().isEmpty || !_ready(itemId, t, seq)) return false;
    final base = _base(t);
    final ok = await _sendOnce(itemId, '已发出', () async {
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

  /// Offline, or the question is gone locally: the word, and nothing is sent.
  bool _ready(String id, ReplyTarget t, int? seq) {
    if (_watches.containsKey(id) || _outcomes[id]?.pending == true) return false;
    if (!state.hubUsable || state.offlineWord(t.device, t.term) == '设备离线') {
      _set(id, const ReplyOutcome(_noLink, failed: true));
      return false;
    }
    final ps = _row(t)?.ps;
    if (seq != null && (ps == null || ps.state != 'blocked' || ps.seq != seq)) {
      _set(id, const ReplyOutcome(_gone, failed: true));
      return false;
    }
    return true;
  }

  (String, int)? _base(ReplyTarget t) {
    final ps = _row(t)?.ps;
    return ps == null ? null : (ps.state, ps.seq);
  }

  Future<bool> _sendOnce(String id, String word, Future<void> Function() go) async {
    _set(id, ReplyOutcome(word, pending: true));
    try {
      await go();
      return true;
    } on HubException catch (e) {
      final m = e.message;
      final word = m.contains('older version')
          ? _oldRun
          : (m == 'changed' || m == 'typed' ? _gone : _goLook);
      _set(id, ReplyOutcome(word, failed: true));
    } catch (_) {
      _set(id, const ReplyOutcome(_goLook, failed: true));
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
      _set(id, o);
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
    super.dispose();
  }
}
