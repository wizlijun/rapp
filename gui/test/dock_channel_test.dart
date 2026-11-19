import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/dock_channel.dart';
import 'package:tray_manager/tray_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/dock');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// What the native side would send: a call on [channel].
  Future<void> fromNative(String method, [Object? args]) async {
    await messenger.handlePlatformMessage(
        channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)), (_) {});
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('dockPayload: separators and items with key, label, disabled', () {
    final p = dockPayload(
        [MenuItem(label: '常用', disabled: true), MenuItem.separator(), MenuItem(key: 'fav:2/X', label: '    X')]);
    expect(p, [
      {'key': null, 'label': '常用', 'disabled': true},
      {'separator': true},
      {'key': 'fav:2/X', 'label': '    X', 'disabled': false},
    ]);
  });

  test('setMenu sends the payload; confirmQuit asks the native side to quit', () async {
    final calls = <List<Object?>>[];
    messenger.setMockMethodCallHandler(channel, (c) async {
      calls.add([c.method, c.arguments]);
      return null;
    });
    final dock = DockChannel(onClick: (_) {}, onQuitRequested: () async {}, channel: channel);
    await dock.setMenu([MenuItem(key: 'session:1/a', label: '    a')]);
    await dock.confirmQuit();
    expect(calls, [
      [
        'setMenu',
        [
          {'key': 'session:1/a', 'label': '    a', 'disabled': false}
        ]
      ],
      ['confirmQuit', null],
    ]);
  });

  test('a native click reaches onClick with its key', () async {
    final clicked = <String>[];
    DockChannel(onClick: clicked.add, onQuitRequested: () async {}, channel: channel);
    await fromNative('click', 'session:1/a');
    expect(clicked, ['session:1/a']);
  });

  test('a native quitRequested runs onQuitRequested', () async {
    var asked = 0;
    DockChannel(onClick: (_) {}, onQuitRequested: () async => asked++, channel: channel);
    await fromNative('quitRequested');
    expect(asked, 1);
  });
}
