// Hold to talk on the Mac stage: the 按住说话 button at the right end of the composer row, the bubble above it,
// the 编辑 / 取消 targets, and the hotkey's events driving the same hold. The hold itself is [VoiceHold].
import 'dart:async';

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'voice_button.dart';
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

/// The row's right end: [others] (the rest of the row) then the 按住说话 button. Owns the session's [VoiceHold].
class DesktopVoice extends StatefulWidget {
  const DesktopVoice({
    super.key,
    required this.state,
    required this.session,
    required this.port,
    required this.stageWidth,
    required this.others,
  });

  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  /// The stage's width: the bubble is at most 32 narrower.
  final double stageWidth;

  /// The row's other items, which fade out while a hold is on.
  final List<Widget> others;

  @override
  State<DesktopVoice> createState() => _DesktopVoiceState();
}

class _DesktopVoiceState extends State<DesktopVoice> {
  late final VoiceHold _hold;
  StreamSubscription<(Object, VoiceKeyPhase)>? _keys;
  final _editBox = GlobalKey();
  final _cancelBox = GlobalKey();
  bool _mouse = false;
  int? _pointer;
  List<double> _levels = List.filled(_bars, 0);

  MainState get _state => widget.state;
  Object get _sid => widget.session.sid;

  @override
  void initState() {
    super.initState();
    final voice = _state.voice!;
    _hold = VoiceHold(
      voice: voice,
      // The widget, not the first one: a rebuild may bring a new port for the same session.
      send: (text) => sendVoice(state: widget.state, session: widget.session, port: widget.port, text: text),
      edit: (text) {
        final c = widget.session.composer;
        unawaited(c.keep(text));
        c.open = true;
      },
      composer: () => widget.session.composer,
      onEnd: _ended,
      languageHintDue: () => !widget.state.prefs.voiceLanguageHintShown,
      languageHintShown: widget.state.voiceLanguageHintDone,
    );
    _hold.addListener(_onHold);
    voice.level.addListener(_onLevel);
    _keys = _state.voiceKeys.listen(_onKey);
  }

  @override
  void dispose() {
    _keys?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _state.voice?.level.removeListener(_onLevel);
    _hold.removeListener(_onHold);
    _hold.dispose();
    super.dispose();
  }

  void _ended(VoicePick? p) {
    _mouse = false;
    _pointer = null;
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _state.voiceEnd(_sid);
    if (p == VoicePick.send || p == VoicePick.cancel) _state.focusPicture(_sid);
  }

  void _onHold() {
    if (!_hold.holding) _levels = List.filled(_bars, 0);
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
        if (_mouse || (!_hold.active && widget.session.composer.open)) return;
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
    _pointer = e.pointer;
    _mouse = true;
    _state.holdForPanel(widget.session);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    unawaited(_hold.start());
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final c = _rectOf(_cancelBox), ed = _rectOf(_editBox);
    _hold.choose(c == null || ed == null ? VoicePick.send : desktopPick(e.position, c, ed));
  }

  void _up(PointerEvent e) {
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
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomRight,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedOpacity(
                  opacity: active ? 0 : 1,
                  duration: reduced ? Duration.zero : _fade,
                  child: IgnorePointer(
                    ignoring: active,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [...widget.others, const SizedBox(width: 8)]),
                  ),
                ),
                Listener(
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerUp: _up,
                  onPointerCancel: _up,
                  child: RappButton.secondary(
                    key: const Key('voice-hold'),
                    label: '按住说话',
                    semanticLabel: '语音',
                    icon: _hold.holding ? Icons.mic : Icons.mic_none,
                    onPicture: true,
                    // A no-op keeps the enabled look; the Listener does the work.
                    onPressed: () {},
                  ),
                ),
              ],
            ),
            if (active || _hold.hint != null)
              Positioned(
                right: 0,
                bottom: 48 + 8,
                child: active ? _column(context, reduced) : voiceHint(_hold),
              ),
          ],
        );
      },
    );
  }

  Widget _column(BuildContext context, bool reduced) {
    final t = RappTokens.of(context);
    final pick = _hold.pick;
    final width = (widget.stageWidth - 32).clamp(0.0, 480.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduced ? 1 : 0, end: 1),
      duration: reduced ? Duration.zero : _rise,
      curve: Curves.easeOut,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child),
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
              _target(t, const Key('voice-edit'), _editBox, '编辑', 'Tab', pick == VoicePick.edit),
              const SizedBox(width: 8),
              _target(t, const Key('voice-cancel'), _cancelBox, '取消', 'Esc', pick == VoicePick.cancel),
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

  Widget _target(RappTokens t, Key key, GlobalKey box, String label, String keyName, bool on) => KeyedSubtree(
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
    final said = voice.text;
    final words = said.isEmpty ? '正在听…' : voiceTail(said, style, width - 32, MediaQuery.textScalerOf(context));
    return CustomPaint(
      key: const Key('voice-bubble'),
      painter: VoiceBubbleFrame(fill: fill, border: border, dashed: pick == VoicePick.edit, right: true, radius: t.r, tail: false),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(words, style: style),
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
    );
  }
}
