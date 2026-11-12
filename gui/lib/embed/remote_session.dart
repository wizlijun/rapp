// One embedded session as the GUI sees it: the state the runner's events build up.
import 'package:flutter/foundation.dart';

import 'composer_model.dart';
import 'resize_policy.dart';
import 'session_port.dart';
import 'stream_choice.dart';
import 'window_tabs.dart';

/// Quiet seconds (no picture frame) after which a session that has shown one is idle.
const idleAfter = 10;

class RemoteSession extends ChangeNotifier {
  /// [onResize] is where the session's resize policy sends: window, width, height.
  /// [onDropBlock] is where a block that left the composer goes (the runner forgets it).
  RemoteSession(this.sid, this.appName,
      {void Function(int window, int w, int h)? onResize, this.onSelect, this.onStream, void Function(int n)? onDropBlock})
      : policy = ResizePolicy(onResize ?? (_, _, _) {}),
        composer = ComposerModel(onDrop: onDropBlock);

  /// The composer's draft and whether it is open; kept per session (R18).
  final ComposerModel composer;

  /// The upload strip's text (`上传 1/2 · a.txt`); null when nothing is uploading.
  String? transferStatus;

  /// Decides when the stage size becomes A's window size.
  final ResizePolicy policy;

  /// Where a tab pick goes (A raises that window).
  final void Function(int window)? onSelect;

  /// Where a new stream choice goes (the runner's `set_stream`).
  final void Function(StreamChoice choice)? onStream;

  /// What the user chose for this session's stream; kept per session (R18), not saved.
  StreamChoice choice = startChoice;

  /// The user picked [c] in the stream menu.
  void setChoice(StreamChoice c) {
    choice = c;
    onStream?.call(c);
    notifyListeners();
  }

  /// The decorated windows and which one is current.
  final WindowTabs tabs = WindowTabs();

  final Object sid;
  String appName;
  bool ready = false;
  List<RemoteWindow> windows = const [];
  int? get currentWindow => tabs.current;
  bool detached = false;
  int bytesPerSecond = 0;

  /// Whether a picture frame has arrived yet, and how many seconds have passed since the last.
  bool sawFrame = false;
  int quietSeconds = 0;
  bool get idle => sawFrame && quietSeconds >= idleAfter;
  List<ClipRow> clips = const [];
  List<MenuEntry> menu = const [];

  /// Set once the runner reported the session closed.
  String? endReason;

  /// The window an attach named as current (R21) before it was a tab here: selected when a
  /// window table brings it, dropped by a tab pick or the next detach.
  int? _pendingCurrent;

  /// Prefer window [id] when a window table brings it (like an attach's current window).
  void preferWindow(int? id) => _pendingCurrent = id;

  bool _isTab(int id) => tabs.tabs.any((w) => w.id == id);

  void apply(SessionEvent e) {
    switch (e) {
      case ReadyEvent():
        ready = true;
        appName = e.appName;
      case WindowsEvent():
        windows = e.windows;
        tabs.update(windows);
        final p = _pendingCurrent;
        if (p != null && _isTab(p)) {
          _pendingCurrent = null;
          tabs.select(p);
        }
      case TrafficEvent():
        bytesPerSecond = e.bytes;
        if (e.frames > 0) {
          sawFrame = true;
          quietSeconds = 0;
        } else if (sawFrame) {
          quietSeconds++;
        }
      case DisconnectedEvent():
        linkDown();
        return;
      case ClipsEvent():
        clips = e.clips;
        composer.clipArrived();
      case ComposerStateEvent():
        if (e.sending != null) composer.setSending(e.sending!);
        final d = e.done;
        if (d != null) composer.done(d.sent, d.failure);
      case ComposerInsertEvent():
        // A clip's 「插入」: into the draft, which opens to show it.
        composer.apply(e.insert);
        composer.open = true;
        composer.wantFocus();
      case TransferEvent():
        transferStatus = e.status;
      case MenuEvent():
        menu = e.items;
      case DetachedEvent():
        detached = e.detached;
        final c = e.current;
        _pendingCurrent = null;
        if (!detached && c != null) {
          // The runner names a window it had, but its table may not have reached us yet.
          _isTab(c) ? tabs.select(c) : _pendingCurrent = c;
        }
      case ClosedEvent():
        endReason = e.reason;
    }
    notifyListeners();
  }

  /// The link is gone: no transfer or send round is running any more.
  void linkDown() {
    transferStatus = null;
    composer.done(0, null);
    notifyListeners();
  }

  /// The user picked tab [id]: A raises it, and the stage size is judged for it at once (not while
  /// detached: then the session is not on the stage).
  void selectWindow(int id) {
    if (!_isTab(id)) return;
    _pendingCurrent = null;
    tabs.select(id);
    onSelect?.call(id);
    if (!detached) {
      for (final w in windows) {
        if (w.id == id) policy.current(w);
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    policy.dispose();
    composer.dispose();
    super.dispose();
  }
}
