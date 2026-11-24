// Hold to talk on the Mac stage: the 按住说话 button at the right end of the composer row, the bubble above it,
// the 编辑 / 取消 targets, and the hotkey's events driving the same hold. The hold itself is [VoiceHold].
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'composer_model.dart' show VoiceOrigin;
import 'remote_session.dart';
import 'session_port.dart';
import 'voice_button.dart';
import 'voice_input.dart';
import 'voice_key_gate.dart';
import 'voice_overlay.dart';
import 'voice_ring.dart';

/// Where the pointer is: on a target (each inflated by 6), else the button, which sends.
VoicePick desktopPick(Offset p, Rect cancel, Rect edit) {
  if (cancel.inflate(6).contains(p)) return VoicePick.cancel;
  if (edit.inflate(6).contains(p)) return VoicePick.edit;
  return VoicePick.send;
}

const _fade = Duration(milliseconds: 120);
const _rise = Duration(milliseconds: 160);
const _bars = 24;

/// What the bubble and the hint keep clear on the stage's left.
const _leftClear = 20.0;

/// The row's right end: [others] (the rest of the row) then the 按住说话 button. Owns the session's [VoiceHold].
class DesktopVoice extends StatefulWidget {
  const DesktopVoice({
    super.key,
    required this.state,
    required this.session,
    required this.port,
    required this.maxWidth,
    required this.others,
  });

  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  /// The width the row's column may take: the stage less the row's right inset (12, or the key row's).
  /// The bubble and the hint keep 20 clear on the left, so without the key row the bubble is the spec's
  /// `min(stage − 32, 480)`.
  final double maxWidth;

  /// The row's other items, which fade out while a hold is on.
  final List<Widget> others;

  @override
  State<DesktopVoice> createState() => _DesktopVoiceState();
}

class _DesktopVoiceState extends State<DesktopVoice> with SingleTickerProviderStateMixin {
  late final VoiceHold _hold;
  // Always shown: what it holds (the column, the hint or nothing) is built with the row.
  final _portal = OverlayPortalController()..show();
  StreamSubscription<(Object, VoiceKeyPhase)>? _keys;
  final _editBox = GlobalKey();
  final _cancelBox = GlobalKey();
  final _bubbleBox = GlobalKey();
  bool _handing = false;
  bool _mouse = false;
  int? _pointer;
  List<double> _levels = List.filled(_bars, 0);

  // The column's exit after a release: 1 is fully there. [VoiceHold.showing] holds the rest of the row back meanwhile.
  late final AnimationController _exit = AnimationController(vsync: this, duration: _rise, value: 1);
  bool _up = false;
  bool _gone = false;
  bool _reduced = false;
  VoicePick _released = VoicePick.send;
  String _said = '';

  MainState get _state => widget.state;
  Object get _sid => widget.session.sid;

  @override
  void initState() {
    super.initState();
    final voice = _state.voice!;
    _hold = VoiceHold(
      voice: voice,
      // The widget, not the first one: a rebuild may bring a new port for the same session.
      send: (text, heard) => sendVoice(
          state: widget.state, session: widget.session, port: widget.port, text: text, voice: VoiceOrigin(heard: heard)),
      edit: (text, heard) {
        final c = widget.session.composer;
        unawaited(c.keep(text));
        c.pendingHeard = heard;
        c.open = true;
      },
      composer: () => widget.session.composer,
      tidy: (text, pick, at, heard) =>
          widget.state.tidyOf(widget.session.sid).begin(text, pick, at: at, heard: heard.heard),
      fix: (t) => widget.state.voiceFix(widget.session.sid, t),
      log: widget.state.voiceLog,
      wouldTidy: (text) => widget.state.tidyOf(widget.session.sid).would(text),
      onPress: () => widget.state.tidyIfAny(widget.session.sid)?.interrupt(),
      prefetch: (t) => t == null
          ? widget.state.tidyIfAny(widget.session.sid)?.prefetch(null)
          : widget.state.tidyOf(widget.session.sid).prefetch(t),
      onEnd: _ended,
      languageHintDue: () => !widget.state.prefs.voiceLanguageHintShown,
      languageHintShown: widget.state.voiceLanguageHintDone,
    );
    _hold.addListener(_onHold);
    voice.level.addListener(_onLevel);
    _keys = _state.voiceKeys.listen(_onKey);
    _exit.addStatusListener(_onExit);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
  }

  void _onExit(AnimationStatus s) {
    if (s == AnimationStatus.dismissed && !_up) _hold.showing = false;
  }

  @override
  void dispose() {
    _gone = true;
    _exit.dispose();
    _keys?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _clearMouseHold();
    _state.voice?.level.removeListener(_onLevel);
    _hold.removeListener(_onHold);
    _hold.dispose();
    super.dispose();
  }

  void _ended(VoicePick? p) {
    final mouse = _mouse;
    _mouse = false;
    _pointer = null;
    _clearMouseHold();
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _state.voiceEnd(_sid);
    if (_gone) return; // a dispose cut it short: nothing to give focus back to
    // A mouse press blurred the picture: it gets focus back unless the panel took it (R17).
    // The hotkey never blurred it, so it only refocuses where it did before.
    final panel = p == VoicePick.edit && widget.session.composer.open;
    if (mouse ? !panel : (p == VoicePick.send || p == VoicePick.cancel)) _state.focusPicture(_sid);
  }

  void _clearMouseHold() {
    if (_state.voiceMouseHold == _sid) _state.voiceMouseHold = null;
  }

  void _onHold() {
    if (_hold.holding && !_up) {
      _up = true;
      _levels = List.filled(_bars, 0);
      _said = '';
      _exit.value = 1;
      if (_hold.showing) _hold.showing = false;
    } else if (!_hold.holding && _up) {
      _up = false;
      _released = _hold.pick;
      _hold.bubbleAt = _rectOf(_bubbleBox);
      if (_hold.handingOver) {
        // The tidy will likely take the words: the bubble stays as it is until its card stands in its place.
        _handing = true;
        _hold.showing = true;
        _exit.value = 1;
      } else {
        _goOut();
      }
    } else if (_handing && !_hold.handingOver) {
      _handing = false;
      if (_hold.handedOver) {
        // The card is in this frame, where the bubble was.
        _exit.value = 0;
        _hold.showing = false;
      } else {
        _goOut();
      }
    }
    if (!_hold.holding) _levels = List.filled(_bars, 0);
  }

  // Instant with reduced motion; else the column stays up, fading (a send also rises), while the row waits.
  void _goOut() {
    if (_reduced) {
      _hold.showing = false;
      return;
    }
    _hold.showing = true;
    _exit.value = 1;
    unawaited(_exit.reverse());
  }

  void _onLevel() {
    if (!_hold.holding || _hold.pick == VoicePick.cancel) return;
    final v = _state.voice;
    if (v != null && mounted) setState(() => _levels = [..._levels.skip(1), v.level.value]);
  }

  void _onKey((Object, VoiceKeyPhase) e) {
    if (e.$1 != _sid) return;
    switch (e.$2) {
      case VoiceKeyPhase.start:
        if (_mouse) return; // the text area open or not, as a mouse hold (and iOS)
        unawaited(_hold.start());
      case VoiceKeyPhase.release:
        _hold.finish(VoicePick.send);
      case VoiceKeyPhase.cancel:
        _hold.finish(VoicePick.cancel);
      case VoiceKeyPhase.edit:
        _hold.finish(VoicePick.edit);
    }
  }

  // Only while a mouse hold is on: Esc cancels, Tab edits.
  bool _onKeyEvent(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _hold.finish(VoicePick.cancel);
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.tab) {
      _hold.finish(VoicePick.edit);
      return true;
    }
    return false;
  }

  Rect? _rectOf(GlobalKey k) {
    final box = k.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _down(PointerDownEvent e) {
    if (_pointer != null || _mouse || _hold.active || e.buttons & kPrimaryButton == 0) return;
    // A recogniser still busy (an old stop out) would refuse the start and never end the press.
    if (_state.voice!.phase != VoicePhase.idle) return;
    _pointer = e.pointer;
    _mouse = true;
    _state.voiceMouseHold = _sid;
    _state.holdForPanel(widget.session);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    unawaited(_hold.start());
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final c = _rectOf(_cancelBox), ed = _rectOf(_editBox);
    _hold.choose(c == null || ed == null ? VoicePick.send : desktopPick(e.position, c, ed));
  }

  void _lift(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _hold.finish(e is PointerCancelEvent ? VoicePick.cancel : _hold.pick);
  }

  @override
  Widget build(BuildContext context) {
    final voice = _state.voice!;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_hold, voice]),
      builder: (context, _) {
        final active = _hold.active;
        final above = active
            ? _column(context, reduced)
            : _hold.hint != null
            ? voiceHint(_hold, maxWidth: math.max(0.0, widget.maxWidth - _leftClear))
            : null;
        // The bubble, the targets and the hint stand 8 above the row's right end, in the overlay: the input block
        // (drawn over the corner row) must not cover them (input-dock final review).
        return OverlayPortal.overlayChildLayoutBuilder(
          controller: _portal,
          overlayChildBuilder: (context, info) {
            if (above == null) return const SizedBox.shrink();
            final corner = MatrixUtils.transformPoint(info.childPaintTransform, Offset(info.childSize.width, 0));
            return Stack(
              children: [
                Positioned(
                  right: info.overlaySize.width - corner.dx,
                  bottom: info.overlaySize.height - corner.dy + 8,
                  child: KeyedSubtree(key: const Key('voice-above'), child: above),
                ),
              ],
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedOpacity(
                opacity: active ? 0 : 1,
                duration: reduced ? Duration.zero : _fade,
                child: IgnorePointer(
                  ignoring: active,
                  child: Listener(
                    onPointerDown: (_) => _state.holdForPanel(widget.session),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [...widget.others, const SizedBox(width: 8)]),
                  ),
                ),
              ),
              Listener(
                onPointerDown: _down,
                onPointerMove: _move,
                onPointerUp: _lift,
                onPointerCancel: _lift,
                child: Tooltip(
                  message: '按住说话',
                  triggerMode: TooltipTriggerMode.manual,
                  child: RappButton.secondary(
                    key: const Key('voice-hold'),
                    label: '按住说话',
                    semanticLabel: '语音',
                    icon: _hold.holding ? Icons.mic : Icons.mic_none,
                    onPicture: true,
                    seeThrough: true,
                    // A no-op keeps the enabled look; the Listener does the work.
                    onPressed: () {},
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _column(BuildContext context, bool reduced) {
    final t = RappTokens.of(context);
    final pick = _hold.holding ? _hold.pick : _released;
    final width = (widget.maxWidth - _leftClear).clamp(0.0, 480.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduced ? 1 : 0, end: 1),
      duration: reduced ? Duration.zero : _rise,
      curve: Curves.easeOut,
      builder: (context, v, child) => AnimatedBuilder(
        animation: _exit,
        builder: (context, _) {
          // Out: a send rises as it fades; 取消 and 编辑 fade where they are.
          final o = _exit.value;
          final rise = _hold.holding || pick != VoicePick.send ? 0.0 : -8 * (1 - o);
          return Opacity(
            opacity: v * o,
            child: Transform.translate(offset: Offset(0, 8 * (1 - v) + rise), child: child),
          );
        },
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _bubble(context, t, pick, width),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _target(t, const Key('voice-edit'), _editBox, Icons.edit_outlined, '编辑', 'Tab', pick == VoicePick.edit),
              const SizedBox(width: 8),
              _target(t, const Key('voice-cancel'), _cancelBox, Icons.close, '取消', 'Esc', pick == VoicePick.cancel),
            ],
          ),
          const SizedBox(height: 4),
          DecoratedBox(
            decoration: t.floatBox(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(voiceHintLine(pick), style: TextStyle(color: t.text, fontSize: 13, height: 1.4)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _target(RappTokens t, Key key, GlobalKey box, IconData icon, String label, String keyName, bool on) =>
      KeyedSubtree(
        key: key,
        child: Container(
          key: box,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: on ? t.accent : Color.alphaBlend(t.raise.first, t.float.first),
            border: Border.all(color: on ? t.accent : t.line),
            borderRadius: BorderRadius.circular(t.r),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: on ? t.accentInk : t.text),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: on ? t.accentInk : t.text, fontSize: 15)),
              const SizedBox(width: 6),
              Text(keyName, style: TextStyle(color: on ? t.accentInk : t.muted, fontSize: 12)),
            ],
          ),
        ),
      );

  Widget _bubble(BuildContext context, RappTokens t, VoicePick pick, double width) {
    final voice = _state.voice!;
    final (fill, ink, border) = switch (pick) {
      VoicePick.send => (t.text, t.bg, null),
      VoicePick.cancel => (t.raise.first, t.muted, t.line),
      VoicePick.edit => (t.float.first, t.text, t.text),
    };
    final style = TextStyle(color: ink, fontSize: 17, height: 1.35);
    // Holding: the live words. Going out: the last of them (a cancel has cleared the recogniser's).
    final said = _hold.holding ? (_said = _hold.fixedText) : _said;
    final words = said.isEmpty ? '正在听…' : voiceTail(said, style, width - 32, MediaQuery.textScalerOf(context));
    return KeyedSubtree(
      key: _bubbleBox,
      child: CustomPaint(
        key: const Key('voice-bubble'),
        painter: VoiceBubbleFrame(
          fill: fill,
          border: border,
          dashed: pick == VoicePick.edit,
          right: true,
          radius: t.r,
          tail: false,
        ),
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                pick == VoicePick.edit
                    ? Text.rich(
                        TextSpan(
                          text: words,
                          children: [
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: SizedBox(width: 1.5, height: 20, child: ColoredBox(color: t.text)),
                            ),
                          ],
                        ),
                        style: style,
                      )
                    : Text(words, style: style),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: CustomPaint(
                    size: const Size(_bars * 4 - 2, 20),
                    painter: VoiceBarsPainter(
                      level: voice.level.value,
                      levels: _levels,
                      color: ink,
                      still: pick == VoicePick.cancel,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
