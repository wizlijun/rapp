// The system's body text size: every piece of rApp text uses it (the big dashboard numbers aside).
import 'dart:io';

import 'package:flutter/services.dart';

/// Used where the system says nothing (tests, Windows, a failed read).
const fallbackTextSize = 15.0;

/// The system's standard text size, in logical pixels: macOS NSFont.systemFontSize (13), Linux the
/// size in GNOME's `font-name` (points at 96 dpi). The system's own text scaling (Linux
/// text-scaling-factor, accessibility) is applied on top by Flutter, as before.
Future<double> systemTextSize({MethodChannel channel = const MethodChannel('rapp/system')}) async {
  try {
    if (Platform.isMacOS) {
      final v = await channel.invokeMethod<double>('fontSize');
      if (v != null) return clampTextSize(v);
    } else if (Platform.isLinux) {
      final r = await Process.run('gsettings', ['get', 'org.gnome.desktop.interface', 'font-name']);
      final pt = r.exitCode == 0 ? gnomeFontPoints('${r.stdout}') : null;
      if (pt != null) return clampTextSize(pt * 96 / 72);
    }
  } catch (_) {}
  return fallbackTextSize;
}

/// The point size at the end of a GNOME font name such as `'Cantarell 11'`, or null.
double? gnomeFontPoints(String s) {
  final m = RegExp(r"(\d+(?:\.\d+)?)\s*'?\s*$").firstMatch(s.trim());
  return m == null ? null : double.tryParse(m.group(1)!);
}

/// Keeps an odd system setting from breaking fixed-height rows.
double clampTextSize(double v) => v.isFinite ? v.clamp(11.0, 20.0).toDouble() : fallbackTextSize;
