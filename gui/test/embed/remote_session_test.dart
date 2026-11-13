import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_choice.dart';

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
    rs.composer.text = '草稿';
    rs.composer.open = true;
    expect(rs.composerAllowed, isFalse);
    rs.selectWindow(1);
    expect(rs.composerAllowed, isTrue);
    expect(rs.composer.open, isTrue);
    expect(rs.composer.text, '草稿');
    rs.setProfile(const ResolvedProfile(name: 'X', composer: false));
    expect(rs.composerAllowed, isFalse);
  });

  test('afterSend return calls onReturn after a full round; none does not', () {
    var n = 0;
    final rs = RemoteSession(1, 'X', onReturn: () => n++)..setProfile(const ResolvedProfile(name: 'X', afterSend: AfterSend.pressReturn));
    rs.composer.text = 'go';
    rs.composer.send();
    rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
    expect(n, 1);
    rs.setProfile(ResolvedProfile.generic);
    rs.composer.text = 'go';
    rs.composer.send();
    rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
    expect(n, 1);
  });
}
