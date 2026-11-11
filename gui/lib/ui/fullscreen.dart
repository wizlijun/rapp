// Fullscreen control, abstracted so tests don't need a real window.
import 'dart:async';

import 'package:window_manager/window_manager.dart';

abstract class FullscreenControl {
  Future<bool> isFullScreen();
  Future<void> setFullScreen(bool on);

  /// Emits the new state whenever fullscreen changes, including OS-driven changes.
  Stream<bool> get changes;
}

class WindowManagerFullscreen with WindowListener implements FullscreenControl {
  final _changes = StreamController<bool>.broadcast();
  bool _attached = false;

  @override
  Stream<bool> get changes {
    if (!_attached) {
      _attached = true;
      windowManager.addListener(this);
    }
    return _changes.stream;
  }

  @override
  void onWindowEnterFullScreen() => _changes.add(true);

  @override
  void onWindowLeaveFullScreen() => _changes.add(false);

  @override
  Future<bool> isFullScreen() => windowManager.isFullScreen();

  @override
  Future<void> setFullScreen(bool on) => windowManager.setFullScreen(on);
}
