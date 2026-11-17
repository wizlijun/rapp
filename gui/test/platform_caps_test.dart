import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/platform_caps.dart';

void main() {
  test('iOS runs the hub in process and has no service, tray, window manager or detach', () {
    final c = PlatformCaps.forOs('ios');
    expect(c.hubInProcess, isTrue);
    expect(c.systemOpen, isTrue);
    expect(c.hasService, isFalse);
    expect(c.hasTray, isFalse);
    expect(c.hasWindowManager, isFalse);
    expect(c.canDetach, isFalse);
    expect(c.onlineUpdate, isFalse);
    expect(c.showsPorts, isFalse);
  });

  test('macOS keeps the desktop set', () {
    final c = PlatformCaps.forOs('macos');
    expect(c.canDetach, isTrue);
    expect(c.showsPorts, isTrue);
    expect([c.hasService, c.hasTray, c.hasWindowManager, c.onlineUpdate], everyElement(isTrue));
    expect([c.hubInProcess, c.systemOpen], everyElement(isFalse));
  });

  test('Linux and Windows stay as they are', () {
    for (final os in ['linux', 'windows']) {
      final c = PlatformCaps.forOs(os);
      expect([c.hasService, c.hasTray, c.hasWindowManager, c.showsPorts, c.onlineUpdate], everyElement(isTrue), reason: os);
      expect([c.hubInProcess, c.systemOpen], everyElement(isFalse), reason: os);
    }
    expect(PlatformCaps.forOs('linux').canDetach, isTrue);
    expect(PlatformCaps.forOs('windows').canDetach, isFalse);
  });
}
