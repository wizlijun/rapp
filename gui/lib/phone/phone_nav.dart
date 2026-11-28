/// Where the phone shell is. Leaving home (enter, open) clears [cameFrom]; the fold sets it after.
library;

import 'package:flutter/foundation.dart';

import '../ui/main_state.dart';
import 'assistant_store.dart';
import 'replies.dart';

enum PhoneView { home, session, devices, settings, assistant }

class PhoneNav extends ChangeNotifier {
  /// [send]: a test hook for the replies' sender; null sends through the hub.
  PhoneNav(this.state, {ReplySender? send}) : _send = send; // ignore: prefer_initializing_formals
  final ReplySender? _send;
  final MainState state;

  /// The replies sent from phone cards, and their outcome words (they outlive a form switch).
  late final PhoneReplies replies = PhoneReplies(state, send: _send);

  /// The notes of the 助理, on this phone only. One per nav, so they outlive a form switch.
  late final AssistantStore assistant = AssistantStore(state.data.localDir);

  /// Words 「编辑」 puts in the input of the 助理 page; the page takes them when it opens.
  String? assistantDraft;

  PhoneView _now = PhoneView.home;
  PhoneView get now => _now;

  String? cameFrom;
  String? entered;
  final Set<String> gotIt = {};

  /// Words for the draft of the session the user is about to go into (a spoken reply they chose to 编辑).
  ({String key, String text})? pendingDraft;

  /// Into a session ("会话里面").
  void enter(String key) {
    state.select(key);
    state.setPhone(form: true, inSession: true);
    final d = pendingDraft;
    pendingDraft = null;
    final rs = state.currentRemote;
    if (d != null && d.key == key && rs != null) {
      rs.composer.keep(d.text);
      rs.composer.open = true;
    }
    entered = key;
    cameFrom = null;
    _now = PhoneView.session;
    notifyListeners();
  }

  void home() {
    pendingDraft = null;
    assistantDraft = null;
    state.setPhone(form: true, inSession: false);
    cameFrom = null;
    _now = PhoneView.home;
    notifyListeners();
  }

  /// The devices or the settings page.
  void open(PhoneView v) {
    pendingDraft = null;
    cameFrom = null;
    _now = v;
    notifyListeners();
  }
}
