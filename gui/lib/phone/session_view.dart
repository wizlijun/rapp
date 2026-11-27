/// The phone's in-session view (V1b Task 8): the existing stage widgets, never the Pad's `Stage`.
/// A text terminal asks with `fit: false`, so A's rows and columns stay as they are (S4, F11).
library;

import 'package:flutter/material.dart';

import '../embed/picture.dart';
import '../embed/session_port.dart';
import '../term/term_stage.dart';
import '../ui/disconnected_stage.dart';
import '../ui/lifecycle.dart';
import '../ui/main_state.dart';
import '../ui/stage.dart' show keyboardLift, offlineBarFor;
import '../ui/tokens.dart';
import 'phone_nav.dart';
import 'widgets.dart';

class PhoneSessionView extends StatelessWidget {
  const PhoneSessionView({super.key, required this.state, required this.nav});
  final MainState state;
  final PhoneNav nav;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Scaffold(
      resizeToAvoidBottomInset: false, // the keyboard covers, it never squeezes (F12)
      backgroundColor: t.bg,
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => PhonePage(onBack: nav.home, child: _body(context, t)),
      ),
    );
  }

  Widget _body(BuildContext context, RappTokens t) {
    final rec = state.currentRecord;
    final rs = state.currentRemote;
    final keyboard = keyboardLift(MediaQuery.of(context), fullscreen: false);
    RemoteWindow? win;
    if (rs != null && rs.ready) {
      for (final w in rs.windows) {
        if (w.id == rs.currentWindow && w.hasPicture) win = w;
      }
    }
    final isTerm = rs != null && state.termPort?.owns(rs.sid) == true;
    if (rec != null && rec.frozen && rs != null && !rs.detached && win != null && !isTerm) {
      return Stack(children: [
        Positioned.fill(child: Picture(state: state, session: rs, window: win, frozen: true, keyboard: keyboard)),
        Positioned(top: 0, left: 0, right: 0, child: offlineBarFor(state, rec)),
      ]);
    }
    if (isTerm &&
        ((rec?.phase == Phase.live && rec?.lastSid == null) ||
            (rec?.frozen == true && !rs.detached && rs.windows.isNotEmpty))) {
      return Stack(children: [
        Positioned.fill(
          child: TermStage(
            state: state,
            session: rs,
            port: state.termPort!,
            frozen: rec?.frozen == true,
            keyboard: keyboard,
            fit: false,
          ),
        ),
        if (rec != null && rec.frozen) Positioned(top: 0, left: 0, right: 0, child: offlineBarFor(state, rec)),
      ]);
    }
    if (rec != null && (rec.phase == Phase.disconnected || rec.lastSid != null)) {
      return DisconnectedStage(
        session: rs,
        reason: disconnectWord(rec.reason),
        reconnectWord: reconnectLabel(rec.reason),
        connecting: rec.phase != Phase.disconnected,
        onReconnect: state.hubUsable ? state.reconnectCurrent : null,
        retrying: rec.retry != null,
        waiting: state.waitWordOf(rec),
        onStop: state.stopReconnectCurrent,
        onEnd: state.endCurrent,
        sessionKey: rec.key,
      );
    }
    if (rs != null && !rs.detached && win != null) {
      return Picture(state: state, session: rs, window: win, keyboard: keyboard);
    }
    return Center(child: Text('正在连接', style: TextStyle(color: t.muted)));
  }
}
