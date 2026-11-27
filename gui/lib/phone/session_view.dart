/// The phone's in-session view (V1b Task 8): the existing stage widgets, never the Pad's `Stage`.
/// A text terminal asks with `fit: false`, so A's rows and columns stay as they are (S4, F11). Over it, the Pad's
/// composer layer, lock banner and host notice (R34, one implementation).
library;

import 'package:flutter/material.dart';

import '../embed/picture.dart';
import '../embed/session_port.dart';
import '../term/term_stage.dart';
import '../ui/disconnected_stage.dart';
import '../ui/lifecycle.dart';
import '../ui/main_state.dart';
import '../ui/stage.dart' show PixelSnap, keyboardLift, stageOverlays;
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
        builder: (context, _) => PhonePage(onBack: nav.home, keepHomeBar: true, child: _body(context, t)),
      ),
    );
  }

  Widget _body(BuildContext context, RappTokens t) {
    final problem = state.hubProblem;
    if (problem != null) return Center(child: Text(problem, textAlign: TextAlign.center, style: TextStyle(color: t.text)));
    if (state.current == null) {
      // The session ended (结束) or is gone: back to the home page.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (nav.now == PhoneView.session) nav.home();
      });
      return const SizedBox.shrink();
    }
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
    Widget body;
    var picture = false, full = false, term = false;
    if (rec != null && rec.frozen && rs != null && !rs.detached && win != null && !isTerm) {
      picture = true;
      body = Picture(state: state, session: rs, window: win, frozen: true, keyboard: keyboard);
    } else if (isTerm &&
        ((rec?.phase == Phase.live && rec?.lastSid == null) ||
            (rec?.frozen == true && !rs.detached && rs.windows.isNotEmpty))) {
      full = true;
      term = true;
      body = PixelSnap(
        child: TermStage(
          state: state,
          session: rs,
          port: state.termPort!,
          frozen: rec?.frozen == true,
          keyboard: keyboard,
          fit: false,
        ),
      );
    } else if (rec != null && (rec.phase == Phase.disconnected || rec.lastSid != null)) {
      full = true;
      body = DisconnectedStage(
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
    } else if (rs != null && !rs.detached && win != null) {
      picture = true;
      body = Picture(state: state, session: rs, window: win, keyboard: keyboard);
    } else {
      body = Center(child: Text('正在连接', style: TextStyle(color: t.muted)));
    }
    // The Pad's own composer layer, offline bar, lock banner and host notice over the body (R34). They float over
    // it and never resize anything: only the Pad's Stage calls stageSize (S4, F11).
    return Stack(children: [
      Positioned.fill(child: body),
      ...stageOverlays(context,
          state: state, rec: rec, rs: rs, term: term, picture: picture, full: full, keyboard: keyboard),
    ]);
  }
}
