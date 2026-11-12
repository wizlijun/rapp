import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';

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
}
