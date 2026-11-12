// One embedded session as the GUI sees it: the state the runner's events build up.
import 'package:flutter/foundation.dart';

import 'composer_model.dart';
import 'resize_policy.dart';
import 'session_port.dart';
import 'stream_choice.dart';
import 'window_tabs.dart';

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
        if (e.current != null) tabs.select(e.current!);
      case ClosedEvent():
        endReason = e.reason;
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
    composer.dispose();
    super.dispose();
  }
}
