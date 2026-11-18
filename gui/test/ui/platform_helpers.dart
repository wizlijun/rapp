import 'package:flutter/foundation.dart';

/// Runs [body] with [defaultTargetPlatform] overridden to [p], and always resets the override.
Future<void> onPlatform(TargetPlatform p, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = p;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}
