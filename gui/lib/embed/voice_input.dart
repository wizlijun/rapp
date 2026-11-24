// The Dart side of the `rapp/speech` channel (gui/ios/Runner, a later task): hold-to-talk speech recognition.
// Dart calls `start` ({hotwords} when there are any) / `stop` / `cancel`; native answers with `partial` / `final` {text} and `error` {code} calls,
// and `timing` {first_partial_ms, final_ms} just before `final`.
// `start` replies `cancelled` when a cancel or an interruption overtook it natively.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// [cancelled]: a stop or cancel came while starting (or native was overtaken); nothing to show.
enum VoiceStart { ok, asked, denied, unavailable, preparing, cancelled }

enum VoicePhase { idle, starting, listening, finishing }

/// How long one recording took natively; null where it did not happen (no partial, or no stop before the final).
class VoiceTiming {
  const VoiceTiming({this.firstPartialMs, this.finalMs});

  /// Native `start` called to the first `partial`.
  final int? firstPartialMs;

  /// Native `stop` to the `final`.
  final int? finalMs;
}

class VoiceInput extends ChangeNotifier {
  VoiceInput({
    MethodChannel? channel,
    this.finalWait = const Duration(seconds: 1),
    this.maxLength = const Duration(minutes: 5),
  }) : _channel = channel ?? const MethodChannel('rapp/speech') {
    _channel.setMethodCallHandler(handle);
  }

  final MethodChannel _channel;

  /// How long `stop` waits for the final transcript before settling for the last partial.
  final Duration finalWait;

  /// Recording ends by itself this long after it began (`onMaxLength` fires once).
  final Duration maxLength;

  /// Fired once when [maxLength] passes while listening.
  VoidCallback? onMaxLength;

  /// Words the recogniser should expect (Apple's contextual strings), asked for at each [start].
  List<String> Function()? hotwords;

  /// Native `error` {code}; the phase has already gone idle.
  void Function(String code)? onError;

  VoicePhase _phase = VoicePhase.idle;
  String _text = '';
  Timer? _maxTimer, _finalTimer;
  Completer<String>? _finalDone;
  // A stop or cancel that arrived while `start` was pending (native cancel already sent); its stop() future
  // (if any) waits here.
  bool _aborted = false;
  Completer<String>? _abortedStop;
  // A native `final` that arrived while still listening (the recogniser ended early); the next `stop` returns it.
  bool _earlyFinal = false;
  final ValueNotifier<double> _level = ValueNotifier(0);

  /// Microphone level, 0..1; 0 whenever the phase is not `listening`.
  ValueListenable<double> get level => _level;

  VoicePhase get phase => _phase;

  /// The latest partial (or final) transcript.
  String get text => _text;

  VoiceTiming? _lastTiming;

  /// The timing native reported for the current or last recording; cleared at each [start].
  VoiceTiming? get lastTiming => _lastTiming;

  void _set({VoicePhase? phase, String? text}) {
    _phase = phase ?? _phase;
    _text = text ?? _text;
    if (_phase != VoicePhase.listening) _level.value = 0;
    notifyListeners();
  }

  Future<VoiceStart> start() async {
    if (_phase != VoicePhase.idle) return VoiceStart.unavailable;
    _aborted = false;
    _earlyFinal = false;
    _lastTiming = null;
    _set(phase: VoicePhase.starting, text: '');
    VoiceStart r;
    try {
      final words = hotwords?.call() ?? const <String>[];
      r = switch (await _channel.invokeMethod<String>('start', words.isEmpty ? null : {'hotwords': words})) {
        'ok' => VoiceStart.ok,
        'asked' => VoiceStart.asked,
        'denied' => VoiceStart.denied,
        'preparing' => VoiceStart.preparing,
        'cancelled' => VoiceStart.cancelled,
        _ => VoiceStart.unavailable,
      };
    } on PlatformException {
      r = VoiceStart.unavailable;
    } on MissingPluginException {
      r = VoiceStart.unavailable;
    }
    final aborted = _aborted;
    final waiting = _abortedStop;
    _aborted = false;
    _abortedStop = null;
    if (aborted) {
      // The native cancel went when the abort came, after this start on the same channel: an `ok` start
      // was ended by it, a pending one was overtaken. Silent either way.
      _set(phase: VoicePhase.idle, text: '');
      waiting?.complete('');
      return VoiceStart.cancelled;
    }
    if (r != VoiceStart.ok) {
      _set(phase: VoicePhase.idle);
      return r;
    }
    _maxTimer = Timer(maxLength, () => onMaxLength?.call());
    _set(phase: VoicePhase.listening);
    return r;
  }

  Future<String> stop() async {
    if (_phase == VoicePhase.starting) {
      unawaited(_abort());
      return (_abortedStop ??= Completer<String>()).future;
    }
    if (_phase != VoicePhase.listening) return _phase == VoicePhase.finishing ? _finalDone!.future : '';
    _maxTimer?.cancel();
    if (_earlyFinal) {
      _earlyFinal = false;
      final text = _text;
      _finish(text);
      return text;
    }
    final done = _finalDone = Completer<String>();
    _set(phase: VoicePhase.finishing);
    _finalTimer = Timer(finalWait, () => _finish(_text));
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      _finish(_text);
    } on MissingPluginException {
      _finish(_text);
    }
    return done.future;
  }

  Future<void> cancel() async {
    if (_phase == VoicePhase.starting) return _abort();
    if (_phase == VoicePhase.idle) return;
    _maxTimer?.cancel();
    _finish('');
    await _nativeCancel();
  }

  // Tells native at once, so a start still setting up (iOS 26) never turns the audio session on.
  Future<void> _abort() async {
    if (_aborted) return;
    _aborted = true;
    await _nativeCancel();
  }

  Future<void> _nativeCancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // Nothing more to stop.
    } on MissingPluginException {
      // Same.
    }
  }

  /// Back to idle with [text]; settles a pending `stop`.
  void _finish(String text) {
    _maxTimer?.cancel();
    _finalTimer?.cancel();
    final done = _finalDone;
    _finalDone = null;
    _set(phase: VoicePhase.idle, text: text);
    if (done != null && !done.isCompleted) done.complete(text);
  }

  /// Native to Dart: `partial` / `final` {text}, `level` {value}, `error` {code}, `timing` {first_partial_ms, final_ms}. Ignored while idle, and while
  /// starting: native sends nothing for a run before its `ok`, so anything then is a late one from the last run.
  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    if (_phase == VoicePhase.idle || _phase == VoicePhase.starting) return null;
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'partial':
        _set(text: '${args['text'] ?? ''}');
      case 'final':
        if (_phase == VoicePhase.finishing) {
          _finish('${args['text'] ?? ''}');
        } else {
          _earlyFinal = true;
          _set(text: '${args['text'] ?? ''}');
        }
      case 'level':
        if (_phase == VoicePhase.listening) {
          _level.value = ((args['value'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
        }
      case 'timing':
        _lastTiming = VoiceTiming(
          firstPartialMs: (args['first_partial_ms'] as num?)?.toInt(),
          finalMs: (args['final_ms'] as num?)?.toInt(),
        );
      case 'error':
        _finish('');
        onError?.call('${args['code'] ?? ''}');
    }
    return null;
  }

  @override
  void dispose() {
    _maxTimer?.cancel();
    _finalTimer?.cancel();
    _channel.setMethodCallHandler(null);
    _level.dispose();
    super.dispose();
  }
}
