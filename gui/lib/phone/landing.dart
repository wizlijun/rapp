/// Where each form lands when the window folds or unfolds (V1b, F6 to F8).
library;

/// Where the Pad form was: the overview wall, or the session [key].
class PadSpot {
  const PadSpot({required this.overview, required this.key});
  final bool overview;
  final String? key;
}

enum PhoneScreen { home, session }

/// Folding to the phone form. Anything waiting for the user goes first: the home page, with [cameFrom] the session
/// the Pad was in, unless that session is itself one of the waiting (it is on the home page already). Nothing
/// waiting and the Pad in a session: stay in it. The Pad in the overview: the home page.
({PhoneScreen screen, String? cameFrom}) foldLanding({
  required PadSpot spot,
  required bool padInSession,
  required int waiting,
  required bool cameFromIsWaiting,
}) {
  if (waiting > 0) {
    return (screen: PhoneScreen.home, cameFrom: padInSession && !cameFromIsWaiting ? spot.key : null);
  }
  if (padInSession) return (screen: PhoneScreen.session, cameFrom: null);
  return (screen: PhoneScreen.home, cameFrom: null);
}

/// Unfolding back to the Pad form. A session entered on the phone wins; else where the Pad was.
({bool overview, String? key}) unfoldLanding({required PadSpot spot, required String? phoneEntered}) =>
    phoneEntered != null ? (overview: false, key: phoneEntered) : (overview: spot.overview, key: spot.key);
