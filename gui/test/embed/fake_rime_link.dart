import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rapp_rime/rapp_rime.dart';

/// A [RimeLink] with no engine: tests push updates by hand and read back what the editor asked for.
class FakeRimeLink extends ChangeNotifier implements RimeLink {
  FakeRimeLink({
    this.enabled = true,
    this.builtin = true,
    this.status = const RimeStatus(),
    this.ascii = false,
    this.delayed = false,
  });

  /// [flush] returns at once and the commit comes on a later microtask, just before the answer, as over
  /// RappRime's channel. Otherwise the commit is pushed inside the call.
  final bool delayed;

  @override
  bool enabled;
  @override
  bool builtin;
  @override
  RimeStatus status;
  @override
  bool ascii;

  /// What [flush] answers. True also pushes the raw input as a commit, as the native side does.
  bool flushOk = true;

  /// While set, [flush] answers only once it completes (the engine's answer arriving late).
  Completer<void>? flushGate;

  final calls = <String>[];
  Object? owner;
  void Function(RimeUpdate)? _onUpdate;
  String _input = '';

  /// Delivers [u] to the current owner, synchronously like [RappRime].
  void push(RimeUpdate u) {
    _input = u.input;
    _onUpdate?.call(u);
  }

  /// Changes and tells the listeners, as [RappRime] does on configure / status / toggle.
  void set({bool? enabled, bool? builtin, RimeStatus? status}) {
    if (enabled != null) this.enabled = enabled;
    if (builtin != null) this.builtin = builtin;
    if (status != null) this.status = status;
    notifyListeners();
  }

  @override
  void attach(Object owner, void Function(RimeUpdate) onUpdate) {
    calls.add('attach');
    this.owner = owner;
    _onUpdate = onUpdate;
  }

  @override
  void detach(Object owner) {
    calls.add('detach');
    if (!identical(this.owner, owner)) return;
    this.owner = null;
    _onUpdate = null;
  }

  @override
  Future<void> setActive(Object owner, bool on) {
    calls.add('setActive($on)');
    return Future.value();
  }

  @override
  Future<void> select(int index) {
    calls.add('select($index)');
    return Future.value();
  }

  @override
  Future<void> page(bool next) {
    calls.add('page($next)');
    return Future.value();
  }

  @override
  Future<bool> flush() {
    calls.add('flush');
    bool answer() {
      if (flushOk) push(RimeUpdate(commit: _input));
      return flushOk;
    }

    final gate = flushGate;
    if (gate != null) return gate.future.then((_) => answer());
    return delayed ? Future.microtask(answer) : Future.value(answer());
  }

  /// As the native side: the engine's composition is gone, so a later flush commits nothing.
  @override
  Future<void> clear() {
    calls.add('clear');
    _input = '';
    return Future.value();
  }

  @override
  void toggleBuiltin() {
    calls.add('toggleBuiltin');
    if (builtin) clear();
    builtin = !builtin;
    notifyListeners();
  }
}
