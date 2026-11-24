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
import 'stage_buttons.dart';
import 'voice_fix.dart';
import 'voice_input.dart';
import 'voice_ring.dart';

const linuxVoicePreparing = '首次使用正在下载本地语音模型（约 142MB），请稍后再试';
const linuxVoiceUnavailable = '本地语音不可用，请检查网络、麦克风和 libpulse，再重试';
const linuxVoiceLanguageHint = '语音在本机识别，语言跟随系统；录音不保存、不上传';
bool get _linux => defaultTargetPlatform == TargetPlatform.linux;

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

/// What [openVoiceSettings] runs by default; tests replace it to see the button's tap arrive.
@visibleForTesting
Future<ProcessResult> Function(String, List<String>) voiceSettingsRunner = Process.run;

/// Opens System Settings (macOS) at the pane [s] names, as `openSettingsPane` does. [run] is for tests.
Future<void> openVoiceSettings(
  VoiceSettings s, {
  Future<ProcessResult> Function(String, List<String>)? run,
}) async {
  run ??= voiceSettingsRunner;
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
  VoiceOrigin voice = const VoiceOrigin(),
}) {
  final t = text.trim();
  if (t.isEmpty) return voiceBlank;
  final c = session.composer;
  String keep(String hint) {
    unawaited(c.keep(t));
    if (voice.ai != null) c.pendingAi = voice.ai; // sent from the panel later, it is still the AI's text
    if (voice.ai == null && voice.heard != null) c.pendingHeard = voice.heard; // and still what was heard
    return hint;
  }

  if (state.isDetaching(session.sid) || state.sendBlocked(session.sid)) return keep(voiceBlocked);
  if (c.busy) return keep(voiceBusy);
  switch (c.submitText(t, voice: voice)) {
    case SubmitPieces(:final pieces):
      session.prepareInput();
      port.composerSend(session.sid, pieces);
      return null;
    case _:
      return keep(voiceBusy);
  }
}

/// How long each hint stays once it shows (plan Global Constraints; the preparing and unavailable ones as long
/// as a put-back).
Duration _life(String hint) => switch (hint) {
  voiceBlank => const Duration(milliseconds: 1500),
  voiceDenied => const Duration(seconds: 4),
  voiceLanguageHint || linuxVoiceLanguageHint => const Duration(seconds: 6),
  linuxVoicePreparing || linuxVoiceUnavailable => const Duration(seconds: 4),
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
    this.tidy,
    this.wouldTidy,
    this.onPress,
    this.prefetch,
    this.fix,
    this.log,
    this.pauseFor = const Duration(milliseconds: 800),
  });

  /// On-device fixing (spec D5): every word this hold shows or hands on goes through it — the bubble
  /// ([fixedText]), [prefetch], [wouldTidy], [tidy], [send], [edit] and a draft kept after a session switch.
  /// Null: the words as heard.
  final FixResult Function(String text)? fix;

  /// One line per release that was not a cancel (D14 first step, D20): native's timing, the fix's count and
  /// time, and the release to the hand-off. Counts and milliseconds only, never words.
  final void Function(String line)? log;

  /// 边说边整理 (user 2026-11-21): the words so far, for the tidy to start on unseen while they are still being
  /// said — after each [pauseFor] without new words while holding, and at once at a release (松手立刻发), before
  /// the stop is back. Null: drop it (a cancel, a release the tidy did not take). The tidy takes it at [tidy]
  /// when the final words are the same.
  final void Function(String? text)? prefetch;
  final Duration pauseFor;

  /// Offered each non-blank text a release gives (send or edit pick, the fixed words) and where the bubble stood
  /// ([bubbleAt]), with what was heard; true means it took the text (the AI tidy runs and ends the send or edit
  /// itself), and nothing else happens here.
  final bool Function(String text, VoicePick pick, Rect? at, VoiceHeard heard)? tidy;

  /// At the release, on the words so far as [fixedText] has them: true when [tidy] is likely to take them. The bubble then stays
  /// up as it is ([handingOver]) until the stop is back, so the tidy card takes its place without a gap.
  final bool Function(String text)? wouldTidy;

  /// Called at each press, before the recognizer starts (a tidy still running gives way to it).
  final VoidCallback? onPress;

  /// Called once per press when it is over: with the pick after a release has finished, with null when the start
  /// did not give `ok`, on a quick tap, or when [dispose] cuts a press short.
  final void Function(VoicePick? pick)? onEnd;

  /// True the first time a release has no other hint to show (on macOS a send only: an 编辑 hides it at once);
  /// [languageHintShown] then says it was shown.
  final bool Function()? languageHintDue;
  final void Function()? languageHintShown;

  final VoiceInput voice;

  /// The session's composer, read at each press: words that come back after this hold is gone (a session
  /// switch while the stop is out) still go to the draft they were said for.
  final ComposerModel Function() composer;

  /// Sends the text (the fixed words; [VoiceHeard] says what was heard); returns a hint to show, or null.
  final String? Function(String text, VoiceHeard heard) send;

  /// Puts the text (the fixed words) in the draft and opens the panel.
  final void Function(String text, VoiceHeard heard) edit;

  /// The overlay's root: the stage the ring is laid out in.
  final stageKey = GlobalKey();

  /// From an `ok` start until the release (or the 5 minute cap, an interruption, a pointer cancel).
  bool holding = false;
  VoicePick pick = VoicePick.send;
  String? hint;

  /// The hint offers 「去设置」.
  VoiceSettings settings = VoiceSettings.none;
  VoiceRing? ring;

  /// The voice button's own opacity, which the overlay drives while it morphs.
  final buttonOpacity = ValueNotifier<double>(1);

  /// The words bubble's global rect, set by the UI at the release, handed to [tidy].
  Rect? bubbleAt;

  /// From a release [wouldTidy] said yes to until the stop is back: the bubble stays as it is.
  bool get handingOver => _handingOver;
  bool _handingOver = false;

  /// The last release's text was taken by [tidy] (its card now stands where the bubble was).
  bool get handedOver => _handedOver;
  bool _handedOver = false;

  bool _pressed = false;
  bool _open = false; // a press whose onEnd has not been called
  bool _showing = false;
  bool _disposed = false;
  int? _pointer;
  Timer? _hintTimer;
  Timer? _pauseTimer;
  String _said = ''; // the fixed words a pause last saw
  ComposerModel? _pressedFor;
  String? _fixIn;
  FixResult? _fixOut;

  /// The words so far ([VoiceInput.text]) through [fix]; the words themselves without one. What the bubble shows.
  String get fixedText => _fixed(voice.text).text;

  // [fix] on [text], kept for the next ask of the same text (the bubble asks at each frame).
  FixResult _fixed(String text) {
    final f = fix;
    if (f == null) return FixResult(text, const []);
    if (text != _fixIn || _fixOut == null) {
      _fixOut = f(text);
      _fixIn = text;
    }
    return _fixOut!;
  }

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
    onPress?.call();
    _open = true;
    _pressedFor = composer();
    _fixIn = _fixOut = null; // the rules may have changed since the last hold (a lesson applies at once)
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
        _said = fixedText;
        if (prefetch != null) voice.addListener(_onWords);
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
        _setHint(_linux ? linuxVoicePreparing : voicePreparing);
        _end(null);
      case VoiceStart.unavailable:
        _pressed = false;
        _setHint(_linux ? linuxVoiceUnavailable : voiceUnavailable);
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

  // New words while holding: the prefetch waits for the next pause.
  void _onWords() {
    if (!holding) return;
    final said = fixedText;
    if (said == _said) return;
    _said = said;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(pauseFor, () {
      _pauseTimer = null;
      if (holding && _said.trim().isNotEmpty) prefetch?.call(_said);
    });
  }

  void _stopListening() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    voice.removeListener(_onWords);
  }

  Future<void> _release() async {
    if (!holding) return;
    final released = Stopwatch()..start();
    holding = false;
    _pressed = false;
    voice.onMaxLength = null;
    voice.onError = null;
    _stopListening();
    final which = pick;
    final said = fixedText;
    if (which == VoicePick.cancel) {
      prefetch?.call(null);
    } else if (said.trim().isNotEmpty) {
      prefetch?.call(said);
    }
    final draft = _pressedFor;
    _handedOver = false;
    _handingOver = which != VoicePick.cancel && tidy != null && (wouldTidy?.call(said) ?? false);
    notifyListeners();
    switch (which) {
      case VoicePick.cancel:
        await voice.cancel();
      case VoicePick.send || VoicePick.edit:
        final words = await voice.stop();
        // Run once more on the final words, timed for the log (the last partial's result is not reused).
        final fixing = Stopwatch()..start();
        final r = fix?.call(words) ?? FixResult(words, const []);
        fixing.stop();
        if (fix != null) {
          _fixIn = words;
          _fixOut = r;
        }
        final text = r.text;
        final heard = VoiceHeard(heard: words, fixed: text);
        // The words are handed on from here: the release to now is the log's `out`.
        final out = released.elapsedMilliseconds;
        if (_disposed) {
          // The session switched meanwhile: keep the words in its draft rather than lose them.
          prefetch?.call(null);
          if (draft != null) unawaited(draft.keep(text));
          _logRelease(r, fixing, out);
          return;
        }
        // Taken by the tidy: it sends or edits when it is done, and no language hint shows over its card.
        final taken = text.trim().isNotEmpty && (tidy?.call(text, which, bubbleAt, heard) ?? false);
        if (!taken) prefetch?.call(null);
        _handedOver = taken;
        if (_handingOver) {
          _handingOver = false;
          notifyListeners();
        }
        if (taken) {
        } else if (which == VoicePick.send) {
          _setHint(send(text, heard));
        } else if (text.trim().isEmpty) {
          _setHint(voiceBlank);
        } else {
          edit(text, heard);
        }
        _logRelease(r, fixing, out);
        // R14, narrowed on macOS: an 编辑 opens the panel, which takes the stage row in the same frame, so the
        // hint could never paint there; it stays due for the next send.
        if (!taken && hint == null && (which == VoicePick.send || _ios) && (languageHintDue?.call() ?? false)) {
          _setHint(_linux ? linuxVoiceLanguageHint : voiceLanguageHint, settings: _linux ? VoiceSettings.none : VoiceSettings.language);
          languageHintShown?.call();
        }
    }
    if (!_disposed) _end(which);
  }

  // [out]: the release to the hand-off (the call to [tidy], [send] or [edit], the draft, or 没听清), in ms.
  void _logRelease(FixResult r, Stopwatch fixing, int out) {
    final l = log;
    if (l == null) return;
    final t = voice.lastTiming;
    final fixMs = (fixing.elapsedMicroseconds / 1000).toStringAsFixed(2);
    l('voice: first ${t?.firstPartialMs ?? '-'}ms, final ${t?.finalMs ?? '-'}ms, '
        'fix ${r.changes.length} in ${fixMs}ms, out ${out}ms');
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
    _stopListening();
    if (holding || _pressed) prefetch?.call(null);
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

/// The square voice button ([stageButtonSize]) at the bottom of the stage stack. It feeds [hold] and fades out while the disc grows from it.
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
        child: RappButton.stage(
          key: const Key('voice-hold'),
          label: '语音',
          icon: Icons.mic_none,
          size: stageButtonSize,
          // A no-op keeps the enabled look; the Listener above does the work.
          onPressed: () {},
        ),
      ),
    );
  },
);

/// The small bubble after a release (spec §5.1 「松手后的提示」): 没听清, a put-back, a permission or a not-yet.
/// With [maxWidth] (the Mac's stage row) the text wraps to fit, so 「去设置」 always stays in view.
Widget voiceHint(VoiceHold hold, {double? maxWidth}) => Builder(
  builder: (context) {
    final t = RappTokens.of(context);
    // iOS only has a pane for the permission; the language one is a hint to read.
    final button = hold.settings == VoiceSettings.privacy || (hold.settings == VoiceSettings.language && !_ios);
    final text = Text(hold.hint ?? '', style: TextStyle(color: t.text));
    final box = DecoratedBox(
      key: const Key('voice-hint'),
      decoration: BoxDecoration(
        // The raise colour on the opaque float surface, as the stage buttons: no picture shows through.
        color: Color.alphaBlend(t.raise.first, t.float.first),
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(t.r),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, button ? 4 : 8, button ? 4 : 12, button ? 4 : 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (maxWidth != null) Flexible(child: text) else text,
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
    return maxWidth == null ? box : ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: box);
  },
);
