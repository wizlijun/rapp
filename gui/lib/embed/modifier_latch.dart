// The sticky modifiers of the app key row (iPad spec §8.3): a tap lights a modifier for the next key, a quick second
// tap locks it, a tap on a locked one turns it off. Only the state lives here; AppKeyRow sends what it means to A.
import 'package:flutter/foundation.dart';

enum LatchState { off, once, locked }

/// The modifiers' CGEventFlags bits, as A's key events carry them.
const latchCmd = 1048576;
const latchOpt = 524288;
const latchCtrl = 262144;
const latchShift = 131072;

/// A second tap sooner than this after the first locks the modifier.
const latchLockWithin = Duration(milliseconds: 350);

class ModifierLatch extends ChangeNotifier {
  ModifierLatch({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final _states = <int, LatchState>{};
  final _lastTap = <int, DateTime>{};
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  LatchState of(int bit) => _states[bit] ?? LatchState.off;

  /// The bits of every modifier that is on (once or locked).
  int get flags {
    var f = 0;
    for (final e in _states.entries) {
      if (e.value != LatchState.off) f |= e.key;
    }
    return f;
  }

  /// A tap on [bit]'s key. [sinceLast]: the time since its last tap; measured here when not given.
  void tap(int bit, {Duration? sinceLast}) {
    final now = _clock();
    final last = _lastTap[bit];
    _lastTap[bit] = now;
    final since = sinceLast ?? (last == null ? null : now.difference(last));
    _states[bit] = switch (of(bit)) {
      LatchState.off => LatchState.once,
      LatchState.once => since != null && since < latchLockWithin ? LatchState.locked : LatchState.off,
      LatchState.locked => LatchState.off,
    };
    notifyListeners();
  }

  /// A key went out with the modifiers: the once ones go off, the locked ones stay.
  void used() {
    final once = [for (final e in _states.entries) if (e.value == LatchState.once) e.key];
    if (once.isEmpty) return;
    for (final bit in once) {
      _states[bit] = LatchState.off;
    }
    notifyListeners();
  }

  /// Every modifier off, locked ones too: the row goes away, the session changes, the app goes to the background.
  /// Whoever sent a modifier's down sends its up on this notify.
  void releaseAll() {
    _lastTap.clear();
    if (_disposed || flags == 0) return;
    _states.clear();
    notifyListeners();
  }
}
