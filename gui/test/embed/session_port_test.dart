import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';

import '../fakes.dart';

Map<String, Object?> win({Object? kind = 'normal', Object? texture = 42}) => {
      'id': 7, 'parent': 0, 'kind': kind, 'title': 'Calc', 'x': 10, 'y': 20.5, 'w': 300, 'h': 200,
      'titleBar': 28, 'resizable': true, 'focused': false, 'texture': texture, 'visible': [0, 0, 1, 1],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses windows and ignores junk', () {
    final e = parseSessionEvent('windows', {'sid': 1, 'windows': [win()]});
    final w = (e as WindowsEvent).windows.single;
    expect(e.sid, 1);
    expect(w.texture, 42);
    expect(w.id, 7);
    expect(w.kind, WindowKind.normal);
    expect(w.decorated, isTrue);
    expect(w.rect, const Rect.fromLTWH(10, 20.5, 300, 200));
    expect(w.titleBar, 28);
    expect(w.visible, const Rect.fromLTWH(0, 0, 1, 1));
    expect(w.title, 'Calc');
    expect(w.resizable, isTrue);
    expect(w.focused, isFalse);
    expect(parseSessionEvent('windows', {'sid': 1, 'windows': 'x'}), isNull);
    expect(parseSessionEvent('windows', {'sid': 1, 'windows': [win(kind: 'blob')]}), isNull);
    expect(parseSessionEvent('windows', {'sid': 1, 'windows': [win(texture: 'x')]}), isNull);
    expect(parseSessionEvent('windows', {'windows': [win()]}), isNull);
    expect(parseSessionEvent('nope', {}), isNull);
    expect(parseSessionEvent('ready', 'x'), isNull);
  });

  test('a window without a texture has none', () {
    final e = parseSessionEvent('windows', {'sid': 1, 'windows': [win(kind: 'menu', texture: null)]}) as WindowsEvent;
    expect(e.windows.single.texture, isNull);
    expect(e.windows.single.decorated, isFalse);
  });

  test('closed carries the reason', () {
    final e = parseSessionEvent('closed', {'sid': 3, 'reason': 'quit'});
    expect((e as ClosedEvent).reason, 'quit');
    expect(e.sid, 3);
    expect(parseSessionEvent('closed', {'sid': 3}), isNull);
  });

  test('parses the other events', () {
    expect((parseSessionEvent('ready', {'sid': 1, 'appName': 'Calc'}) as ReadyEvent).appName, 'Calc');
    expect((parseSessionEvent('traffic', {'sid': 1, 'bytes': 2048}) as TrafficEvent).bytes, 2048);
    final clips = parseSessionEvent('clipboard', {
      'sid': 1,
      'clips': [
        {'id': 5, 'title': 'hi', 'pickable': false}
      ]
    }) as ClipsEvent;
    expect(clips.clips.single.id, 5);
    expect(clips.clips.single.title, 'hi');
    expect(clips.clips.single.pickable, isFalse);
    final menu = parseSessionEvent('menu', {
      'sid': 1,
      'items': [
        {
          'title': 'File', 'enabled': true, 'checked': false, 'separator': false, 'shortcut': '',
          'children': [
            {'title': 'New', 'enabled': true, 'checked': true, 'separator': false, 'shortcut': '⌘N', 'children': []},
          ],
        }
      ]
    }) as MenuEvent;
    expect(menu.items.single.title, 'File');
    expect(menu.items.single.shortcut, isNull);
    expect(menu.items.single.children.single.shortcut, '⌘N');
    expect(menu.items.single.children.single.checked, isTrue);
    expect(parseSessionEvent('menu', {'sid': 1, 'items': [{'title': 'File'}]}), isNull);

    final sending = parseSessionEvent('composer', {'sid': 1, 'sending': true}) as ComposerStateEvent;
    expect(sending.sending, isTrue);
    expect(sending.done, isNull);
    final done = parseSessionEvent('composer', {
      'sid': 1,
      'done': {'sent': 2, 'failure': null}
    }) as ComposerStateEvent;
    expect(done.done!.sent, 2);
    expect(done.done!.failure, isNull);
    expect(done.sending, isNull);
    expect(parseSessionEvent('composer', {'sid': 1}), isNull);

    final text = parseSessionEvent('composer_insert', {'sid': 1, 'text': 'hi'}) as ComposerInsertEvent;
    expect(text.insert.text, 'hi');
    final blocks = parseSessionEvent('composer_insert', {
      'sid': 1,
      'blocks': [
        {'n': 1, 'label': '[图片 #1 10×20]'}
      ]
    }) as ComposerInsertEvent;
    expect(blocks.insert.blocks.single.n, 1);
    expect(blocks.insert.blocks.single.label, '[图片 #1 10×20]');

    expect((parseSessionEvent('transfer', {'sid': 1, 'status': '1/2'}) as TransferEvent).status, '1/2');
    expect((parseSessionEvent('transfer', {'sid': 1, 'status': null}) as TransferEvent).status, isNull);
    final detached = parseSessionEvent('detached', {'sid': 1, 'detached': false, 'current': 7}) as DetachedEvent;
    expect(detached.detached, isFalse);
    expect(detached.current, 7);
    expect((parseSessionEvent('detached', {'sid': 1, 'detached': true}) as DetachedEvent).current, isNull);
  });

  test('the fake records the channel arguments and emits events', () async {
    final port = FakeSessionPort();
    expect(await port.init(), 500);
    await port.start(const StartArgs(1, 5000, 'tk', 'color16', 15, 'adaptive'));
    port.mouse(1, 7, 'down', 'left', 100, 78, 1);
    port.pictureFocus(null);
    port.close(1);
    expect(port.calls.map((c) => c.$1), ['init', 'start', 'mouse', 'picture_focus', 'close']);
    expect(port.calls[1].$2, {'sid': 1, 'port': 5000, 'token': 'tk', 'mode': 'color16', 'fps': 15, 'density': 'adaptive'});
    expect(port.calls[2].$2, {'sid': 1, 'window': 7, 'kind': 'down', 'button': 'left', 'x': 100.0, 'y': 78.0, 'clicks': 1});
    expect(port.calls[3].$2, {'sid': null});
    port.startError = 'boom';
    expect(port.start(const StartArgs(2, 5001, 't', 'color16', 15, 'adaptive')), throwsA(anything));
    final got = <SessionEvent>[];
    final sub = port.events.listen(got.add);
    port.emit(ClosedEvent(1, 'quit'));
    await Future<void>.delayed(Duration.zero);
    expect((got.single as ClosedEvent).reason, 'quit');
    await sub.cancel();
  });

  test('the channel port invokes rapp/session and turns calls into events', () async {
    const channel = MethodChannel('rapp/session');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'init') return {'doubleClickMs': 350};
      if (call.method == 'composer_paste') return {'blocks': [{'n': 2, 'label': 'b'}]};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final port = ChannelSessionPort();
    expect(await port.init(), 350);
    port.resize(1, 7, 800, 600);
    port.setStream(1, 'duogray', 1, 'adaptive');
    final pasted = await port.composerPaste(1);
    expect(pasted.blocks.single.n, 2);
    expect(calls.map((c) => c.method), ['init', 'resize', 'set_stream', 'composer_paste']);
    expect(calls[1].arguments, {'sid': 1, 'window': 7, 'w': 800, 'h': 600});

    final got = <SessionEvent>[];
    final sub = port.events.listen(got.add);
    await messenger.handlePlatformMessage('rapp/session',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('traffic', {'sid': 1, 'bytes': 10})), (_) {});
    await messenger.handlePlatformMessage('rapp/session',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('windows', {'sid': 1, 'windows': 'junk'})), (_) {});
    expect(got.length, 1);
    expect((got.single as TrafficEvent).bytes, 10);
    await sub.cancel();
  });
}
