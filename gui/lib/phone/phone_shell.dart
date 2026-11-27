/// The phone shell: the home, the session, devices and settings pages in one place (V1b Task 9).
library;

import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../paths.dart';
import '../platform_caps.dart';
import '../ui/access_setup.dart';
import '../ui/main_state.dart';
import '../ui/stage.dart' show UnlockAsks;
import 'devices_page.dart';
import 'form.dart';
import 'home_model.dart';
import 'home_screen.dart';
import 'landing.dart';
import 'phone_nav.dart';
import 'session_view.dart';
import 'settings_page.dart';

class PhoneShell extends StatefulWidget {
  const PhoneShell({super.key, required this.state, required this.nav, required this.data});
  final MainState state;

  /// Made by the holder of the [FormSwitch], so it lives as long as the app and survives a form swap.
  final PhoneNav nav;
  final DataDir data;

  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends State<PhoneShell> with UnlockAsks<PhoneShell> {
  MainState get _s => widget.state;

  /// The hub's last `access` (no service): null until it answered. Same as the Pad's.
  HubAccess? _access;

  @override
  void initState() {
    super.initState();
    listenUnlockAsks(_s);
    // Only a hub in this process owns the access; elsewhere the service does and the Pad's monitor reads it.
    if (caps.hubInProcess) {
      _s.hub?.addListener(_onAccess);
      _s.hub?.access().then((_) {}, onError: (_) {});
      // An answer already in: the first frame shows the right page, and the relay flag (it notifies MainState's
      // listeners, who may be building right now) is set after that frame.
      _access = _s.hub?.lastAccess;
      final a = _access;
      if (a != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _s.setRelaySet(a.hasKey);
        });
      }
    }
  }

  @override
  void dispose() {
    stopUnlockAsks();
    _s.hub?.removeListener(_onAccess);
    super.dispose();
  }

  void _onAccess() {
    final a = _s.hub?.lastAccess;
    if (a == null || a == _access || !mounted) return;
    setState(() => _access = a);
    _s.setRelaySet(a.hasKey);
  }

  void _onAccessDone(HubAccess a) {
    _onAccess();
    _s.refreshDevices();
  }

  bool get _needsAccess => caps.hubInProcess && _access?.hasKey == false;

  Widget _page(Widget child) => Scaffold(resizeToAvoidBottomInset: false, body: child);

  @override
  Widget build(BuildContext context) {
    if (_needsAccess && _s.hub != null) {
      return Scaffold(
        body: SafeArea(child: AccessSetup(key: const Key('access-setup'), hub: _s.hub!, onDone: _onAccessDone)),
      );
    }
    return ListenableBuilder(
      listenable: widget.nav,
      builder: (context, _) => switch (widget.nav.now) {
        // The pages hold InkWells and need a Material above them; the session view has its own Scaffold.
        PhoneView.home => _page(HomeScreen(state: _s, nav: widget.nav)),
        PhoneView.session => PhoneSessionView(state: _s, nav: widget.nav),
        PhoneView.devices => _page(DevicesPage(state: _s, nav: widget.nav)),
        PhoneView.settings => _page(SettingsPage(state: _s, nav: widget.nav)),
      },
    );
  }
}

/// The one way to wire a [FormSwitch] to the phone's [PhoneNav] and home model (Task 10 builds the app with it).
Widget phoneFormSwitch({
  required MainState state,
  required PhoneNav nav,
  required WidgetBuilder pad,
  required DataDir data,
  Duration settle = phoneFormSettle,
}) {
  // One build per fold: `waiting` and `isWaiting` read the same model; onFold drops it.
  HomeModel? memo;
  HomeModel model() => memo ??= phoneHomeModel(state, nav);
  return FormSwitch(
    state: state,
    settle: settle,
    pad: pad,
    phone: (_) => PhoneShell(state: state, nav: nav, data: data),
    onFold: (landing) {
      nav.entered = null; // an old phone visit must not beat where the Pad is now
      if (landing.screen == PhoneScreen.session) {
        final key = state.currentKey;
        if (key != null) nav.enter(key); // sets entered and the phone state; cameFrom is null for a session landing
      } else {
        nav.home();
      }
      nav.cameFrom = landing.cameFrom;
      memo = null;
    },
    // A session that ended on the phone is not a place to land.
    entered: () => state.entries.any((e) => e.key == nav.entered) ? nav.entered : null,
    waiting: () => model().items.where((i) => i.kind == HomeKind.waiting).length,
    isWaiting: (key) => model().items.any((i) => i.kind == HomeKind.waiting && i.sessionKey == key),
  );
}
