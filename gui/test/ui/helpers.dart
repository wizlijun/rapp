import 'package:flutter/material.dart';
import 'package:rapp/ui/tokens.dart';

/// Wraps [child] in a themed MaterialApp for widget tests.
Widget wrap(
  Widget child, {
  bool disableAnimations = false,
  RappTheme theme = RappTheme.matrix,
}) {
  return MaterialApp(
    theme: themeDataFor(theme),
    home: Scaffold(body: Center(child: child)),
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: c!,
    ),
  );
}
