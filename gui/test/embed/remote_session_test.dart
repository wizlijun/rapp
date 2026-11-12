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
}
