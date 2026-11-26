// What the user means to type decides the local input method: the writing panel (写作版) is Chinese, the
// picture is English (spec: IME intent). Only the edges count: the first panel to take the caret switches to
// Chinese, the last one to lose it switches back, and a move from one panel to another in the same turn
// switches nothing. Every call to the input method is queued, bounded and never throws.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../embed/local_ime.dart';

class ImeIntent {
  /// [enabled]: the 全局设置 switch. [secure]: a password field holds the keyboard; nothing is switched then.
  /// [lastId]/[saveId]: the Chinese input method last left, asked for on the next switch.
  ImeIntent(this.ime,
      {required this.enabled,
      required this.secure,
      required this.lastId,
      required this.saveId,
      this.callTimeout = const Duration(milliseconds: 300)});

  final LocalIme ime;
  final Duration callTimeout;
  final bool Function() enabled, secure;
  final String? Function() lastId;
  final void Function(String id) saveId;

  /// The sessions whose writing panel has the caret.
  final Set<Object> _inside = {};

  /// What the last settle saw: some writing panel had the caret.
  bool _wasInside = false;

  /// The settle waiting for the end of this turn; completes when it ran.
  Completer<void>? _pending;

  /// The tail of the queued calls (it never fails), and how many of them have not ended.
  Future<void>? _chain;
  int _queued = 0;

  /// The writing panel of session [sid] took ([on]) or lost the caret.
  void focus(Object sid, bool on) {
    final changed = on ? _inside.add(sid) : _inside.remove(sid);
    if (!changed || _pending != null) return;
    final c = _pending = Completer<void>();
    Timer(Duration.zero, () {
      _pending = null;
      _settle();
      c.complete();
    });
  }

  /// The app came back: another app may have changed the input method meanwhile.
  void appResumed() {
    if (_inside.isEmpty || !_on) return;
    _queue(_toChinese);
  }

  /// Done when the queued settle and every call queued so far have ended (each call at most [callTimeout]).
  Future<void> get settled async {
    for (;;) {
      final p = _pending;
      if (p != null) await p.future;
      final tail = _chain;
      if (_queued == 0 || tail == null) {
        if (_pending == null) return;
        continue;
      }
      await tail;
    }
  }

  bool get _on => enabled() && !secure();

  void _settle() {
    final inside = _inside.isNotEmpty;
    if (inside == _wasInside) return;
    _wasInside = inside;
    if (!_on) return;
    _queue(inside ? _toChinese : _toEnglish);
  }

  Future<void> _toChinese() async {
    // Read here, not when queued: a leave queued just before may have saved a newer one.
    await _call('toChinese', () => ime.toChinese(lastId()));
  }

  Future<void> _toEnglish() async {
    final now = await _call('current', ime.current);
    if (now != null && !now.ascii) {
      try {
        saveId(now.id);
      } catch (e) {
        debugPrint('ime: save ${now.id}: $e');
      }
    }
    await _call('toEnglish', ime.toEnglish);
  }

  void _queue(Future<void> Function() job) {
    _queued++;
    Future<void> run() async {
      try {
        await job();
      } finally {
        _queued--;
      }
    }

    // Idle: a fresh chain, so nothing waits on a future of an older zone.
    final tail = _chain;
    _chain = _queued == 1 || tail == null ? run() : tail.then((_) => run());
  }

  /// [f] bounded by [callTimeout]; a failure or a timeout is logged and gives null.
  Future<T?> _call<T>(String what, Future<T> Function() f) async {
    try {
      return await f().timeout(callTimeout);
    } catch (e) {
      debugPrint('ime: $what: $e');
      return null;
    }
  }
}
