// Fullscreen control, abstracted so tests don't need a real window.
import 'package:window_manager/window_manager.dart';

abstract class FullscreenControl {
  Future<bool> isFullScreen();
  Future<void> setFullScreen(bool on);
}

class WindowManagerFullscreen implements FullscreenControl {
  @override
  Future<bool> isFullScreen() => windowManager.isFullScreen();

  @override
  Future<void> setFullScreen(bool on) => windowManager.setFullScreen(on);
}
