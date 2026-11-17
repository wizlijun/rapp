// The iPad app going to the background and coming back (iPad spec §9), the screen kept awake while a session
// is live (§9.5) and the system's memory warning. Installed only by main_ios.dart: desktop never builds one.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../ios_channel.dart';
import 'main_state.dart';

/// Makes the lifecycle listener; tests pass one that makes none.
typedef LifecycleListen = AppLifecycleListener? Function({required VoidCallback onHide, required VoidCallback onShow});

AppLifecycleListener? _listen({required VoidCallback onHide, required VoidCallback onShow}) =>
    AppLifecycleListener(onHide: onHide, onShow: onShow);

class BackgroundWatch {
  /// Only `hidden` is the background: `inactive` (Control Center, the app switcher's first touch, a call
  /// banner) keeps every session.
  BackgroundWatch({required this.state, required this.ios, LifecycleListen? listen}) {
    _listener = (listen ?? _listen)(
      onHide: () => unawaited(state.enterBackground(begin: ios.beginBackground, end: ios.endBackground)),
      onShow: () => unawaited(state.enterForeground()),
    );
    _events = ios.events.listen((e) {
      if (e == 'memoryWarning') state.memoryWarning();
      if (e == 'pathChanged') state.netChanged();
    });
    state.addListener(_sync);
    _sync();
  }

  final MainState state;
  final IosChannel ios;
  AppLifecycleListener? _listener;
  StreamSubscription<String>? _events;
  bool? _awake, _active;

  /// The screen stays awake (if 屏幕常亮 is on) and the edge gestures are held while a session is live on
  /// the stage; each is sent only when it changes.
  void _sync() {
    final live = state.stageLive;
    final awake = state.prefs.keepAwake && live;
    if (awake != _awake) {
      _awake = awake;
      unawaited(ios.keepAwake(awake).catchError((Object _) {}));
    }
    if (live != _active) {
      _active = live;
      unawaited(ios.sessionActive(live).catchError((Object _) {}));
    }
  }

  void dispose() {
    state.removeListener(_sync);
    _listener?.dispose();
    _listener = null;
    unawaited(_events?.cancel());
    _events = null;
  }
}
