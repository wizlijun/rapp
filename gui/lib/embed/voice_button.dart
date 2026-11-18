// Hold to talk (iOS): the voice button, what a press, a slide and a release do, and where the words go
// (voice-input spec §5.1, §5.2). The drawing is in voice_overlay.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
const voiceUnavailable = '这种系统语言暂不支持语音识别，可以在系统设置里换一种';
const voiceLanguageHint = '识别语言跟随系统。要换语言：系统设置 → 通用 → 语言与地区';

/// What the hint's 「去设置」 opens (and whether it shows at all).
enum VoiceSettings { none, privacy, language }

const _microphoneUrl = 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone';
const _languageUrl = 'x-apple.systempreferences:com.apple.Localization-Settings.extension';

/// Opens System Settings (macOS) at the pane [s] names, as `openSettingsPane` does. [run] is for tests.
Future<void> openVoiceSettings(
  VoiceSettings s, {
  Future<ProcessResult> Function(String, List<String>) run = Process.run,
}) async {
  switch (s) {
    case VoiceSettings.none:
      return;
    case VoiceSettings.privacy:
      await run('open', [_microphoneUrl]);
    case VoiceSettings.language:
      await run('open', [_languageUrl]);
  }
}

bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;

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

/// How long each hint stays once it shows (plan Global Constraints; the preparing and unavailable ones as long
/// as a put-back).
Duration _life(String hint) => switch (hint) {
  voiceBlank => const Duration(milliseconds: 1500),
  voiceDenied => const Duration(seconds: 4),
  voiceLanguageHint => const Duration(seconds: 6),
  _ => const Duration(seconds: 2),
};

/// The stack's fade back in after a hold (stage_buttons.dart): a hint set then is fully there this much later.
const _stackFadeIn = Duration(milliseconds: 120);

/// One hold on the voice button: from the press, through the slide over the disc and the bands, to the release.
/// Points are in the stage's coordinates (the box under [stageKey], which the overlay puts on its root).
class VoiceHold extends ChangeNotifier {
  VoiceHold({
    required this.voice,
    required this.send,
    required this.edit,
    required this.composer,
    this.onEnd,
    this.languageHintDue,
    this.languageHintShown,
  });

  /// Called once per press when it is over: with the pick after a release has finished, with null when the start
  /// did not give `ok`, on a quick tap, or when [dispose] cuts a press short.
  final void Function(VoicePick? pick)? onEnd;

  /// True the first time a release has no other hint to show; [languageHintShown] then says it was shown.
  final bool Function()? languageHintDue;
  final void Function()? languageHintShown;

  final VoiceInput voice;

  /// The session's composer, read at each press: words that come back after this hold is gone (a session
  /// switch while the stop is out) still go to the draft they were said for.
  final ComposerModel Function() composer;

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
  VoiceSettings settings = VoiceSettings.none;
  VoiceRing? ring;

  /// The voice button's own opacity, which the overlay drives while it morphs.
  final buttonOpacity = ValueNotifier<double>(1);

  bool _pressed = false;
  bool _open = false; // a press whose onEnd has not been called
  bool _showing = false;
  bool _disposed = false;
  int? _pointer;
  Timer? _hintTimer;
  ComposerModel? _pressedFor;

  /// The overlay is up or still animating.
  bool get showing => _showing;
  set showing(bool v) {
    if (_showing == v) return;
    _showing = v;
    // A hint set during the release starts its time now, as the stack fades back in with it.
    final h = hint;
    if (!active && h != null && _hintTimer == null) _hintTimer = Timer(_life(h) + _stackFadeIn, _clearHint);
    notifyListeners();
  }

  /// Holding, or the disc still on its way back: the rest of the stack stays hidden.
  bool get active => holding || _showing;

  Future<void> down(Offset thumb, Size stage, bool right) async {
    if (_pressed || holding || voice.phase != VoicePhase.idle) return;
    ring = VoiceRing(stage: stage, thumb: thumb, right: right);
    await start();
  }

  /// The press without a ring (the Mac button and hotkey).
  Future<void> start() async {
    if (_pressed || holding || voice.phase != VoicePhase.idle) return;
    _pressed = true;
    _open = true;
    _pressedFor = composer();
    pick = VoicePick.send;
    _setHint(null);
    final r = await voice.start();
    if (_disposed) return;
    // Let go while the start was on its way: that release already ended it, and there is nothing to show.
    if (!_pressed) {
      _end(null);
      return;
    }
    switch (r) {
      case VoiceStart.ok:
        holding = true;
        voice.onMaxLength = _release;
        voice.onError = _interrupted;
        if (_ios) unawaited(HapticFeedback.mediumImpact());
        notifyListeners();
      case VoiceStart.asked:
        _pressed = false;
        _end(null);
      case VoiceStart.cancelled:
        _pressed = false;
        _end(null);
      case VoiceStart.denied:
        _pressed = false;
        _setHint(voiceDenied, settings: VoiceSettings.privacy);
        _end(null);
      case VoiceStart.preparing:
        _pressed = false;
        _setHint(voicePreparing);
        _end(null);
      case VoiceStart.unavailable:
        _pressed = false;
        _setHint(voiceUnavailable);
        _end(null);
    }
  }

  void _end(VoicePick? p) {
    if (!_open) return;
    _open = false;
    onEnd?.call(p);
  }

  /// While holding, moves the pick (a key or the mouse on a band). No haptics.
  void choose(VoicePick p) {
    if (!holding || p == pick) return;
    pick = p;
    notifyListeners();
  }

  /// Ends the press on [p]: while holding, a release on it; before the hold, 取消 cancels and the rest is a release.
  void finish(VoicePick p) {
    if (holding) {
      pick = p;
      unawaited(_release());
    } else if (_pressed) {
      if (p == VoicePick.cancel) {
        cancel();
      } else {
        up();
      }
    }
  }

  void move(Offset p) {
    final r = ring;
    if (!holding || r == null) return;
    final n = r.pick(p);
    if (n == pick) return;
    pick = n;
    if (_ios) unawaited(HapticFeedback.selectionClick());
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

  // The recogniser stopped by itself: nothing to send. A call or leaving the app says nothing; a recogniser
  // that failed lost the words, so 没听清.
  void _interrupted(String code) {
    if (!holding) return;
    pick = VoicePick.cancel;
    unawaited(_release());
    if (code != 'interrupted') _setHint(voiceBlank);
  }

  Future<void> _release() async {
    if (!holding) return;
    holding = false;
    _pressed = false;
    voice.onMaxLength = null;
    voice.onError = null;
    final which = pick;
    final draft = _pressedFor;
    notifyListeners();
    switch (which) {
      case VoicePick.cancel:
        await voice.cancel();
      case VoicePick.send || VoicePick.edit:
        final text = await voice.stop();
        if (_disposed) {
          // The session switched meanwhile: keep the words in its draft rather than lose them.
          if (draft != null) unawaited(draft.keep(text));
          return;
        }
        if (which == VoicePick.send) {
          _setHint(send(text));
        } else if (text.trim().isEmpty) {
          _setHint(voiceBlank);
        } else {
          edit(text);
        }
        if (hint == null && (languageHintDue?.call() ?? false)) {
          _setHint(voiceLanguageHint, settings: VoiceSettings.language);
          languageHintShown?.call();
        }
    }
    if (!_disposed) _end(which);
  }

  /// While the stack is hidden (a hold, its release) the hint waits; its time starts when it shows.
  void _setHint(String? h, {VoiceSettings settings = VoiceSettings.none}) {
    _hintTimer?.cancel();
    _hintTimer = null;
    if (h == null && hint == null) return;
    hint = h;
    this.settings = h != null ? settings : VoiceSettings.none;
    if (h != null && !active) _hintTimer = Timer(_life(h), _clearHint);
    notifyListeners();
  }

  void _clearHint() => _setHint(null);

  @override
  void dispose() {
    _disposed = true;
    _hintTimer?.cancel();
    if (holding || _pressed) {
      voice.onMaxLength = null;
      voice.onError = null;
      unawaited(voice.cancel());
    }
    _end(null);
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
    // iOS only has a pane for the permission; the language one is a hint to read.
    final button = hold.settings == VoiceSettings.privacy || (hold.settings == VoiceSettings.language && !_ios);
    return DecoratedBox(
      key: const Key('voice-hint'),
      decoration: BoxDecoration(
        // The raise colour on the opaque float surface, as the round buttons: no picture shows through.
        color: Color.alphaBlend(t.raise.first, t.float.first),
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(t.r),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, button ? 4 : 8, button ? 4 : 12, button ? 4 : 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(hold.hint ?? '', style: TextStyle(color: t.text)),
            if (button) ...[
              const SizedBox(width: 8),
              RappButton.secondary(
                key: const Key('voice-settings'),
                label: '去设置',
                onPicture: true,
                onPressed: () => unawaited(_ios ? iosChannel.openSettings() : openVoiceSettings(hold.settings)),
              ),
            ],
          ],
        ),
      ),
    );
  },
);
