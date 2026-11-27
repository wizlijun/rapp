/// The phone shell: the home, the session, devices and settings pages in one place (V1b Task 9).
library;

import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../paths.dart';
import '../platform_caps.dart';
import '../ui/access_setup.dart';
import '../ui/main_state.dart';
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

class _PhoneShellState extends State<PhoneShell> {
  MainState get _s => widget.state;

  /// The hub's last `access` (no service): null until it answered. Same as the Pad's.
  HubAccess? _access;

  @override
  void initState() {
    super.initState();
    _s.hub?.addListener(_onAccess);
    _s.hub?.access().then((_) {}, onError: (_) {});
    _onAccess();
  }

  @override
  void dispose() {
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
        PhoneView.home => Scaffold(body: HomeScreen(state: _s, nav: widget.nav)),
        PhoneView.session => PhoneSessionView(state: _s, nav: widget.nav),
        PhoneView.devices => DevicesPage(state: _s, nav: widget.nav),
        PhoneView.settings => SettingsPage(state: _s, nav: widget.nav),
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
    },
    entered: () => nav.entered,
    waiting: () => phoneHomeModel(state, nav).items.where((i) => i.kind == HomeKind.waiting).length,
    isWaiting: (key) => phoneHomeModel(state, nav).items.any((i) => i.kind == HomeKind.waiting && i.sessionKey == key),
  );
}
