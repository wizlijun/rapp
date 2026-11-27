/// Where the phone shell is (V1b Task 7: the minimal version; Task 6 adds to it).
library;

import 'package:flutter/foundation.dart';

import '../ui/main_state.dart';

enum PhoneView { home, session, devices, settings }

class PhoneNav extends ChangeNotifier {
  PhoneNav(this.state);
  final MainState state;

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
    _now = v;
    notifyListeners();
  }
}
