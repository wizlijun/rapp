import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/geometry.dart';
import 'package:rapp/embed/session_port.dart';

RemoteWindow w(double width, double height, {double titleBar = 28}) => RemoteWindow(
      id: 1,
      parent: 0,
      kind: WindowKind.normal,
      title: 't',
      rect: Rect.fromLTWH(0, 0, width, height),
      titleBar: titleBar,
      resizable: true,
      focused: true,
      texture: 42,
      visible: const Rect.fromLTWH(0, 0, 1, 1),
    );

void main() {
  test('fitRect letterboxes', () {
    expect(fitRect(const Size(200, 100), const Size(400, 400)), const Rect.fromLTWH(0, 100, 400, 200));
  });

  test('fitRect of an empty side is zero', () {
    expect(fitRect(const Size(0, 100), const Size(400, 400)), Rect.zero);
    expect(fitRect(const Size(100, 100), const Size(400, -1)), Rect.zero);
  });

  test('toRemote adds the title bar', () {
    final p = toRemote(const Offset(200, 200), const Rect.fromLTWH(0, 100, 400, 200), w(200, 128));
    expect(p, const Offset(100, 78));
  });

  test('pictureRect places the visible part', () {
    expect(
      pictureRect(const Rect.fromLTWH(0, 100, 400, 200), const Rect.fromLTWH(0, 0, 1, .5)),
      const Rect.fromLTWH(0, 100, 400, 100),
    );
  });

  test('contentSize drops the title bar', () {
    expect(contentSize(w(200, 128)), const Size(200, 100));
  });
}
