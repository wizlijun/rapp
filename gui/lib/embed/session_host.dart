import 'package:flutter/services.dart';

import 'session_copy.dart';

/// The platform pieces a session port cannot supply itself: clipboard, file picker, download
/// directory, reveal, trace directory and the native detached-window channel.
abstract class SessionHost {
  /// 端口 init 时调一次。分离窗口那一组的原生端从这里接上，它的来电交给 [onDetachCall]。
  /// 能力位（[supportsDetach]）在这之后才定。
  Future<void> init(Future<Object?> Function(MethodCall call) onDetachCall);
  String downloads(); // 传文件落盘目录
  Future<bool> reveal(String path); // 去看收到的文件
  Future<SessionCopy?> readClipboard();
  Future<bool> writeClipboard(SessionCopy copy);
  Future<List<String>> chooseFiles();
  String? get traceDir; // null：不追踪
  MethodChannel? get detachChannel; // 分离窗口那一组；null：没有
  bool get supportsInlineNativeComposer;
  bool get supportsDetach;
}
