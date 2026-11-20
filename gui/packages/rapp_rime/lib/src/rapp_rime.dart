import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// What the editor uses of the input method; tests substitute a fake.
abstract class RimeLink implements Listenable {
  bool get enabled;
  bool get builtin; // 「内」 true, 「系」 false
  RimeStatus get status;
  bool get ascii;

  /// This editor becomes the one receiving updates (the previous one is replaced). A composition the
  /// previous one still had is committed to it first.
  void attach(Object owner, void Function(RimeUpdate) onUpdate);
  void detach(Object owner);
  Future<void> setActive(Object owner, bool on);
  Future<void> select(int index);
  Future<void> page(bool next);

  /// False when the channel fails (no plugin, engine not loaded).
  Future<bool> flush();
  Future<void> clear();
  void toggleBuiltin();
}

class RappRime extends ChangeNotifier implements RimeLink {
  RappRime(this._channel) {
    _channel.setMethodCallHandler(_handle);
  }
  static final RappRime instance = RappRime(const MethodChannel('rapp/rime'));

  final MethodChannel _channel;
  bool _enabled = false, _builtin = true, _ascii = false;
  void Function(bool builtin)? _onBuiltin;
  RimeStatus _status = const RimeStatus();
  Object? _owner;
  void Function(RimeUpdate)? _onUpdate;
  // Where updates go: the owner's callback, or during a handover the previous owner's.
  void Function(RimeUpdate)? _route;
  bool _handingOver = false;
  bool _on = false; // what the current owner asked for
  String? _sentConfigure; // last configure sent, to skip duplicates

  @override
  bool get enabled => _enabled;
  @override
  bool get builtin => _builtin;
  @override
  RimeStatus get status => _status;
  @override
  bool get ascii => _ascii;

  bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    if (!_ios) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<dynamic> _handle(MethodCall call) {
    // Synchronous on purpose: replayed keys mix these with text the native side
    // inserts directly, so nothing may be awaited before delivery.
    switch (call.method) {
      case 'status':
        _status = RimeStatus.parse(call.arguments);
        notifyListeners();
      case 'update':
        final update = RimeUpdate.parse(call.arguments);
        if (update != null) {
          final changed = _ascii != update.ascii;
          _ascii = update.ascii;
          _route?.call(update);
          if (changed) notifyListeners();
        }
    }
    return SynchronousFuture<dynamic>(null);
  }

  /// What the app wants, sent again whenever any of it may have changed (repeats cost nothing). [enabled]: the
  /// master switch. [builtin]: 「内」 (true) or 「系」 for the panel the user is typing in now. [onBuiltin]: the user
  /// tapped 「内」/「系」 ([toggleBuiltin]); the app keeps the choice and passes it back as [builtin].
  void configure({
    required bool enabled,
    required bool builtin,
    required RimeDictionary dictionary,
    required void Function(bool builtin) onBuiltin,
  }) {
    final stateChanged = enabled != _enabled || builtin != _builtin;
    // 「内」 to 「系」 from here is the app switching (another session's choice), not the user: what was being
    // composed is committed as typed, like a blur. The switch going off drops it (the engine stops).
    final commit = _owner != null && _on && _enabled && enabled && _builtin && !builtin;
    _enabled = enabled;
    _builtin = builtin;
    _onBuiltin = onBuiltin;
    if (!_ios) return;
    final key = '$enabled/${dictionary.name}';
    if (key != _sentConfigure) {
      _sentConfigure = key;
      _invoke<void>('configure', {'enabled': enabled, 'dictionary': dictionary.name});
    }
    if (commit) flush();
    if (stateChanged && _owner != null) _sendActive();
    if (stateChanged) notifyListeners();
  }

  Future<void> redeploy() => _invoke<void>('redeploy');

  Future<({String path, bool ready})> userFolder() async {
    final result = await _invoke<Map<Object?, Object?>>('userFolder');
    final path = result?['path'], ready = result?['ready'];
    if (path is! String) return (path: '', ready: false);
    return (path: path, ready: ready == true);
  }

  @override
  void attach(Object owner, void Function(RimeUpdate) onUpdate) {
    final previous = _owner;
    _owner = owner;
    _onUpdate = onUpdate;
    if (previous == null || identical(previous, owner)) {
      if (!_handingOver) _route = onUpdate;
      return;
    }
    _on = false;
    // A new panel attaches before the old one lets go: the old one's composition is committed to the old
    // one. Native answers a flush with its update before the reply, so until the reply every update is
    // the old owner's. An attach meanwhile waits for the same flush, then the latest owner takes over.
    if (_handingOver) return;
    _handingOver = true;
    flush().whenComplete(() {
      _handingOver = false;
      _route = _onUpdate;
    });
  }

  @override
  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    final wasOn = _on;
    _owner = null;
    _onUpdate = null;
    if (!_handingOver) _route = null;
    _on = false;
    if (wasOn) _sendActive();
  }

  Future<void> _sendActive() {
    final on = _on && _enabled && _builtin;
    if (on) _watchClicks();
    return _invoke<void>('active', {'on': on});
  }

  bool _watching = false;

  /// Shift (or Control) pressed and released with nothing in between toggles 中/英 in Rime. A click while it is
  /// held never reaches the engine as a key, so the native side is told, and tells the engine something came
  /// between. Registered on the first activation (the binding exists by then), for good.
  void _watchClicks() {
    if (_watching) return;
    _watching = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  @override
  void dispose() {
    if (_watching) GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    super.dispose();
  }

  void _onPointer(PointerEvent e) {
    if (e is! PointerDownEvent || !(_on && _enabled && _builtin)) return;
    final hw = HardwareKeyboard.instance;
    if (hw.isShiftPressed || hw.isControlPressed) _invoke<void>('interrupt');
  }

  @override
  Future<void> setActive(Object owner, bool on) {
    if (!identical(owner, _owner)) return Future.value();
    _on = on;
    return _sendActive();
  }

  @override
  Future<void> select(int index) => _invoke<void>('select', {'index': index});
  @override
  Future<void> page(bool next) => _invoke<void>('page', {'next': next});
  @override
  Future<bool> flush() async {
    if (!_ios) return false;
    try {
      await _channel.invokeMethod<void>('flush');
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> clear() => _invoke<void>('clear');

  @override
  void toggleBuiltin() {
    final next = !_builtin;
    if (!next) clear(); // going to 「系」: drop the composition without committing
    _builtin = next;
    _ascii = false;
    if (_owner != null) _sendActive();
    notifyListeners();
    _onBuiltin?.call(next);
  }
}
