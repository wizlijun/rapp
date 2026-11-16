// One embedded session as the GUI sees it: the state the runner's events build up.
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset, Rect;

import 'app_profile.dart';
import 'composer_model.dart';
import 'geometry.dart' show contentSize;
import 'resize_policy.dart';
import 'session_port.dart';
import 'stream_choice.dart';
import 'window_rules.dart';
import 'window_tabs.dart';

/// Quiet seconds (no picture frame) after which a session that has shown one is idle.
const idleAfter = 10;

class RemoteSession extends ChangeNotifier {
  /// [onResize] is where the session's resize policy sends: window, width, height.
  /// [onDropBlock] is where a block that left the composer goes (the runner forgets it).
  /// [followNewTabs]: a window that appears becomes the current tab (off for terminals).
  RemoteSession(this.sid, this.appName,
      {void Function(int window, int w, int h)? onResize,
      this.onSelect,
      this.onStream,
      void Function(int n)? onDropBlock,
      this.appId = '',
      this.onReturn,
      this.onSelectInput,
      this.onClick,
      bool followNewTabs = true,
      DateTime Function()? clock})
      : policy = ResizePolicy(onResize ?? (_, _, _) {}),
        tabs = WindowTabs(followNew: followNewTabs) {
    composer = ComposerModel(onDrop: onDropBlock, onAllSent: _allSent, clock: clock);
    composer.addListener(_composerChanged);
    composer.onDeclined = () {
      composeArmed = false;
      notifyListeners();
    };
  }

  /// Whether a typed letter opens the writing panel. A panel opened by a letter and closed unused means the
  /// user wants the app's own keys (vim, y/n, a password): off until they open the panel themselves.
  bool composeArmed = true;

  bool _wasOpen = false;

  /// The panel opened (button, key, a clip's 「插入」, a compose letter): A goes to English now, so
  /// Chinese is composed on B (type-to-compose §1.1). [prepareInput] still checks before sending.
  void _composerChanged() {
    final open = composer.open;
    if (open && !_wasOpen) {
      if (!composeArmed && !composer.openedByLetter) {
        composeArmed = true;
        notifyListeners();
      }
      final s = inputSource;
      if (s != null && !s.ascii) selectInput('');
    }
    // A held letter is for the open that asked for it; the runner has dropped it by the next one.
    if (!open) composer.replayPending = false;
    _wasOpen = open;
  }

  /// The app this session runs (the profile's key); empty when unknown.
  final String appId;

  /// Where the after-send Return goes (the runner presses key [returnKeyCode]).
  final VoidCallback? onReturn;

  /// The composer's draft and whether it is open; kept per session (R18).
  late final ComposerModel composer;

  /// Where an input source switch goes (the runner's `select_input`; '' = English).
  final void Function(String id)? onSelectInput;

  /// Where the click on the marked text box goes: a left click at A point [at] of [window].
  final void Function(int window, Offset at)? onClick;

  /// 「直接回车且隐藏」: everything is in A, so the Return goes and the panel hides (the text stays,
  /// W6; the picture takes the keys back).
  void _allSent() {
    if (profile.afterSend != AfterSend.pressReturn) return;
    onReturn?.call();
    composer.collapse();
  }

  /// A's screen is locked, as its host last said; null until told (an older host never says).
  bool? screenLocked;

  /// A's input source as its host last said (null: an older host that never says).
  ({String id, String name, bool ascii})? inputSource;

  /// The last input method (not a plain layout) A had: what 「切回」 selects.
  ({String id, String name, bool ascii})? lastInputMethod;

  /// Switches A's input source: '' for English, else a source id it reported.
  void selectInput(String id) {
    if (inputSource == null) return; // the host would not understand
    onSelectInput?.call(id);
  }

  /// Right before text or a Return goes to A: English input on A (so its input method cannot
  /// eat what comes), and a click on the marked text box (so it has the focus).
  void prepareInput() {
    final s = inputSource;
    if (s != null && !s.ascii) onSelectInput?.call('');
    final c = inputClick();
    if (c != null) onClick?.call(c.window, c.at);
  }

  /// The user sent with an empty composer: a Return for A's app.
  void pressReturn() {
    prepareInput();
    onReturn?.call();
  }

  /// Where the marked text box is now, in A points of the main window; null without a mark, or
  /// while another window is the current tab (a click would bring the main one over it).
  ({int window, Offset at})? inputClick() {
    final p = profile.input;
    final m = _main;
    if (p == null || m == null) return null;
    final cur = currentWindow;
    if (cur != null && cur != m) return null;
    final w = windows.where((w) => w.id == m).firstOrNull;
    if (w == null) return null;
    final size = contentSize(w);
    if (size.width <= 0 || size.height <= 0) return null;
    final o = p.inContent(size);
    return (window: m, at: Offset(o.dx, w.titleBar + o.dy));
  }

  ResolvedProfile _profile = ResolvedProfile.generic;
  ResolvedProfile get profile => _profile;

  /// A new profile for this session: windows are filtered again.
  void setProfile(ResolvedProfile p) {
    _profile = p;
    _refilter();
    notifyListeners();
  }

  final MainWindowTracker _mainTracker = MainWindowTracker();
  int? _main;
  final Set<int> _showOnce = {};
  List<RemoteWindow> _shown = const [];
  List<RemoteWindow> _hidden = const [];

  /// What the tabs and popups are built from: [windows] minus what a `hide` rule hid.
  List<RemoteWindow> get shown => _shown;
  List<RemoteWindow> get hidden => _hidden;

  /// Ids in [windows] that are not in [shown] (the runner keeps them off a detached stage).
  Set<int> get hiddenIds {
    final s = {for (final w in _shown) w.id};
    return {for (final w in windows) if (!s.contains(w.id)) w.id};
  }

  bool isMain(int id) => _main == id;

  /// A hidden window has A's focus (keys would go to something not shown).
  bool get hiddenFocused => _hidden.any((w) => w.focused);

  /// Show hidden window [id] for this session only.
  void showOnce(int id) {
    _showOnce.add(id);
    _refilter();
    tabs.select(id);
    notifyListeners();
  }

  /// What is sent to this app goes into the input record (the app's own switch).
  bool get recordsInput => profile.recordInput;

  /// A's keyboard focus is in a password field, as its host last said (v13; false before that):
  /// type-to-compose does not open the panel and nothing sent is recorded (InputRecorder).
  bool secureFocus = false;

  /// The composer is on for the app and the current tab is not a `noComposer` one.
  bool get composerAllowed {
    if (!profile.composer) return false;
    final c = currentWindow;
    if (c == null) return true;
    for (final w in _shown) {
      if (w.id == c) return actionFor(profile.windows, w, isMain: isMain(c)) != RuleAction.noComposer;
    }
    return true;
  }

  void _refilter() {
    _main = _mainTracker.update(windows);
    final ids = {for (final w in windows) w.id};
    _showOnce.retainAll(ids);
    final r = applyHide(windows, profile.windows, main: _main, showOnce: _showOnce);
    _shown = r.shown;
    _hidden = r.hidden;
    tabs.update(_shown);
  }

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

  /// The user picked a stream choice by hand: A never changes it on its own (kept for the session's life).
  bool streamPinned = false;

  /// A lowered the stream below the choice (any saving level).
  bool weak = false;

  /// How far A lowered it: 0, 1 (frame rate) or 2 (the floor).
  int saving = 0;

  /// The last ping round trip over the whole path; null before one (or from a v8 A).
  int? rttMs;

  /// The whole path looks broken.
  bool stalled = false;

  /// [c] is the new choice; [manual] when the user picked it in the stream menu.
  void setChoice(StreamChoice c, {bool manual = false}) {
    choice = c;
    if (manual) streamPinned = true;
    onStream?.call(c);
    notifyListeners();
  }

  /// The decorated windows and which one is current.
  final WindowTabs tabs;

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
      case StreamChoiceEvent():
        setChoice(StreamChoice(e.mode, e.density, e.fps, smart: e.smart), manual: true);
      case ReadyEvent():
        ready = true;
        appName = e.appName;
      case WindowsEvent():
        final old = windows;
        windows = e.windows;
        if (focus != null) {
          final f = focus!;
          final now = windows.where((w) => w.id == f.window).firstOrNull;
          final before = old.where((w) => w.id == f.window).firstOrNull;
          // Gone, or resized: the rects are in the old size's points. Clear until A sends fresh ones
          // (extra colour meanwhile, never wrong gray). Moving or a title bar change is harmless.
          if (now == null || (before != null && before.rect.size != now.rect.size)) focus = null;
        }
        _refilter();
        final p = _pendingCurrent;
        if (p != null && _isTab(p)) {
          _pendingCurrent = null;
          tabs.select(p);
        }
      case FocusRegionEvent():
        // A late one (smart left) must not paint gray on a session that is not asking. Otherwise kept
        // as A said it, window 0 (no focus window) and not-yet-listed windows included: the drawing
        // only acts on the current window with rects.
        if (!_focusWanted) return;
        focus = (window: e.window, rects: e.rects);
      case WeakEvent():
        weak = e.on;
        saving = e.on ? e.level : 0;
      case RttEvent():
        rttMs = e.ms;
      case StalledEvent():
        stalled = e.on;
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
      case ComposerDraftEvent():
        // Detached, the other window holds the text and has no marks in it; it reports a chip it lost
        // as `drop` instead. Attached, the text is ours and its marks say which blocks are still held.
        if (e.text != null) {
          if (detached) {
            composer.setDetachedDraft(e.text!);
          } else {
            composer.setDraft(e.text!);
          }
        }
        if (e.drop != null) composer.removeBlock(e.drop!);
      case ComposerInsertEvent():
        // A clip's 「插入」: into the draft, which opens to show it.
        composer.apply(e.insert);
        composer.open = true;
        composer.wantFocus();
      case ComposeKeyEvent():
        // A letter on the picture (type-to-compose): the panel opens, takes the caret, then asks for the letter.
        // Not when the panel is off here (the tab just became noComposer): the runner drops its hold when
        // MainState sends compose:false for that picture.
        if (!composerAllowed || !composeArmed || secureFocus) break;
        composer.replayPending = true;
        composer.openByLetter();
        composer.wantFocus();
      case TransferStatusEvent():
        transferStatus = e.status;
      case TransferProgressEvent():
        break; // MainState's.
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
      case InputBlockedEvent():
        break; // MainState's hint.
      case InputSourceEvent():
        inputSource = (id: e.id, name: e.name, ascii: e.ascii);
        if (!e.ascii) lastInputMethod = inputSource;
      case ScreenLockedEvent():
        screenLocked = e.locked;
      case SecureFocusEvent():
        secureFocus = e.on;
      case CoveredEvent():
      case AppOpenedEvent():
        break; // MainState's notice.
      case ClosedEvent():
        endReason = e.reason;
    }
    notifyListeners();
  }

  /// The link is gone: no transfer or send round is running any more.
  void linkDown() {
    focus = null;
    secureFocus = false; // a new link's host says it again when it is still so
    _focusWanted = false;
    transferStatus = null;
    rttMs = null;
    stalled = false;
    weak = false;
    saving = 0;
    composer.done(0, null);
    notifyListeners();
  }

  /// A's focus region (§6 of the focus-pane spec): null until A says, and again when it can no longer
  /// be true (link down, its window gone, smart off). Empty rects mean the whole window.
  ({int window, List<Rect> rects})? focus;

  bool _focusWanted = false;

  /// Whether A is being asked for the focus region (MainState sets it with each `set_stream`).
  /// While false, focus events are ignored; turning it off clears [focus].
  bool get focusWanted => _focusWanted;
  set focusWanted(bool v) {
    if (_focusWanted == v) return;
    _focusWanted = v;
    if (!v) clearFocus();
  }

  /// Forgets the focus region (smart left, or A is no longer asked) and tells the listeners.
  void clearFocus() {
    if (focus == null) return;
    focus = null;
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
    composer.removeListener(_composerChanged);
    composer.dispose();
    super.dispose();
  }
}
