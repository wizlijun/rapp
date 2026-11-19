// The macOS Dock menu and the quit gate over `rapp/dock` (native side: macos/Runner/DockMenu.swift).
// Dart → native: setMenu(payload), confirmQuit. Native → Dart: click(key), quitRequested.
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';

/// [items] as the native side builds them: `{separator: true}` or `{key, label, disabled}`.
List<Map<String, Object?>> dockPayload(List<MenuItem> items) => [
      for (final i in items)
        if (i.type == 'separator') {'separator': true} else {'key': i.key, 'label': i.label, 'disabled': i.disabled},
    ];

class DockChannel {
  DockChannel({
    required void Function(String key) onClick,
    required Future<void> Function() onQuitRequested,
    MethodChannel channel = const MethodChannel('rapp/dock'),
  }) : _channel = channel {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'click':
          onClick(call.arguments as String);
        case 'quitRequested':
          await onQuitRequested();
        default:
          throw MissingPluginException(call.method);
      }
    });
  }

  final MethodChannel _channel;

  /// What the Dock menu shows from now on.
  Future<void> setMenu(List<MenuItem> items) => _channel.invokeMethod<void>('setMenu', dockPayload(items));

  /// The quit was confirmed: the native side lets it through and terminates.
  Future<void> confirmQuit() => _channel.invokeMethod<void>('confirmQuit');
}
