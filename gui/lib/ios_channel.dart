// The `rapp/ios` channel (gui/ios/Runner/IosPlugin.swift): paths, device facts, the network, background time,
// the share sheet and links. Native-to-Dart events arrive as method calls (`memoryWarning`, `pathChanged`).
import 'dart:async';

import 'package:flutter/services.dart';

/// The app's folders: `support` is Application Support (not backed up), `documents` is what the Files app shows.
class IosPaths {
  const IosPaths(this.support, this.documents);
  final String support, documents;

  /// rapp's data root.
  String get dataRoot => '$support/rapp';
}

/// The answer of `net`: whether one system HTTP request got through (China-region devices: the 无线数据 prompt).
class IosNet {
  const IosNet({required this.ok, this.status = 0, this.error = ''});
  final bool ok;
  final int status;
  final String error;

  /// Nothing can get out (NSURLErrorNotConnectedToInternet, what the 无线数据 refusal gives): the app waits. A
  /// timeout or an HTTP error is not this; the hub then tries on its own.
  bool get blocked => !ok && error.contains('Code=-1009');
}

class IosChannel {
  IosChannel([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('rapp/ios');

  final MethodChannel _channel;
  StreamController<String>? _events;

  Future<IosPaths> paths() async {
    final m = await _channel.invokeMapMethod<String, Object?>('paths') ?? const {};
    return IosPaths('${m['support'] ?? ''}', '${m['documents'] ?? ''}');
  }

  Future<String> deviceName() async => await _channel.invokeMethod<String>('deviceName') ?? '';

  /// CFBundleShortVersionString.
  Future<String> version() async => await _channel.invokeMethod<String>('version') ?? '';

  Future<IosNet> net() async {
    final m = await _channel.invokeMapMethod<String, Object?>('net') ?? const {};
    final status = m['status'];
    return IosNet(ok: m['ok'] == true, status: status is int ? status : 0, error: '${m['error'] ?? ''}');
  }

  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');
  Future<void> keepAwake(bool on) => _channel.invokeMethod<void>('keepAwake', {'on': on});
  Future<void> sessionActive(bool on) => _channel.invokeMethod<void>('sessionActive', {'on': on});

  /// The status bar hidden and the home indicator fading out (RappViewController.fullscreen).
  Future<void> fullscreen(bool on) => _channel.invokeMethod<void>('fullscreen', {'on': on});
  Future<void> beginBackground() => _channel.invokeMethod<void>('beginBackground');
  Future<void> endBackground() => _channel.invokeMethod<void>('endBackground');

  /// The share sheet for [path] (a file or a folder).
  Future<void> share(String path) => _channel.invokeMethod<void>('share', {'path': path});
  Future<void> openUrl(String url) => _channel.invokeMethod<void>('openUrl', {'url': url});

  /// `memoryWarning` and `pathChanged`, as the runner calls them.
  Stream<String> get events {
    var c = _events;
    if (c == null) {
      final made = c = _events = StreamController<String>.broadcast();
      _channel.setMethodCallHandler((call) async {
        made.add(call.method);
        return null;
      });
    }
    return c.stream;
  }
}

/// The app's one channel object.
final iosChannel = IosChannel();
