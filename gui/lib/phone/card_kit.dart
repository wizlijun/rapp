/// What a phone card needs to reply, shared by the home page's focus card and the card pinned inside a session
/// (V1c Task 14): one implementation, two places.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/main_state.dart';
import 'home_model.dart';
import 'phone_nav.dart';
import 'phone_voice.dart';
import 'reply_model.dart';

class PhoneCardKit {
  PhoneCardKit(this.state, this.nav);
  final MainState state;
  final PhoneNav nav;

  CardReply cardReply(HomeItem card) {
    final p = card.id.split('\n');
    final row = p.length == 3 && p[0] == 'term'
        ? state.hub?.termLists[p[1]]?.terms.where((r) => r.id == p[2]).firstOrNull
        : null;
    return replyOf(card, row: row, deviceReply: p.length == 3 && deviceCanReply(state.probes, p[1]));
  }

  /// A done terminal of a device this machine has no terminal list for: only the service can clear it.
  bool viaService(HomeItem i) {
    final p = i.id.split('\n');
    return p.length == 3 &&
        p[0] == 'term' &&
        state.stateSync != null &&
        !(state.hub?.termLists.containsKey(p[1]) ?? false);
  }

  /// 「知道了」: the card goes, and the service hears of it.
  void gotIt(HomeItem item) {
    final sync = state.stateSync;
    nav.gotIt.add(item.gotItKey);
    if (item.kind == HomeKind.resource && item.need != null) {
      state.snoozeNeed(item.need!);
    }
    final eid = item.eid;
    if (eid != null) sync?.markHandled(eid);
    if (item.kind == HomeKind.done && viaService(item)) {
      final p = item.id.split('\n');
      sync?.markSeen(p[1], p[2]);
    }
  }

  /// Hold to talk needs a recogniser, a target, the session to go into, and for 「要改」 the seq and its keys:
  /// without any of them the words would have nowhere to go.
  bool canVoice(HomeItem item, CardReply reply) {
    if (state.voice == null || reply.target == null || item.sessionKey == null) return false;
    if (reply.kind == ReplyKind.review) return reply.seq != null && reply.planRevise != null;
    return true;
  }

  /// 「说一句」 / 「要改」: hold to talk; the words go through the reply path, no view (V4). 「编辑」 goes through
  /// [editIn].
  Widget voiceFor(
    HomeItem item,
    CardReply reply,
    String label,
    ReplyVoiceUse use, {
    required void Function(HomeItem item, String text) editIn,
    required bool Function() mounted,
  }) {
    final t = reply.target!;
    final seq = reply.seq;
    final keys = reply.planRevise;
    final revise = use == ReplyVoiceUse.revise && seq != null && keys != null;
    final replies = nav.replies;
    return PhoneVoice(
      state: state,
      key2: '${item.gotItKey}\n${use.name}',
      send: (text, voice) {
        if (revise) {
          unawaited(_revised(item, replies.revise(item.id, t, seq, keys, text)));
        } else {
          unawaited(replies.say(item.id, t, text));
        }
        return null;
      },
      edit: (text) {
        if (revise) {
          unawaited(_reviseEdit(item, t, seq, keys, text, editIn, mounted));
        } else {
          editIn(item, text);
        }
      },
      builder: (context, hold) => phoneVoiceButton(hold, label),
    );
  }

  Future<void> _revised(HomeItem item, Future<bool> sent) async {
    final ok = await sent;
    final eid = item.pointsEid;
    if (ok && eid != null) nav.replies.markEid(eid);
  }

  /// 要改 → 编辑: the edit key goes first; only if it went does the session open with the words in its draft.
  Future<void> _reviseEdit(
    HomeItem item,
    ReplyTarget t,
    int seq,
    List<String> keys,
    String text,
    void Function(HomeItem, String) editIn,
    bool Function() mounted,
  ) async {
    final ok = await nav.replies.keys(item.id, t, seq, keys, doneWord: '已发出');
    if (!ok) return;
    final eid = item.pointsEid;
    if (eid != null) nav.replies.markEid(eid);
    if (mounted()) editIn(item, text);
  }
}
