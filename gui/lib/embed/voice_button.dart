// Hold to talk (iOS): the voice button, what a press, a slide and a release do, and where the words go
// (voice-input spec §5.1, §5.2). The drawing is in voice_overlay.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ios_channel.dart';
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'composer_model.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'voice_input.dart';
import 'voice_ring.dart';

const voiceBlank = '没听清';
const voiceBlocked = '连接已断开或正在移动，内容尚未发送';
const voiceBusy = '上一段还在发送，已放进输入板';
const voiceDenied = '需要麦克风和语音识别权限';
const voicePreparing = '正在准备语音识别，请稍后再试';
const voiceUnavailable = '这台设备不能识别语音';

/// Sends [text] the way the writing panel does (spec §5.2). Returns the hint to show, or null when it went.
/// A blocked or busy session keeps the text at the end of the draft instead; the panel stays as it is.
String? sendVoice({
  required MainState state,
  required RemoteSession session,
  required SessionPort port,
  required String text,
}) {
  final t = text.trim();
  if (t.isEmpty) return voiceBlank;
  final c = session.composer;
  if (state.isDetaching(session.sid) || state.sendBlocked(session.sid)) {
    unawaited(c.keep(t));
    return voiceBlocked;
  }
  if (c.busy) {
    unawaited(c.keep(t));
    return voiceBusy;
  }
  switch (c.submitText(t)) {
    case SubmitPieces(:final pieces):
      session.prepareInput();
      port.composerSend(session.sid, pieces);
      return null;
    case _:
      unawaited(c.keep(t));
      return voiceBusy;
  }
}

/// How long each hint stays (plan Global Constraints; the preparing and unavailable ones as long as a put-back).
Duration _life(String hint) => switch (hint) {
  voiceBlank => const Duration(milliseconds: 1500),
  voiceDenied => const Duration(seconds: 4),
  _ => const Duration(seconds: 2),
};

/// One hold on the voice button: from the press, through the slide over the disc and the bands, to the release.
/// Points are in the stage's coordinates (the box under [stageKey], which the overlay puts on its root).
class VoiceHold extends ChangeNotifier {
  VoiceHold({required this.voice, required this.send, required this.edit});

  final VoiceInput voice;

  /// Sends the text; returns a hint to show, or null.
  final String? Function(String text) send;

  /// Puts the text in the draft and opens the panel.
  final void Function(String text) edit;

  /// The overlay's root: the stage the ring is laid out in.
  final stageKey = GlobalKey();

  /// From an `ok` start until the release (or the 60 s cap, an interruption, a pointer cancel).
  bool holding = false;
  VoicePick pick = VoicePick.send;
  String? hint;

  /// The hint offers 「去设置」.
  bool settings = false;
  VoiceRing? ring;

  /// The voice button's own opacity, which the overlay drives while it morphs.
  final buttonOpacity = ValueNotifier<double>(1);

  bool _pressed = false;
  bool _showing = false;
  bool _disposed = false;
  int? _pointer;
  Timer? _hintTimer;

  /// The overlay is up or still animating.
  bool get showing => _showing;
  set showing(bool v) {
    if (_showing == v) return;
    _showing = v;
    notifyListeners();
  }

  /// Holding, or the disc still on its way back: the rest of the stack stays hidden.
  bool get active => holding || _showing;

  Future<void> down(Offset thumb, Size stage, bool right) async {
    if (_pressed || holding || voice.phase != VoicePhase.idle) return;
    _pressed = true;
    pick = VoicePick.send;
    ring = VoiceRing(stage: stage, thumb: thumb, right: right);
    _setHint(null);
    final r = await voice.start();
    if (_disposed) return;
    switch (r) {
      case VoiceStart.ok:
        // Let go while the start was on its way: the stop that came then already ended it.
        if (!_pressed) return;
        holding = true;
        voice.onMaxLength = _release;
        voice.onError = (_) => _interrupted();
        unawaited(HapticFeedback.mediumImpact());
        notifyListeners();
      case VoiceStart.asked:
        _pressed = false;
      case VoiceStart.denied:
        _pressed = false;
        _setHint(voiceDenied, settings: true);
      case VoiceStart.preparing:
        _pressed = false;
        _setHint(voicePreparing);
      case VoiceStart.unavailable:
        _pressed = false;
        _setHint(voiceUnavailable);
    }
  }

  void move(Offset p) {
    final r = ring;
    if (!holding || r == null) return;
    final n = r.pick(p);
    if (n == pick) return;
    pick = n;
    unawaited(HapticFeedback.selectionClick());
    notifyListeners();
  }

  void up() {
    if (holding) {
      _release();
    } else if (_pressed) {
      // A quick tap: the start is still pending; this stop makes it cancel the recogniser.
      _pressed = false;
      if (voice.phase == VoicePhase.starting) unawaited(voice.stop());
    }
  }

  /// The system took the pointer (a call, a pull-down): as a release on 取消.
  void cancel() {
    if (holding) {
      pick = VoicePick.cancel;
      _release();
    } else if (_pressed) {
      _pressed = false;
      if (voice.phase == VoicePhase.starting) unawaited(voice.cancel());
    }
  }

  // The recogniser stopped by itself (interrupted): nothing to send.
  void _interrupted() {
    if (!holding) return;
    pick = VoicePick.cancel;
    _release();
  }

  Future<void> _release() async {
    if (!holding) return;
    holding = false;
    _pressed = false;
    voice.onMaxLength = null;
    voice.onError = null;
    final which = pick;
    notifyListeners();
    switch (which) {
      case VoicePick.cancel:
        await voice.cancel();
      case VoicePick.send:
        final text = await voice.stop();
        if (_disposed) return;
        _setHint(send(text));
      case VoicePick.edit:
        final text = await voice.stop();
        if (_disposed) return;
        if (text.trim().isEmpty) {
          _setHint(voiceBlank);
        } else {
          edit(text);
        }
    }
  }

  void _setHint(String? h, {bool settings = false}) {
    _hintTimer?.cancel();
    if (h == null && hint == null) return;
    hint = h;
    this.settings = h != null && settings;
    if (h != null) _hintTimer = Timer(_life(h), () => _setHint(null));
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _hintTimer?.cancel();
    if (holding || _pressed) {
      voice.onMaxLength = null;
      voice.onError = null;
      unawaited(voice.cancel());
    }
    buttonOpacity.dispose();
    super.dispose();
  }
}

/// The 64 voice button at the bottom of the stage stack. It feeds [hold] and fades out while the disc grows from it.
Widget voiceButton(VoiceHold hold) => Builder(
  builder: (context) {
    RenderBox? stage() => hold.stageKey.currentContext?.findRenderObject() as RenderBox?;
    return Listener(
      onPointerDown: (e) {
        if (hold._pointer != null) return;
        final s = stage();
        final me = context.findRenderObject() as RenderBox?;
        if (s == null || me == null || !s.hasSize) return;
        hold._pointer = e.pointer;
        final thumb = s.globalToLocal(me.localToGlobal(me.size.center(Offset.zero)));
        unawaited(hold.down(thumb, s.size, thumb.dx > s.size.width / 2));
      },
      onPointerMove: (e) {
        final s = stage();
        if (e.pointer == hold._pointer && s != null) hold.move(s.globalToLocal(e.position));
      },
      onPointerUp: (e) {
        if (e.pointer != hold._pointer) return;
        hold._pointer = null;
        hold.up();
      },
      onPointerCancel: (e) {
        if (e.pointer != hold._pointer) return;
        hold._pointer = null;
        hold.cancel();
      },
      child: ValueListenableBuilder<double>(
        valueListenable: hold.buttonOpacity,
        builder: (context, o, child) => Opacity(opacity: o, child: child),
        child: RappButton.round(
          key: const Key('voice-hold'),
          label: '语音',
          icon: Icons.mic_none,
          size: 64,
          // A no-op keeps the enabled look; the Listener above does the work.
          onPressed: () {},
        ),
      ),
    );
  },
);

/// The small bubble after a release (spec §5.1 「松手后的提示」): 没听清, a put-back, a permission or a not-yet.
Widget voiceHint(VoiceHold hold) => Builder(
  builder: (context) {
    final t = RappTokens.of(context);
    return DecoratedBox(
      key: const Key('voice-hint'),
      decoration: BoxDecoration(
        // The raise colour on the opaque float surface, as the round buttons: no picture shows through.
        color: Color.alphaBlend(t.raise.first, t.float.first),
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(t.r),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, hold.settings ? 4 : 8, hold.settings ? 4 : 12, hold.settings ? 4 : 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(hold.hint ?? '', style: TextStyle(color: t.text)),
            if (hold.settings) ...[
              const SizedBox(width: 8),
              RappButton.secondary(
                key: const Key('voice-settings'),
                label: '去设置',
                onPicture: true,
                onPressed: () => unawaited(iosChannel.openSettings()),
              ),
            ],
          ],
        ),
      ),
    );
  },
);
