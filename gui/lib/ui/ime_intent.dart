// What the user means to type decides the local input method: the writing panel (写作版) is Chinese, the
// picture is English (spec: IME intent). Only the edges count: the first panel to take the caret switches to
// Chinese, the last one to lose it switches back, and a move from one panel to another in the same turn
// switches nothing. A leave waits [ImeIntent.defaultLeaveGrace] first: a panel handing the caret to another one
// (a reconnect, a stage switch) takes longer than a turn, and the input method is left alone if it arrives. While
// the app is not in front nothing is switched at all (the focused window, and its input method, are another
// app's); coming back reconciles once. Every call to the input method is queued, bounded and never throws.
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
      this.callTimeout = const Duration(milliseconds: 300),
      this.leaveGrace = defaultLeaveGrace});

  /// How long the last panel losing the caret waits before switching to English: another panel taking it by
  /// then means the caret only moved, and the input method stays Chinese.
  static const defaultLeaveGrace = Duration(milliseconds: 200);

  final LocalIme ime;
  final Duration callTimeout, leaveGrace;
  final bool Function() enabled, secure;
  final String? Function() lastId;
  final void Function(String id) saveId;

  /// The sessions whose writing panel has the caret.
  final Set<Object> _inside = {};

  /// What the last settle saw: some writing panel had the caret.
  bool _wasInside = false;

  /// The settle waiting for the end of this turn; completes when it ran.
  Completer<void>? _pending;
  Timer? _pendingTimer;

  /// A leave waiting out [leaveGrace].
  Timer? _leave;

  /// The app is in front (lifecycle resumed); otherwise nothing is switched.
  bool _front = true;

  /// The app came back: the next settle reconciles instead of looking for an edge.
  bool _resync = false;

  /// The tail of the queued calls (it never fails), and how many of them have not ended.
  Future<void>? _chain;
  int _queued = 0;

  /// The writing panel of session [sid] took ([on]) or lost the caret.
  void focus(Object sid, bool on) {
    final changed = on ? _inside.add(sid) : _inside.remove(sid);
    // Not in front: only tracked; coming back reconciles.
    if (changed && _front) _schedule();
  }

  /// The app went inactive, hidden or paused: the focus moves now belong to another window's input method.
  void appInactive() {
    _front = false;
    _leave?.cancel();
    _leave = null;
  }

  /// The app came back: once, at the end of this turn (so a caret restored just before or after coalesces),
  /// the caret in a panel switches to Chinese, as another app may have changed it meanwhile; outside, nothing.
  void appResumed() {
    _front = true;
    _resync = true;
    _schedule();
  }

  /// Nothing more is switched; a settle being waited for completes.
  void dispose() {
    _front = false;
    _leave?.cancel();
    _leave = null;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    final p = _pending;
    _pending = null;
    p?.complete();
  }

  /// Done when the queued settle and every call queued so far have ended (each call at most [callTimeout]).
  /// A leave still waiting out [leaveGrace] is not waited for.
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

  void _schedule() {
    if (_pending != null) return;
    final c = _pending = Completer<void>();
    _pendingTimer = Timer(Duration.zero, () {
      _pending = null;
      _pendingTimer = null;
      _settle();
      c.complete();
    });
  }

  void _settle() {
    if (!_front) return;
    final inside = _inside.isNotEmpty;
    if (_resync) {
      _resync = false;
      _leave?.cancel();
      _leave = null;
      _wasInside = inside;
      if (inside && _on) _queue(_toChinese);
      return;
    }
    if (inside) {
      if (_leave != null) {
        // The caret only moved to another panel: still Chinese.
        _leave!.cancel();
        _leave = null;
        return;
      }
      if (_wasInside) return;
      _wasInside = true;
      if (_on) _queue(_toChinese);
    } else {
      if (!_wasInside || _leave != null) return;
      _leave = Timer(leaveGrace, () {
        _leave = null;
        if (!_front || _inside.isNotEmpty) return;
        _wasInside = false;
        if (_on) _queue(_toEnglish);
      });
    }
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
