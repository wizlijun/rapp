/// Swaps the Pad shell and the phone shell on one shared [MainState] (V1b, F1, F5, F9 to F14).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../ui/fullscreen.dart' show foldedShortSide;
import '../ui/main_state.dart';
import 'landing.dart';

enum UiForm { pad, phone }

UiForm formOf(Size s) => s.shortestSide < foldedShortSide ? UiForm.phone : UiForm.pad;

/// Tentative 250 ms; not under 100 ms (back on the Pad it adds the ResizePolicy's 300 ms, F11 wants 400).
const phoneFormSettle = Duration(milliseconds: 250);

class FormSwitch extends StatefulWidget {
  const FormSwitch({
    super.key,
    required this.state,
    required this.pad,
    required this.phone,
    this.settle = phoneFormSettle,
    this.onFold,
    this.entered,
    this.waiting,
    this.isWaiting,
  }) : assert(settle >= const Duration(milliseconds: 100), 'F11: back on the Pad the settle adds to the 300 ms policy');

  final MainState state;
  final WidgetBuilder pad, phone;
  final Duration settle;

  /// Called with where the phone form starts, when switching to it (the phone's navigation takes it).
  final void Function(({PhoneScreen screen, String? cameFrom}) landing)? onFold;

  /// The session entered on the phone; read when switching back to the Pad.
  final String? Function()? entered;

  /// How many things wait for the user, and whether the session [key] is one of them; both read when folding.
  final int Function()? waiting;
  final bool Function(String key)? isWaiting;

  @override
  State<FormSwitch> createState() => _FormSwitchState();
}

class _FormSwitchState extends State<FormSwitch> with WidgetsBindingObserver {
  UiForm? _form;
  Size? _size;
  Timer? _timer;
  PadSpot _spot = const PadSpot(overview: false, key: null);

  /// A window size reported while the app is not resumed can be a transitional one (R2): never acted on.
  bool get _resumed {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    if (_form == null) {
      // The first frame takes the form at once.
      _size = size;
      _form = formOf(size);
      // Its side effects wait for the frame to end: listeners of MainState rebuild above this widget (F13).
      if (_form == UiForm.phone) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _form == UiForm.phone) _fold();
        });
      }
      return;
    }
    if (size == _size) return;
    _size = size;
    _judge();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _judge();
    } else {
      _timer?.cancel();
    }
  }

  /// Starts (or restarts) the settle timer when the size's form differs; a size back on this side cancels it.
  void _judge() {
    _timer?.cancel();
    if (!_resumed || formOf(_size!) == _form) return;
    _timer = Timer(widget.settle, _settled);
  }

  void _settled() {
    if (!mounted || !_resumed) return;
    final target = formOf(_size!);
    if (target == _form) return;
    if (target == UiForm.phone) {
      _fold(closeMenus: true);
    } else {
      _unfold();
    }
    setState(() => _form = target);
  }

  void _fold({bool closeMenus = false}) {
    final s = widget.state;
    final inSession = !s.overview && s.currentKey != null;
    _spot = PadSpot(overview: s.overview, key: s.currentKey);
    // Menus and dialogs of the Pad form do not come back (F13).
    if (closeMenus) Navigator.maybeOf(context, rootNavigator: true)?.popUntil((r) => r.isFirst);
    final key = _spot.key;
    final landing = foldLanding(
      spot: _spot,
      padInSession: inSession,
      waiting: widget.waiting?.call() ?? 0,
      cameFromIsWaiting: key != null && (widget.isWaiting?.call(key) ?? false),
    );
    s.setPhone(form: true, inSession: landing.screen == PhoneScreen.session);
    widget.onFold?.call(landing);
  }

  void _unfold() {
    final s = widget.state;
    final spot = unfoldLanding(spot: _spot, phoneEntered: widget.entered?.call());
    // The Pad's stage size goes through the policy after the old one was judged once, so at most one resize goes out.
    s.setPhone(form: false);
    final key = spot.key;
    if (spot.overview) {
      if (!s.overview) s.toggleOverview();
    } else if (key != null && s.entries.any((e) => e.key == key)) {
      s.select(key);
    }
  }

  @override
  Widget build(BuildContext context) => _form == UiForm.phone ? widget.phone(context) : widget.pad(context);
}
