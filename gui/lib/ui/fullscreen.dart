// Fullscreen control, abstracted so tests don't need a real window.
import 'dart:async';
import 'dart:ui' show Size;

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

/// A window whose short side is under this is a folded Duo (its outer screen, either way up) or a phone: the
/// Duo's inner screen is wider than this both ways up (iPad spec §7.1, F4).
const foldedShortSide = 600.0;

/// iOS: folding the Duo leaves fullscreen and unfolding it comes back. What is wanted unfolded is 启动时全屏 at
/// first, then whatever the fullscreen button last set; folded, the status bar always shows. Window sizes and
/// button presses are taken one at a time, in the order they came.
class FoldFullscreen implements FullscreenControl {
  FoldFullscreen(this._inner);

  final FullscreenControl _inner;
  bool _want = false;
  bool? _folded;
  Future<void> _queue = Future.value();

  static bool _isFolded(Size s) => s.shortestSide < foldedShortSide;

  Future<void> _then(Future<void> Function() f) => _queue = _queue.then((_) => f()).catchError((Object _) {});

  /// The app's first window size and 启动时全屏: fullscreen now unless folded.
  Future<void> start({required bool want, required Size size}) => _then(() async {
        _want = want;
        _folded = _isFolded(size);
        if (want && !_folded!) await _inner.setFullScreen(true);
      });

  /// The window changed size (fold, unfold, rotation, Split View).
  Future<void> windowSize(Size size) => _then(() async {
        final folded = _isFolded(size);
        if (folded == _folded) return;
        _folded = folded;
        if (folded) {
          if (await _inner.isFullScreen()) await _inner.setFullScreen(false);
        } else if (_want) {
          await _inner.setFullScreen(true);
        }
      });

  @override
  Stream<bool> get changes => _inner.changes;

  @override
  Future<bool> isFullScreen() => _inner.isFullScreen();

  /// The fullscreen button: also what unfolding comes back to.
  @override
  Future<void> setFullScreen(bool on) => _then(() async {
        _want = on;
        await _inner.setFullScreen(on);
      });
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
