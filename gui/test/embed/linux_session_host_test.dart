import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/linux_session_host.dart';
import 'package:rapp/paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LinuxSessionHost reads downloads and the trace dir from the environment', () {
    final h = LinuxSessionHost(env: {'RAPP_DOWNLOADS': '/d', 'RAPP_STREAM_TRACE_DIR': '/t'});
    expect(h.downloads(), '/d');
    expect(h.traceDir, '/t');
    final bare = LinuxSessionHost(env: {'RAPP_STREAM_TRACE_DIR': '', 'HOME': '/h'});
    expect(bare.traceDir, isNull);
    expect(bare.downloads(), '${dataRoot({'HOME': '/h'}, Platform.operatingSystem)}/files/transfers');
  });

  test('LinuxSessionHost falls back to Flutter text when the native clipboard is missing', () async {
    // rapp/linux 没有处理器 → MissingPluginException → 读 Flutter Clipboard 的文字
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData' ? {'text': 'hi'} : null);
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final copy = await LinuxSessionHost().readClipboard();
    expect(copy?.kind, 'text');
    expect(copy?.text, 'hi');
  });

  test('LinuxSessionHost without the native side has no detach', () async {
    final h = LinuxSessionHost();
    await h.init((_) async => null);
    expect(h.supportsDetach, isFalse);
    expect(h.supportsInlineNativeComposer, isTrue);
  });
}
