// What this platform has: a service process, a tray, window management, detachable windows, online updates, the
// port panel, and how folders and links open. The call sites that differ on iOS ask here, not `Platform.isXxx`.
import 'dart:io';

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
