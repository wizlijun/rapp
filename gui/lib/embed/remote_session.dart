// One embedded session as the GUI sees it: the state the runner's events build up.
import 'package:flutter/foundation.dart';

import 'resize_policy.dart';
import 'session_port.dart';
import 'window_tabs.dart';

class RemoteSession extends ChangeNotifier {
  /// [onResize] is where the session's resize policy sends: window, width, height.
  RemoteSession(this.sid, this.appName, {void Function(int window, int w, int h)? onResize, this.onSelect})
      : policy = ResizePolicy(onResize ?? (_, _, _) {});

  /// Decides when the stage size becomes A's window size.
  final ResizePolicy policy;

  /// Where a tab pick goes (A raises that window).
  final void Function(int window)? onSelect;

  /// The decorated windows and which one is current.
  final WindowTabs tabs = WindowTabs();

  final Object sid;
  String appName;
  bool ready = false;
  List<RemoteWindow> windows = const [];
  int? get currentWindow => tabs.current;
  bool detached = false;
  int bytesPerSecond = 0;
  List<ClipRow> clips = const [];
  List<MenuEntry> menu = const [];

  /// Set once the runner reported the session closed.
  String? endReason;

  void apply(SessionEvent e) {
    switch (e) {
      case ReadyEvent():
        ready = true;
        appName = e.appName;
      case WindowsEvent():
        windows = e.windows;
        tabs.update(windows);
      case TrafficEvent():
        bytesPerSecond = e.bytes;
      case ClipsEvent():
        clips = e.clips;
      case MenuEvent():
        menu = e.items;
      case DetachedEvent():
        detached = e.detached;
        if (e.current != null) tabs.select(e.current!);
      case ClosedEvent():
        endReason = e.reason;
      default:
        return;
    }
    notifyListeners();
  }

  /// The user picked tab [id]: A raises it, and the stage size is judged for it at once.
  void selectWindow(int id) {
    if (!tabs.tabs.any((w) => w.id == id)) return;
    tabs.select(id);
    onSelect?.call(id);
    for (final w in windows) {
      if (w.id == id) policy.current(w);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    policy.dispose();
    super.dispose();
  }
}
