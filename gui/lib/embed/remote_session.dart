// One embedded session as the GUI sees it: the state the runner's events build up.
import 'package:flutter/foundation.dart';

import 'session_port.dart';

class RemoteSession extends ChangeNotifier {
  RemoteSession(this.sid, this.appName);

  final Object sid;
  String appName;
  bool ready = false;
  List<RemoteWindow> windows = const [];
  int? currentWindow;
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
        final keep = currentWindow != null && windows.any((w) => w.id == currentWindow && w.decorated);
        if (!keep) {
          currentWindow = null;
          for (final w in windows) {
            if (w.decorated) {
              currentWindow = w.id;
              break;
            }
          }
        }
      case TrafficEvent():
        bytesPerSecond = e.bytes;
      case ClipsEvent():
        clips = e.clips;
      case MenuEvent():
        menu = e.items;
      case DetachedEvent():
        detached = e.detached;
        if (e.current != null) currentWindow = e.current;
      case ClosedEvent():
        endReason = e.reason;
      default:
        return;
    }
    notifyListeners();
  }
}
