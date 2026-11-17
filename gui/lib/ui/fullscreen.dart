// Fullscreen control, abstracted so tests don't need a real window.
import 'dart:async';

import 'package:window_manager/window_manager.dart';

import '../ios_channel.dart';

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

/// iOS: the app is always the whole screen; fullscreen hides the status bar, lets the home indicator fade, and
/// MainWindow lets the stage run under them (the `fullscreen` method, RappViewController). The state lives here:
/// nothing on iOS changes it behind the app's back.
class IosFullscreen implements FullscreenControl {
  IosFullscreen([IosChannel? channel]) : _channel = channel ?? iosChannel;

  final IosChannel _channel;
  final _changes = StreamController<bool>.broadcast();
  bool _on = false;

  @override
  Stream<bool> get changes => _changes.stream;

  @override
  Future<bool> isFullScreen() async => _on;

  @override
  Future<void> setFullScreen(bool on) async {
    await _channel.fullscreen(on);
    if (on == _on) return;
    _on = on;
    _changes.add(on);
  }
}

/// No fullscreen control: MainWindow shows no fullscreen button.
class NoFullscreen implements FullscreenControl {
  const NoFullscreen();

  @override
  Stream<bool> get changes => const Stream.empty();

  @override
  Future<bool> isFullScreen() async => false;

  @override
  Future<void> setFullScreen(bool on) async {}
}
