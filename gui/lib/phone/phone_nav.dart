/// Where the phone shell is. Leaving home (enter, open) clears [cameFrom]; the fold sets it after.
library;

import 'package:flutter/foundation.dart';

import '../ui/main_state.dart';
import 'replies.dart';

enum PhoneView { home, session, devices, settings }

class PhoneNav extends ChangeNotifier {
  PhoneNav(this.state);
  final MainState state;

  /// The replies sent from phone cards, and their outcome words (they outlive a form switch).
  late final PhoneReplies replies = PhoneReplies(state);

  PhoneView _now = PhoneView.home;
  PhoneView get now => _now;

  String? cameFrom;
  String? entered;
  final Set<String> gotIt = {};

  /// Into a session ("会话里面").
  void enter(String key) {
    state.select(key);
    state.setPhone(form: true, inSession: true);
    entered = key;
    cameFrom = null;
    _now = PhoneView.session;
    notifyListeners();
  }

  void home() {
    state.setPhone(form: true, inSession: false);
    cameFrom = null;
    _now = PhoneView.home;
    notifyListeners();
  }

  /// The devices or the settings page.
  void open(PhoneView v) {
    cameFrom = null;
    _now = v;
    notifyListeners();
  }
}
