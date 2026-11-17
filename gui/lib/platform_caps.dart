// What this platform has: a service process, a tray, window management, detachable windows, online updates, the
// port panel, and how folders and links open. The call sites that differ on iOS ask here, not `Platform.isXxx`.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlatformCaps {
  const PlatformCaps({
    this.hubInProcess = false,
    this.hasService = false,
    this.hasTray = false,
    this.hasWindowManager = false,
    this.canDetach = false,
    this.onlineUpdate = false,
    this.showsPorts = false,
    this.systemOpen = false,
  });

  /// The hub runs inside the app over dart:ffi (iOS), not as the `rapp-hub` child process.
  final bool hubInProcess;

  /// A `rapp-service` runs beside the GUI (its status, password, relay and key live there).
  final bool hasService;
  final bool hasTray;
  final bool hasWindowManager;

  /// A session's window can leave the main window.
  final bool canDetach;

  /// The service's 版本与升级 (UpdateSection).
  final bool onlineUpdate;

  /// The port-sharing panels.
  final bool showsPorts;

  /// Folders and links open through the system API (`rapp/ios`), not a child process.
  final bool systemOpen;

  static PlatformCaps forOs(String os) => switch (os) {
        'ios' => const PlatformCaps(hubInProcess: true, systemOpen: true),
        'windows' => const PlatformCaps(
            hasService: true, hasTray: true, hasWindowManager: true, onlineUpdate: true, showsPorts: true),
        // macOS, Linux (and anything else desktop): everything the desktop has.
        _ => const PlatformCaps(
            hasService: true,
            hasTray: true,
            hasWindowManager: true,
            canDetach: true,
            onlineUpdate: true,
            showsPorts: true),
      };
}

/// This platform's capabilities; tests may replace it.
PlatformCaps caps = PlatformCaps.forOs(Platform.operatingSystem);

/// When the last hardware key event arrived (iOS: a keyboard is attached); null for never.
DateTime? lastHardwareKey;

/// A key event this long ago still means a hardware keyboard is there.
const hardwareKeyFresh = Duration(seconds: 10);

bool _onHardwareKey(KeyEvent _) {
  lastHardwareKey = DateTime.now();
  return false; // only watching: the event goes on
}

/// Keeps [lastHardwareKey] current; once is enough, again is harmless.
void watchHardwareKeys() {
  HardwareKeyboard.instance
    ..removeHandler(_onHardwareKey)
    ..addHandler(_onHardwareKey);
}

/// A hardware keyboard is there: always on macOS, Linux and Windows; on iOS a key is down now or a key event came in
/// the last [hardwareKeyFresh] ([lastHardwareKey]). Without one the writing panel's Return is a newline (spec §8.4).
bool hardwareKeyboard({DateTime? now}) {
  if (defaultTargetPlatform != TargetPlatform.iOS) return true;
  watchHardwareKeys();
  if (HardwareKeyboard.instance.physicalKeysPressed.isNotEmpty) return true;
  final last = lastHardwareKey;
  return last != null && (now ?? DateTime.now()).difference(last) < hardwareKeyFresh;
}
