/// The phone's in-session view (V1b Task 8): the existing stage widgets, never the Pad's `Stage`.
/// A text terminal asks with `fit: false`, so A's rows and columns stay as they are (S4, F11). Over it, the Pad's
/// composer layer, lock banner and host notice (R34, one implementation).
/// A text terminal opens in the reading view (V1c Task 14); 「看原样」 shows the stage. The card waiting on the session
/// is pinned at the bottom, over the reply bar. Nothing here asks A to resize (S4).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../embed/picture.dart';
import '../embed/remote_session.dart';
import '../embed/session_port.dart';
import '../embed/stage_buttons.dart' show stageButtonSize, stageButtonsUp;
import '../embed/voice_button.dart';
import '../term/term_stage.dart';
import '../ui/disconnected_stage.dart';
import '../ui/lifecycle.dart';
import '../ui/controls.dart' show RappButton;
import '../ui/main_state.dart';
import '../ui/stage.dart' show PixelSnap, keyboardLift, stageOverlays;
import '../ui/tokens.dart';
import '../term/term_model.dart';
import 'card_kit.dart';
import 'home_model.dart';
import 'home_screen.dart' show phoneHomeModel;
import 'phone_nav.dart';
import 'phone_voice.dart';
import 'reading_view.dart';
import 'reply_bar.dart';
import 'reply_card.dart';
import 'reply_model.dart';
import 'widgets.dart';

const _edgeWidth = 20.0;
const _edgeSwipe = 80.0;

class PhoneSessionView extends StatefulWidget {
  const PhoneSessionView({super.key, required this.state, required this.nav});
  final MainState state;
  final PhoneNav nav;

  @override
  State<PhoneSessionView> createState() => _PhoneSessionViewState();
}

class _PhoneSessionViewState extends State<PhoneSessionView> {
  /// 「看原样」 is on: the terminal stage instead of the reading view, for this session.
  bool _raw = false;
  String? _rawKey;
  double _drag = 0;

  MainState get _s => widget.state;
  PhoneNav get _nav => widget.nav;
  late final PhoneCardKit _kit = PhoneCardKit(_s, _nav);

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Scaffold(
      resizeToAvoidBottomInset: false, // the keyboard covers, it never squeezes (F12)
      backgroundColor: t.bg,
      body: ListenableBuilder(
        listenable: Listenable.merge([_s, _nav]),
        builder: (context, _) {
          final key = _s.currentKey;
          if (_rawKey != key) {
            _rawKey = key;
            _raw = false;
          }
          final model = _termModel();
          return PhonePage(
            onBack: _nav.home,
            keepHomeBar: true,
            trailing: model == null ? null : _rawToggle(t),
            child: _body(context, t, model),
          );
        },
      ),
    );
  }

  /// The model of the terminal on show, null for a picture or no session.
  TermModel? _termModel() {
    final rs = _s.currentRemote;
    final port = _s.termPort;
    if (rs == null || port == null || !port.owns(rs.sid)) return null;
    return port.model(rs.sid);
  }

  Widget _rawToggle(RappTokens t) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return InkWell(
      key: const Key('raw-toggle'),
      onTap: () => setState(() => _raw = !_raw),
      child: Container(
        constraints: const BoxConstraints(minWidth: phoneTap),
        height: phoneTap,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(_raw ? '看阅读视图' : '看原样', style: style?.copyWith(color: t.text)),
      ),
    );
  }

  Widget _body(BuildContext context, RappTokens t, TermModel? model) {
    final problem = _s.hubProblem;
    if (problem != null) {
      return Center(
        child: Text(
          problem,
          textAlign: TextAlign.center,
          style: TextStyle(color: t.text),
        ),
      );
    }
    if (_s.current == null) {
      // The session ended (结束) or is gone: back to the home page.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_nav.now == PhoneView.session) _nav.home();
      });
      return const SizedBox.shrink();
    }
    final state = _s;
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
    var picture = false, full = false, term = false, reading = false;
    if (rec != null && rec.frozen && rs != null && !rs.detached && win != null && !isTerm) {
      picture = true;
      body = Picture(state: state, session: rs, window: win, frozen: true, keyboard: keyboard);
    } else if (isTerm &&
        ((rec?.phase == Phase.live && rec?.lastSid == null) ||
            (rec?.frozen == true && !rs.detached && rs.windows.isNotEmpty))) {
      full = true;
      term = true;
      reading = !_raw && model != null;
      // The stage stays mounted while reading, so the view and the model keep going; it just is not shown (S4).
      final stage = Offstage(
        offstage: reading,
        child: ExcludeFocus(
          excluding: reading,
          child: PixelSnap(
            child: TermStage(
              state: state,
              session: rs,
              port: state.termPort!,
              frozen: rec?.frozen == true,
              keyboard: keyboard,
              fit: false,
            ),
          ),
        ),
      );
      // One tree shape either way, so the stage's State survives every toggle.
      body = Stack(children: [
        Positioned.fill(child: stage),
        if (reading)
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(bottom: _readingLift),
              child: PhoneReadingView(model: model),
            ),
          ),
      ]);
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
      body = Center(
        child: Text('正在连接', style: TextStyle(color: t.muted)),
      );
    }
    // The Pad's own composer layer, offline bar, lock banner and host notice over the body (R34). They float over
    // it and never resize anything: only the Pad's Stage calls stageSize (S4, F11).
    return Stack(
      children: [
        Positioned.fill(child: body),
        // Back by a swipe from the left edge: the reading view only (S7). The overlays are laid after it and win.
        if (reading)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _edgeWidth,
            child: GestureDetector(
              key: const Key('edge-back'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => _drag = 0,
              onHorizontalDragUpdate: (d) => _drag += d.delta.dx,
              onHorizontalDragEnd: (_) {
                if (_drag > _edgeSwipe) _nav.home();
                _drag = 0;
              },
            ),
          ),
        ...stageOverlays(
          context,
          state: state,
          rec: rec,
          rs: rs,
          term: term,
          picture: picture,
          full: full,
          keyboard: keyboard,
          phoneStack: term && rs != null ? (context, hold, bottom) => _stack(context, rs, hold, bottom, reading) : null,
        ),
      ],
    );
  }

  /// The ReplyTarget of the session on show, when it can take replies without a view (T14-1).
  ReplyTarget? _replyTarget(String? key) {
    if (key == null) return null;
    final i = key.indexOf('/');
    if (i <= 0) return null;
    final device = key.substring(0, i), term = key.substring(i + 1);
    final row = _s.hub?.termLists[device]?.terms.where((r) => r.id == term).firstOrNull;
    if (row == null || !row.reply || !deviceCanReply(_s.probes, device)) return null;
    return ReplyTarget(device, term);
  }

  HomeItem? _pinned(String? key) {
    if (key == null) return null;
    return phoneHomeModel(_s, _nav).items.where((i) => i.sessionKey == key).firstOrNull;
  }

  void _toDraft(RemoteSession rs, String text) {
    unawaited(rs.composer.keep(text));
    rs.composer.open = true;
  }

  /// What stands over the dock: the pinned card, the outcome line, the reply bar. [bottom] is where the stack of the
  /// Pad would stand (8 above the dock, or above the keyboard).
  Widget _stack(BuildContext context, RemoteSession rs, VoiceHold? hold, double bottom, bool reading) {
    final key = _s.currentKey;
    final target = _replyTarget(key);
    final pinned = _pinned(key);
    final itemId = pinned?.id ?? 'session\n$key';
    final replies = _nav.replies;
    final open = rs.composer.open;
    final onType = rs.composerAllowed ? (open ? rs.composer.collapse : () => rs.composer.open = true) : null;
    Widget bar(VoiceHold? h) => PhoneReplyBar(hold: h, onType: onType, open: open && rs.composerAllowed);
    final Widget barWidget;
    if (target != null && _s.voice != null) {
      barWidget = PhoneVoice(
        key: ValueKey(('reply-voice', rs.sid)),
        state: _s,
        key2: rs.sid,
        // The composer layer draws this key's tidy card already.
        ownTidyCard: false,
        send: (text, voice) {
          unawaited(replies.say(itemId, target, text));
          return null;
        },
        edit: (text) => _toDraft(rs, text),
        builder: (context, h) => bar(h),
      );
    } else {
      barWidget = bar(hold);
    }
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium!;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: phoneMaxWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (pinned != null) ...[
                Flexible(child: SingleChildScrollView(child: _pinnedCard(rs, pinned))),
                const SizedBox(height: 12),
              ] else
                ListenableBuilder(
                  listenable: replies,
                  builder: (context, _) {
                    final o = replies.outcomeOf(itemId);
                    if (o == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(o.word, style: style.copyWith(color: t.muted)),
                          ),
                          if (o.failed) ...[
                            const SizedBox(width: 12),
                            PhoneButton(label: '进去看', tall: true, onPressed: () => setState(() => _raw = true)),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              if (!reading && rs.currentZoomed) ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: RappButton.stage(
                    key: const Key('zoom-reset'),
                    label: '还原',
                    icon: Icons.zoom_in_map,
                    size: stageButtonSize,
                    onPressed: rs.restoreCurrent,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              barWidget,
              if (hold != null && target == null)
                ListenableBuilder(
                  listenable: hold,
                  builder: (context, _) => hold.hint == null
                      ? const SizedBox.shrink()
                      : Padding(padding: const EdgeInsets.only(top: 8), child: voiceHint(hold)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The card waiting on this session, the same one the home page shows (S3).
  Widget _pinnedCard(RemoteSession rs, HomeItem card) {
    final reply = _kit.cardReply(card);
    if (reply.kind == ReplyKind.none) {
      return PhoneCard(item: card, onOpen: null, onButton: null, actions: const SizedBox.shrink());
    }
    return PhoneCard(
      item: card,
      onOpen: null,
      onButton: null,
      actions: ReplyActions(
        item: card,
        reply: reply,
        replies: _nav.replies,
        voice: _kit.canVoice(card, reply)
            ? (label, use) => _kit.voiceFor(
                card,
                reply,
                label,
                use,
                editIn: (item, text) => _toDraft(rs, text),
                mounted: () => mounted,
              )
            : null,
        onGotIt: reply.kind == ReplyKind.done ? () => setState(() => _kit.gotIt(card)) : null,
      ),
    );
  }
}

/// The reading view stops above the bar and the dock's rest place (a longer stack covers a little more).
const _readingLift = stageButtonsUp + phonePrimaryTap + 12;
