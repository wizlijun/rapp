import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/geometry.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_choice.dart';

import '../fakes.dart';

RemoteWindow w(int id, {WindowKind kind = WindowKind.normal, bool focused = false}) => RemoteWindow(
      id: id,
      parent: 0,
      kind: kind,
      title: 'w$id',
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      titleBar: 28,
      resizable: true,
      focused: focused,
      texture: id,
      visible: const Rect.fromLTWH(0, 0, 1, 1),
    );

RemoteWindow win(int id, WindowKind kind) => RemoteWindow(
      id: id,
      parent: 0,
      kind: kind,
      title: 'w$id',
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      titleBar: 28,
      resizable: true,
      focused: false,
      texture: id,
      visible: const Rect.fromLTWH(0, 0, 1, 1),
    );

void main() {
  group('zoom', () {
    test('a window gone from the table loses its zoom', () {
      final rs = RemoteSession(1, 'Calc');
      rs.apply(WindowsEvent(1, [w(7), w(8)]));
      rs.zoomOf(7);
      rs.zoomOf(8);
      rs.apply(WindowsEvent(1, [w(8)]));
      expect(rs.zoomIfAny(7), isNull);
      expect(rs.zoomIfAny(8), isNotNull);
    });

    test('zooms notifies when a window zooms; currentZoomed follows the current tab', () {
      final rs = RemoteSession(1, 'Calc');
      rs.apply(WindowsEvent(1, [w(7)]));
      var n = 0;
      rs.zooms.addListener(() => n++);
      expect(rs.currentZoomed, false);
      const stage = Size(1000, 700);
      final fit = fitRect(const Size(100, 100), stage);
      rs.zoomOf(7).zoomTo(2, const Offset(500, 350), fit, stage);
      expect(n, 1);
      expect(rs.currentWindow, 7);
      expect(rs.currentZoomed, true);
    });

    test('the view range is said again after Ready (a new link forgot it)', () {
      final sent = <(int, Rect, double)>[];
      final rs = RemoteSession(1, 'Calc', onView: (w, r, z) => sent.add((w, r, z)));
      rs.view.settled(7, const Rect.fromLTWH(10, 10, 20, 20), const Size(100, 100), 2);
      expect(sent.length, 1);
      rs.apply(const ReadyEvent(1, 'Calc'));
      expect(sent.length, 2);
      expect(sent[1], sent[0]);
    });

    test('restoreCurrent tells A the whole window again', () {
      final sent = <(int, Rect, double)>[];
      final rs = RemoteSession(1, 'Calc', onView: (w, r, z) => sent.add((w, r, z)));
      rs.apply(WindowsEvent(1, [w(7)]));
      rs.view.settled(7, const Rect.fromLTWH(10, 10, 20, 20), const Size(100, 100), 2);
      rs.restoreCurrent();
      expect(sent.last, (0, Rect.zero, 1.0));
    });

    test('adoptZoom carries z and centre of shared windows over', () {
      const stage = Size(1000, 700);
      final fit = fitRect(const Size(100, 100), stage);
      final old = RemoteSession(1, 'Calc')..apply(WindowsEvent(1, [w(7), w(9)]));
      old.zoomOf(7).zoomTo(3, const Offset(300, 200), fit, stage);
      final fresh = RemoteSession(2, 'Calc')..apply(WindowsEvent(2, [w(7)]));
      fresh.adoptZoom(old);
      expect(fresh.zoomIfAny(7)!.z, 3);
      expect(fresh.zoomIfAny(7)!.centre, old.zoomIfAny(7)!.centre);
      expect(fresh.zoomIfAny(9), isNull);
    });
  });

  group('window payload', () {
    Map<String, Object?> payload({int? base}) => {
          'id': 1, 'parent': 0, 'kind': 'normal', 'title': 't', 'x': 0, 'y': 0, 'w': 10, 'h': 10,
          'titleBar': 0, 'resizable': true, 'focused': false, 'texture': 3, 'visible': [0, 0, 1, 1],
          'base': ?base,
        };
    test('base is the baseTexture, null when absent', () {
      final a = parseSessionEvent('windows', {'sid': 1, 'windows': [payload(base: 5)]}) as WindowsEvent;
      expect(a.windows.single.baseTexture, 5);
      final b = parseSessionEvent('windows', {'sid': 1, 'windows': [payload()]}) as WindowsEvent;
      expect(b.windows.single.baseTexture, isNull);
    });
  });

  test('linkDown clears the inferred state', () {
    final rs = RemoteSession(1, 'Calc');
    rs.apply(const AppStateEvent(1, '{"state":"working","health":"ok"}'));
    expect(rs.appState!.state, 'working');
    rs.apply(const AppStateEvent(1, 'junk'));
    expect(rs.appState!.state, 'working'); // a bad report is skipped
    rs.linkDown();
    expect(rs.appState, isNull);
  });

  group('focus', () {
    FocusRegionEvent ev(int window) => FocusRegionEvent(1, window, const [Rect.fromLTWH(0, 0, 10, 10)]);

    test('the event is kept; linkDown and clearFocus drop it and notify', () {
      final rs = RemoteSession(1, 'Calc')..focusWanted = true;
      rs.apply(WindowsEvent(1, [w(7)]));
      var n = 0;
      rs.addListener(() => n++);
      expect(rs.focus, isNull);
      rs.apply(ev(7));
      expect(rs.focus!.window, 7);
      expect(rs.focus!.rects, const [Rect.fromLTWH(0, 0, 10, 10)]);
      expect(n, 1);
      rs.linkDown();
      expect(rs.focus, isNull);
      rs.focusWanted = true;
      rs.apply(ev(7));
      n = 0;
      rs.clearFocus();
      expect(rs.focus, isNull);
      expect(n, 1);
      rs.clearFocus();
      expect(n, 1, reason: 'nothing to clear, nothing to tell');
    });

    test('focus cleared when its window leaves the table', () {
      final rs = RemoteSession(1, 'Calc')..focusWanted = true;
      rs.apply(WindowsEvent(1, [w(7)]));
      rs.apply(ev(7));
      expect(rs.focus, isNotNull);
      rs.apply(WindowsEvent(1, [w(8)]));
      expect(rs.focus, isNull);
    });

    RemoteWindow sized(int id, Rect r) => RemoteWindow(
          id: id,
          parent: 0,
          kind: WindowKind.normal,
          title: 'w$id',
          rect: r,
          titleBar: 28,
          resizable: true,
          focused: true,
          texture: id,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    test('focus cleared, and listeners told, when its window is resized', () {
      final rs = RemoteSession(1, 'Calc')..focusWanted = true;
      rs.apply(WindowsEvent(1, [sized(7, const Rect.fromLTWH(0, 0, 800, 600))]));
      rs.apply(ev(7));
      expect(rs.focus, isNotNull);
      var n = 0;
      rs.addListener(() => n++);
      rs.apply(WindowsEvent(1, [sized(7, const Rect.fromLTWH(0, 0, 900, 600))]));
      expect(rs.focus, isNull);
      expect(n, greaterThan(0));
    });

    test('focus kept when its window only moves', () {
      final rs = RemoteSession(1, 'Calc')..focusWanted = true;
      rs.apply(WindowsEvent(1, [sized(7, const Rect.fromLTWH(0, 0, 800, 600))]));
      rs.apply(ev(7));
      rs.apply(WindowsEvent(1, [sized(7, const Rect.fromLTWH(50, 40, 800, 600))]));
      expect(rs.focus, isNotNull);
    });
  });

  group('late focus events', () {
    FocusRegionEvent ev(int window) => FocusRegionEvent(1, window, const [Rect.fromLTWH(0, 0, 10, 10)]);

    test('an event after leaving smart is ignored, and leaving clears the stored one', () {
      final rs = RemoteSession(1, 'Calc')..focusWanted = true;
      rs.apply(WindowsEvent(1, [w(7)]));
      rs.apply(ev(7));
      expect(rs.focus, isNotNull);
      rs.focusWanted = false;
      expect(rs.focus, isNull);
      rs.apply(ev(7));
      expect(rs.focus, isNull);
    });

    test('window 0 with no rects replaces an older focus and notifies', () {
      final rs = RemoteSession(1, 'Calc')..focusWanted = true;
      rs.apply(WindowsEvent(1, [w(7)]));
      rs.apply(ev(7));
      var n = 0;
      rs.addListener(() => n++);
      rs.apply(FocusRegionEvent(1, 0, const []));
      expect(rs.focus!.window, 0);
      expect(rs.focus!.rects, isEmpty);
      expect(n, 1);
    });

    test('an event before its window is in the table is kept, and the table that lists it keeps it', () {
      final rs = RemoteSession(1, 'Calc')..focusWanted = true;
      rs.apply(ev(7));
      expect(rs.focus!.window, 7);
      rs.apply(WindowsEvent(1, [w(7)]));
      expect(rs.focus!.window, 7);
    });
  });

  test('weak event sets RemoteSession.weak', () {
    final rs = RemoteSession(1, 'Calc');
    var n = 0;
    rs.addListener(() => n++);
    expect(rs.weak, false);
    rs.apply(parseSessionEvent('weak', {'sid': 1, 'on': true})!);
    expect(rs.weak, true);
    expect(n, 1);
    rs.apply(parseSessionEvent('weak', {'sid': 1, 'on': false})!);
    expect(rs.weak, false);
  });

  test('weak carries the saving level; rtt and stalled are kept; a link down forgets the round trip', () {
    final rs = RemoteSession(1, 'Calc');
    rs.apply(parseSessionEvent('weak', {'sid': 1, 'on': true, 'level': 1})!);
    expect((rs.weak, rs.saving), (true, 1));
    rs.apply(parseSessionEvent('weak', {'sid': 1, 'on': true})!);
    expect(rs.saving, 2, reason: 'a runner without the level means the floor');
    rs.apply(parseSessionEvent('weak', {'sid': 1, 'on': false, 'level': 0})!);
    expect((rs.weak, rs.saving), (false, 0));
    rs.apply(parseSessionEvent('rtt', {'sid': 1, 'ms': 420})!);
    expect(rs.rttMs, 420);
    final st = parseSessionEvent('stalled', {'sid': 1, 'on': true});
    expect(st, isA<StalledEvent>().having((e) => e.on, 'on', true));
    rs.apply(st!);
    expect(rs.stalled, true);
    rs.linkDown();
    expect((rs.rttMs, rs.stalled, rs.saving), (null, false, 0));
  });

  test('setChoice pins only when manual', () {
    final rs = RemoteSession(1, 'Calc');
    rs.setChoice(presetLeast);
    expect(rs.streamPinned, false);
    rs.setChoice(presetLeast, manual: true);
    expect(rs.streamPinned, true);
  });

  test('disconnected clears the transfer line and the sending state', () {
    final r = RemoteSession(1, 'x');
    r.apply(const TransferStatusEvent(1, '下载 x 45%'));
    r.apply(const ComposerStateEvent(1, sending: true));
    expect(r.transferStatus, '下载 x 45%');
    expect(r.composer.sending, true);
    r.apply(const DisconnectedEvent(1, 'connection closed'));
    expect(r.transferStatus, isNull);
    expect(r.composer.sending, false);
  });

  test('screenLocked is null until A says, then follows it', () {
    final r = RemoteSession(1, 'desktop:');
    expect(r.screenLocked, isNull);
    r.apply(const ScreenLockedEvent(1, true));
    expect(r.screenLocked, isTrue);
    r.apply(const ScreenLockedEvent(1, false));
    expect(r.screenLocked, isFalse);
  });

  test('secureFocus follows A, blocks type-to-compose, and goes with the link', () {
    final r = RemoteSession(1, 'x');
    expect(r.secureFocus, isFalse);
    r.apply(const SecureFocusEvent(1, true));
    expect(r.secureFocus, isTrue);
    r.apply(const ComposeKeyEvent(1));
    expect(r.composer.open, isFalse);
    r.apply(const DisconnectedEvent(1, 'connection closed'));
    expect(r.secureFocus, isFalse);
  });

  test('ready sets appName and ready', () {
    final r = RemoteSession(1, 'x');
    var n = 0;
    r.addListener(() => n++);
    r.apply(const ReadyEvent(1, 'Calculator'));
    expect(r.ready, true);
    expect(r.appName, 'Calculator');
    expect(n, 1);
  });

  test('windows picks the first decorated window as current', () {
    final r = RemoteSession(1, 'x');
    var n = 0;
    r.addListener(() => n++);
    r.apply(WindowsEvent(1, [win(7, WindowKind.sheet), win(8, WindowKind.normal), win(9, WindowKind.dialog)]));
    expect(r.windows.length, 3);
    expect(r.currentWindow, 8);
    expect(n, 1);
  });

  test('traffic sets bytesPerSecond with one notify', () {
    final r = RemoteSession(1, 'x');
    var n = 0;
    r.addListener(() => n++);
    r.apply(const TrafficEvent(1, 2048));
    expect(r.bytesPerSecond, 2048);
    expect(n, 1);
  });

  test('closed records the reason', () {
    final r = RemoteSession(1, 'x');
    r.apply(const ClosedEvent(1, 'quit'));
    expect(r.endReason, 'quit');
  });

  group('attach with a current window (x)', () {
    test('a known id becomes current at once', () {
      final r = RemoteSession(1, 'x');
      r.apply(WindowsEvent(1, [win(5, WindowKind.normal), win(8, WindowKind.normal)]));
      r.apply(const DetachedEvent(1, true));
      r.apply(const DetachedEvent(1, false, current: 8));
      expect(r.detached, false);
      expect(r.tabs.current, 8);
    });

    test('an id that is not a tab yet waits for the table that brings it', () {
      final r = RemoteSession(1, 'x');
      r.apply(WindowsEvent(1, [win(5, WindowKind.normal)]));
      r.apply(const DetachedEvent(1, true));
      r.apply(const DetachedEvent(1, false, current: 8));
      expect(r.tabs.current, 5);
      // 9 and 8 are both new: without the wait the first new one (9) would win.
      r.apply(WindowsEvent(1, [win(9, WindowKind.normal), win(8, WindowKind.normal)]));
      expect(r.tabs.current, 8);
      // Used once: a later new window becomes current as usual.
      r.apply(WindowsEvent(1, [win(9, WindowKind.normal), win(8, WindowKind.normal), win(10, WindowKind.normal)]));
      expect(r.tabs.current, 10);
    });

    test('a popup id never becomes current; a tab pick drops the wait', () {
      final r = RemoteSession(1, 'x');
      r.apply(WindowsEvent(1, [win(5, WindowKind.normal), win(6, WindowKind.normal)]));
      r.apply(const DetachedEvent(1, false, current: 8));
      r.apply(WindowsEvent(1, [win(5, WindowKind.normal), win(6, WindowKind.normal), win(8, WindowKind.menu)]));
      expect(r.tabs.current, 5);
      r.selectWindow(6);
      r.apply(WindowsEvent(1, [
        win(5, WindowKind.normal), win(6, WindowKind.normal), win(9, WindowKind.normal), win(8, WindowKind.normal),
      ]));
      expect(r.tabs.current, 9); // the first new one, by the ordinary rule: the wait is gone
    });

    test('detaching again forgets an earlier wait', () {
      final r = RemoteSession(1, 'x');
      r.apply(WindowsEvent(1, [win(5, WindowKind.normal)]));
      r.apply(const DetachedEvent(1, false, current: 8));
      r.apply(const DetachedEvent(1, true));
      r.apply(const DetachedEvent(1, false));
      r.apply(WindowsEvent(1, [win(9, WindowKind.normal), win(8, WindowKind.normal)]));
      expect(r.tabs.current, 9);
    });
  });

  test('ten quiet ticks make a session idle, one frame wakes it', () {
    final r = RemoteSession(1, 'A');
    r.apply(const TrafficEvent(1, 900, 1));
    for (var i = 0; i < 9; i++) {
      r.apply(const TrafficEvent(1, 0, 0));
    }
    expect(r.idle, false);
    r.apply(const TrafficEvent(1, 0, 0));
    expect(r.idle, true);
    r.apply(const TrafficEvent(1, 10, 1));
    expect(r.idle, false);
    expect(r.quietSeconds, 0);
  });

  test('no frame yet is never idle', () {
    final r = RemoteSession(1, 'A');
    for (var i = 0; i < 20; i++) {
      r.apply(const TrafficEvent(1, 0, 0));
    }
    expect(r.idle, false);
    expect(r.sawFrame, false);
  });

  test('side bytes alone do not keep a session active', () {
    final r = RemoteSession(1, 'A');
    r.apply(const TrafficEvent(1, 900, 1));
    for (var i = 0; i < 10; i++) {
      r.apply(const TrafficEvent(1, 80000, 0));
    }
    expect(r.idle, true);
    expect(r.bytesPerSecond, 80000);
  });

  test('preferWindow picks that window when the table brings it', () {
    final r = RemoteSession(1, 'A');
    r.preferWindow(7);
    r.apply(WindowsEvent(1, [win(3, WindowKind.normal), win(7, WindowKind.normal)]));
    expect(r.currentWindow, 7);
    final r2 = RemoteSession(1, 'A');
    r2.preferWindow(9);
    r2.apply(WindowsEvent(1, [win(3, WindowKind.normal), win(7, WindowKind.normal)]));
    expect(r2.currentWindow, 3);
  });

  test('transfer progress does not touch the status line', () {
    final r = RemoteSession(1, 'x');
    r.apply(const TransferStatusEvent(1, '上传 1/1 0%'));
    for (final state in TransferState.values) {
      r.apply(TransferProgressEvent(1, 3, true, 'a', 1, 2, state, null, 'boom'));
      expect(r.transferStatus, '上传 1/1 0%', reason: '$state');
    }
  });

  const hideFloating = ResolvedProfile(name: 'X', windows: [WindowRule(kind: WindowKind.floating, action: RuleAction.hide)]);

  test('a hide rule keeps the window out of the tabs and counts it', () {
    final rs = RemoteSession(1, 'X', appId: 'x')..setProfile(hideFloating);
    rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.floating)]));
    expect(rs.tabs.tabs.map((e) => e.id), [1]);
    expect(rs.hidden.map((e) => e.id), [2]);
    expect(rs.hiddenIds, {2});
    expect(rs.windows.length, 2);
  });

  test('hiding the current tab moves to the most recent shown one', () {
    final rs = RemoteSession(1, 'X');
    rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.floating), w(3)]));
    rs.selectWindow(3);
    rs.selectWindow(2);
    rs.setProfile(hideFloating);
    expect(rs.currentWindow, 3);
  });

  test('showOnce brings it back as the current tab; the count drops', () {
    final rs = RemoteSession(1, 'X')..setProfile(hideFloating);
    rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.floating)]));
    rs.showOnce(2);
    expect(rs.tabs.tabs.map((e) => e.id), [1, 2]);
    expect(rs.currentWindow, 2);
    expect(rs.hidden, isEmpty);
  });

  test('hiddenFocused when A focuses a hidden window', () {
    final rs = RemoteSession(1, 'X')..setProfile(hideFloating);
    rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.floating, focused: true)]));
    expect(rs.hiddenFocused, isTrue);
  });

  test('composer: off for the app, or for a noComposer tab, back on another tab; the draft stays', () {
    final rs = RemoteSession(1, 'X')
      ..setProfile(const ResolvedProfile(name: 'X', windows: [WindowRule(kind: WindowKind.dialog, action: RuleAction.noComposer)]));
    rs.apply(WindowsEvent(1, [w(1)]));
    rs.apply(WindowsEvent(1, [w(1), w(2, kind: WindowKind.dialog)])); // 2 is new: current
    final ed = FakeEditor();
    rs.composer.attach(ed);
    ed.value = '草稿';
    rs.composer.open = true;
    expect(rs.composerAllowed, isFalse);
    rs.selectWindow(1);
    expect(rs.composerAllowed, isTrue);
    expect(rs.composer.open, isTrue);
    expect(ed.value, '草稿');
    rs.setProfile(const ResolvedProfile(name: 'X', composer: false));
    expect(rs.composerAllowed, isFalse);
  });

  test('afterSend return calls onReturn after a full round; none does not', () async {
    var n = 0;
    final rs = RemoteSession(1, 'X', onReturn: () => n++)..setProfile(const ResolvedProfile(name: 'X', afterSend: AfterSend.pressReturn));
    final ed = FakeEditor();
    rs.composer.attach(ed);
    ed.value = 'go';
    await rs.composer.submit();
    rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
    expect(n, 1);
    rs.setProfile(const ResolvedProfile(name: 'X', afterSend: AfterSend.none));
    ed.value = 'go';
    await rs.composer.submit();
    rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
    expect(n, 1);
  });

  test('compose_key opens the panel and asks for a replay', () {
    final rs = RemoteSession(1, 'x');
    final tick = rs.composer.focusTick;
    rs.apply(const ComposeKeyEvent(1));
    expect(rs.composer.open, isTrue);
    expect(rs.composer.focusTick, tick + 1);
    expect(rs.composer.takeReplay(), isTrue);
    expect(rs.composer.takeReplay(), isFalse);
  });

  test('compose_key tells onComposeKey before the panel opens, and not when it is refused', () {
    final openAtCall = <bool>[];
    late final RemoteSession rs;
    rs = RemoteSession(1, 'x', onComposeKey: () => openAtCall.add(rs.composer.open));
    rs.apply(const ComposeKeyEvent(1));
    expect(openAtCall, [false]);
    rs.composer.open = false;
    rs.setProfile(const ResolvedProfile(name: 'X', composer: false));
    rs.apply(const ComposeKeyEvent(1));
    expect(openAtCall, [false]);
  });

  test('compose_key does nothing when the panel is not allowed (the tab just became noComposer)', () {
    final rs = RemoteSession(1, 'x');
    rs.setProfile(const ResolvedProfile(name: 'X', composer: false));
    rs.apply(const ComposeKeyEvent(1));
    expect(rs.composer.open, isFalse);
    expect(rs.composer.takeReplay(), isFalse);
  });

  group('a letter-opened panel closed unused turns letters off, until the user opens it', () {
    late RemoteSession rs;
    late FakeEditor ed;
    var now = DateTime(2026, 11, 16, 10);
    setUp(() {
      now = DateTime(2026, 11, 16, 10);
      rs = RemoteSession(1, 'x', clock: () => now);
      ed = FakeEditor();
      rs.composer.attach(ed);
    });

    Future<void> close() async {
      rs.composer.collapse();
      await rs.composer.detach(ed); // the panel going away brings its text into the draft
    }

    test('closed at once with only the captured letter: off, and the letter is dropped', () async {
      rs.apply(const ComposeKeyEvent(1));
      ed.value = 'i';
      await close();
      expect(rs.composeArmed, isFalse);
      expect(rs.composer.draft, isEmpty);
      // A stale compose_key does not reopen it.
      rs.apply(const ComposeKeyEvent(1));
      expect(rs.composer.open, isFalse);
    });

    test('after a quick close with a short ASCII text: off', () async {
      rs.apply(const ComposeKeyEvent(1));
      ed.value = 'ls';
      now = now.add(const Duration(seconds: 2));
      await close();
      expect(rs.composeArmed, isFalse);
    });

    test('a slow close with no more than the held letters is unused too: off', () async {
      rs.apply(const ComposeKeyEvent(1));
      ed.value = 'ls';
      now = now.add(const Duration(seconds: 20)); // looked at the panel a while, typed nothing
      await close();
      expect(rs.composeArmed, isFalse);
      expect(rs.composer.draft, isEmpty);
    });

    test('a long stay with ASCII text, or any non-ASCII text, is composing: stays on', () async {
      rs.apply(const ComposeKeyEvent(1));
      ed.value = 'hello';
      now = now.add(const Duration(seconds: 10));
      await close();
      expect(rs.composeArmed, isTrue);
      expect(rs.composer.draft, 'hello');
      rs.composer.attach(ed); // the next panel's editor
      rs.apply(const ComposeKeyEvent(1));
      ed.value = '你好';
      await close();
      expect(rs.composeArmed, isTrue);
      expect(rs.composer.draft, '你好');
    });

    test('a send keeps it on, the 直接回车且隐藏 collapse after it too', () async {
      rs.apply(const ComposeKeyEvent(1));
      ed.value = 'ls';
      await rs.composer.submit();
      await close();
      expect(rs.composeArmed, isTrue);
    });

    test('the user opening the panel (not a letter) turns letters on again', () async {
      rs.apply(const ComposeKeyEvent(1));
      await close();
      expect(rs.composeArmed, isFalse);
      rs.composer.open = true; // the button, Ctrl+Enter, a clip's 「插入」
      expect(rs.composeArmed, isTrue);
      expect(rs.composer.openedByLetter, isFalse);
    });

    test('a panel the user opened and closed empty does not turn letters off', () async {
      rs.composer.open = true;
      await close();
      expect(rs.composeArmed, isTrue);
    });
  });

  test('a compose replay not taken before the panel closes is gone', () {
    final rs = RemoteSession(1, 'x');
    rs.apply(const ComposeKeyEvent(1));
    rs.composer.open = false; // closed before its field took the caret
    rs.composer.open = true; // a later open by the button must not replay
    expect(rs.composer.takeReplay(), isFalse);
  });

  group('input source and the marked text box', () {
    late List<String> log;
    RemoteSession session() {
      log = [];
      return RemoteSession(1, 'x',
          onSelectInput: (id) => log.add('select:$id'),
          onClick: (win, at) => log.add('click:$win@${at.dx},${at.dy}'),
          onReturn: () => log.add('return'));
    }

    test('an older host (no input_source yet) gets no select_input', () {
      final r = session();
      r.selectInput('');
      r.prepareInput();
      r.pressReturn();
      expect(log, ['return']);
    });

    test('input_source is kept, and the last input method is remembered', () {
      final r = session();
      r.apply(const InputSourceEvent(1, 'com.apple.inputmethod.SCIM.ITABC', '拼音', false));
      expect(r.inputSource?.name, '拼音');
      expect(r.lastInputMethod?.id, 'com.apple.inputmethod.SCIM.ITABC');
      r.apply(const InputSourceEvent(1, 'com.apple.keylayout.ABC', 'ABC', true));
      expect(r.inputSource?.ascii, true);
      expect(r.lastInputMethod?.name, '拼音');
    });

    test('before sending, a non-English source is switched to English', () {
      final r = session();
      r.apply(const InputSourceEvent(1, 'im', '拼音', false));
      r.prepareInput();
      expect(log, ['select:']);
      log.clear();
      r.apply(const InputSourceEvent(1, 'abc', 'ABC', true));
      r.prepareInput();
      expect(log, isEmpty);
    });

    test('opening the panel switches A to English, once per opening', () {
      final r = session();
      r.apply(const InputSourceEvent(1, 'im', '拼音', false));
      r.composer.open = true;
      expect(log, ['select:']);
      r.composer.open = true;
      r.composer.wantFocus();
      expect(log, ['select:']);
      r.composer.open = false;
      r.composer.open = true;
      expect(log, ['select:', 'select:']);
    });

    test('opening the panel: already English, no call', () {
      final r = session();
      r.apply(const InputSourceEvent(1, 'abc', 'ABC', true));
      r.composer.open = true;
      expect(log, isEmpty);
    });

    test('opening the panel: no source reported, no call', () {
      final r = session();
      r.composer.open = true;
      expect(log, isEmpty);
    });

    test('an empty send: English first, then Return', () {
      final r = session();
      r.apply(const InputSourceEvent(1, 'im', '拼音', false));
      r.pressReturn();
      expect(log, ['select:', 'return']);
    });

    test('the marked point is clicked in the main window, below its title bar', () {
      final r = session();
      r.apply(WindowsEvent(1, [w(5)])); // 100x100, title bar 28: content 100x72
      r.setProfile(const ResolvedProfile(input: InputPoint(0.5, 10, fromBottom: true)));
      expect(r.inputClick(), (window: 5, at: const Offset(50, 28 + 62)));
      r.prepareInput();
      expect(log, ['click:5@50.0,90.0']);
    });

    test('no click without a mark, or while another tab is current', () {
      final r = session();
      r.apply(WindowsEvent(1, [w(5), w(6)]));
      expect(r.inputClick(), isNull);
      r.setProfile(const ResolvedProfile(input: InputPoint(0.5, 10)));
      expect(r.inputClick()?.window, 5);
      r.selectWindow(6);
      expect(r.inputClick(), isNull);
    });
  });

  test('InputPoint keeps the distance to the nearer edge', () {
    const size = Size(200, 100);
    final top = InputPoint.at(const Offset(50, 20), size);
    expect((top.x, top.dy, top.fromBottom), (0.25, 20.0, false));
    final bottom = InputPoint.at(const Offset(150, 90), size);
    expect((bottom.x, bottom.dy, bottom.fromBottom), (0.75, 10.0, true));
    // A taller window keeps a bottom box at the bottom.
    expect(bottom.inContent(const Size(400, 300)), const Offset(300, 290));
    expect(InputPoint.fromJson(bottom.toJson())?.dy, 10);
  });
}
