// The Dart side of the `rapp/speech` channel (gui/ios/Runner, a later task): hold-to-talk speech recognition.
// Dart calls `start` / `stop` / `cancel`; native answers with `partial` / `final` {text} and `error` {code} calls.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum VoiceStart { ok, asked, denied, unavailable, preparing }

enum VoicePhase { idle, starting, listening, finishing }

class VoiceInput extends ChangeNotifier {
  VoiceInput({
    MethodChannel? channel,
    this.finalWait = const Duration(seconds: 1),
    this.maxLength = const Duration(seconds: 60),
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

  /// Native `error` {code}; the phase has already gone idle.
  void Function(String code)? onError;

  VoicePhase _phase = VoicePhase.idle;
  String _text = '';
  Timer? _maxTimer, _finalTimer;
  Completer<String>? _finalDone;
  // A stop or cancel that arrived while `start` was pending; its stop() future (if any) waits here.
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
    _set(phase: VoicePhase.starting, text: '');
    VoiceStart r;
    try {
      r = switch (await _channel.invokeMethod<String>('start')) {
        'ok' => VoiceStart.ok,
        'asked' => VoiceStart.asked,
        'denied' => VoiceStart.denied,
        'preparing' => VoiceStart.preparing,
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
      if (r == VoiceStart.ok) await _nativeCancel();
      _set(phase: VoicePhase.idle, text: '');
      waiting?.complete('');
      return r;
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
      _aborted = true;
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
    if (_phase == VoicePhase.starting) {
      _aborted = true;
      return;
    }
    if (_phase == VoicePhase.idle) return;
    _maxTimer?.cancel();
    _finish('');
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

  /// Native to Dart: `partial` / `final` {text}, `error` {code}. Ignored while idle.
  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    if (_phase == VoicePhase.idle) return null;
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
