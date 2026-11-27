import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/phone/landing.dart';

void main() {
  const inX = PadSpot(overview: false, key: 'X');
  const wall = PadSpot(overview: true, key: 'X');

  group('foldLanding', () {
    test('waiting things: home, and the session the Pad was in is remembered', () {
      final l = foldLanding(spot: inX, padInSession: true, waiting: 2, cameFromIsWaiting: false);
      expect(l, (screen: PhoneScreen.home, cameFrom: 'X'));
    });
    test('the session itself waits: home, nothing remembered', () {
      final l = foldLanding(spot: inX, padInSession: true, waiting: 2, cameFromIsWaiting: true);
      expect(l, (screen: PhoneScreen.home, cameFrom: null));
    });
    test('nothing waiting and the Pad in a session: stay in it', () {
      final l = foldLanding(spot: inX, padInSession: true, waiting: 0, cameFromIsWaiting: false);
      expect(l, (screen: PhoneScreen.session, cameFrom: null));
    });
    test('the Pad in the overview: home', () {
      expect(foldLanding(spot: wall, padInSession: false, waiting: 0, cameFromIsWaiting: false),
          (screen: PhoneScreen.home, cameFrom: null));
      expect(foldLanding(spot: wall, padInSession: false, waiting: 3, cameFromIsWaiting: false),
          (screen: PhoneScreen.home, cameFrom: null));
    });
  });

  group('unfoldLanding', () {
    test('a session entered on the phone wins', () {
      expect(unfoldLanding(spot: wall, phoneEntered: 'Y'), (overview: false, key: 'Y'));
    });
    test('none entered: back where the Pad was', () {
      expect(unfoldLanding(spot: wall, phoneEntered: null), (overview: true, key: 'X'));
      expect(unfoldLanding(spot: inX, phoneEntered: null), (overview: false, key: 'X'));
    });
  });
}
