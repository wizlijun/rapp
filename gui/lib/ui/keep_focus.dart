import 'package:flutter/widgets.dart';

/// Keys an app window's picture (or a terminal) lets through stay off Flutter's focus walk: Tab
/// and the arrows never move the keyboard focus onto the top bar's buttons, where its highlight
/// would flash. They still reach the window's own shortcuts on the way up, and then the platform.
class KeepFocus extends StatelessWidget {
  const KeepFocus({super.key, required this.child});

  final Widget child;

  static final _stay = DoNothingAction(consumesKey: false);

  @override
  Widget build(BuildContext context) => Actions(
        actions: {
          NextFocusIntent: _stay,
          PreviousFocusIntent: _stay,
          DirectionalFocusIntent: _stay,
        },
        child: child,
      );
}
