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
    final b = parseSessionEvent('input_blocked', {'sid': 3, 'by': 'Mac mini'}) as InputBlockedEvent;
    expect((b.sid, b.by), (3, 'Mac mini'));
    expect((parseSessionEvent('input_blocked', {'sid': 3}) as InputBlockedEvent).by, '');
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
    final status = parseSessionEvent('composer_insert', {'sid': 1, 'status': '不支持文件夹：dir'}) as ComposerInsertEvent;
    expect(status.insert.status, '不支持文件夹：dir');
    expect(parseSessionEvent('composer_insert', {'sid': 1}), isNull);

    expect((parseSessionEvent('transfer_status', {'sid': 1, 'status': '1/2'}) as TransferStatusEvent).status, '1/2');
    expect((parseSessionEvent('transfer_status', {'sid': 1, 'status': null}) as TransferStatusEvent).status, isNull);
    final detached = parseSessionEvent('detached', {'sid': 1, 'detached': false, 'current': 7}) as DetachedEvent;
    expect(detached.detached, isFalse);
    expect(detached.current, 7);
    expect((parseSessionEvent('detached', {'sid': 1, 'detached': true}) as DetachedEvent).current, isNull);
  });

  test('setHidden sends set_hidden with the ids', () async {
    final port = FakeSessionPort();
    port.setHidden(3, [7, 9]);
    await pumpEventQueue();
    expect(port.calls.last.$1, 'set_hidden');
    expect(port.calls.last.$2, {'sid': 3, 'windows': [7, 9]});
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
    port.setStream(1, 'duogray', 1, 'adaptive', pinned: true);
    final pasted = await port.composerPaste(1);
    expect(pasted.blocks.single.n, 2);
    expect(calls.map((c) => c.method), ['init', 'resize', 'set_stream', 'set_stream', 'composer_paste']);
    expect(calls[1].arguments, {'sid': 1, 'window': 7, 'w': 800, 'h': 600});
    expect(calls[2].arguments, {'sid': 1, 'mode': 'duogray', 'fps': 1, 'density': 'adaptive'});
    expect(calls[3].arguments, {'sid': 1, 'mode': 'duogray', 'fps': 1, 'density': 'adaptive', 'pinned': true});

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

  test('fire-and-forget calls swallow runner errors; start still throws', () async {
    const channel = MethodChannel('rapp/session');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'gone', message: 'no session');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final port = ChannelSessionPort();
    port.mouse(1, 7, 'down', 'left', 1, 2, 1);
    port.scroll(1, 7, 1, 2, 0, -3);
    port.pictureFocus(1);
    port.resize(1, 7, 800, 600);
    // An unhandled error from any of these would fail the test.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, ['mouse', 'scroll', 'picture_focus', 'resize']);
    await expectLater(port.start(const StartArgs(1, 5000, 'tk', 'color16', 15, 'adaptive')),
        throwsA(isA<PlatformException>()));
  });

  test('parses traffic frames and disconnected', () {
    expect((parseSessionEvent('traffic', {'sid': 1, 'bytes': 10, 'frames': 3}) as TrafficEvent).frames, 3);
    expect((parseSessionEvent('traffic', {'sid': 1, 'bytes': 10}) as TrafficEvent).frames, 0);
    expect((parseSessionEvent('disconnected', {'sid': 1, 'reason': 'connection closed'}) as DisconnectedEvent).reason,
        'connection closed');
    expect((parseSessionEvent('disconnected', {'sid': 1}) as DisconnectedEvent).reason, '');
  });

  test('clipboard rows carry kind', () {
    final e = parseSessionEvent('clipboard', {
      'sid': 1,
      'clips': [
        {'id': 1, 'title': 'a', 'pickable': true, 'kind': 'image'},
        {'id': 2, 'title': 'b', 'pickable': true},
        {'id': 3, 'title': 'c', 'pickable': false},
        {'id': 4, 'title': 'd', 'pickable': true, 'kind': 'weird'},
      ]
    }) as ClipsEvent;
    expect(e.clips.map((c) => c.kind), [ClipKind.image, ClipKind.text, ClipKind.unsupported, ClipKind.text]);
  });

  test('transfer progress parses', () {
    final e = parseSessionEvent('transfer', {
      'sid': 1, 'id': 3, 'dir': 'down', 'name': 'a.log', 'done': 10, 'total': 20, 'state': 'done', 'path': '/x/a.log'
    }) as TransferProgressEvent;
    expect((e.id, e.down, e.name, e.done, e.total, e.state, e.path, e.error),
        (3, true, 'a.log', 10, 20, TransferState.done, '/x/a.log', null));
    final up = parseSessionEvent('transfer', {
      'sid': 1, 'id': 4, 'dir': 'up', 'name': 'b', 'kind': 'files', 'done': 0, 'total': 1, 'state': 'failed', 'error': 'boom'
    }) as TransferProgressEvent;
    expect((up.down, up.state, up.error, up.kind), (false, TransferState.failed, 'boom', ClipKind.files));
    expect(e.kind, isNull);
    expect(
        parseSessionEvent('transfer',
            {'sid': 1, 'id': 3, 'dir': 'down', 'name': 'a', 'done': 1, 'total': 2, 'state': 'weird'}),
        isNull);
  });

  test('cancelTransfer without id sends no id', () {
    final port = FakeSessionPort();
    port.cancelTransfer(1);
    port.cancelTransfer(1, id: 3);
    final c = port.calls.where((c) => c.$1 == 'cancel_transfer').map((c) => c.$2).toList();
    expect(c, [
      {'sid': 1},
      {'sid': 1, 'id': 3}
    ]);
  });

  test('fetchClip returns copy or error', () async {
    final port = FakeSessionPort();
    port.fetchReply = {'copy': 7};
    expect((await port.fetchClip(1, 2)).copy, 7);
    port.fetchReply = {'error': 'unknown clip'};
    expect((await port.fetchClip(1, 2)).error, 'unknown clip');
    port.fetchReply = {'weird': 1};
    expect((await port.fetchClip(1, 2)).error, '没有连上 runner');
    port.fetchError = PlatformException(code: 'x');
    expect((await port.fetchClip(1, 2)).error, '没有连上 runner');
    expect(port.calls.first.$1, 'fetch_clip');
    expect(port.calls.first.$2, {'sid': 1, 'clip': 2});
  });

  test('copyLocal, dropCopy and reveal', () async {
    final port = FakeSessionPort();
    expect(await port.copyLocal(5), true);
    port.copyLocalReply = false;
    expect(await port.copyLocal(5), false);
    port.dropCopy(5);
    expect(await port.reveal('/x'), true);
    port.revealReply = false;
    expect(await port.reveal('/x'), false);
    await Future<void>.delayed(Duration.zero);
    expect(port.calls.map((c) => c.$1), ['copy_local', 'copy_local', 'drop_copy', 'reveal', 'reveal']);
    expect(port.calls[2].$2, {'copy': 5});
    expect(port.calls[3].$2, {'path': '/x'});
  });

  test('savePin and loadPin map the runner replies', () async {
    final port = _PinPort();
    port.reply = {'path': '/x/s.md'};
    expect(await port.savePin(3, textDir: '/t', fileDir: '/f', stem: 's'), '/x/s.md');
    expect(port.calls.single.$1, 'pin_save');
    expect(port.calls.single.$2, {'copy': 3, 'text_dir': '/t', 'file_dir': '/f', 'stem': 's'});
    port.reply = {'error': 'x'};
    expect(await port.savePin(3, textDir: '/t', fileDir: '/f', stem: 's'), isNull);
    port.reply = null;
    expect(await port.savePin(3, textDir: '/t', fileDir: '/f', stem: 's'), isNull);
    port.error = PlatformException(code: 'x');
    expect(await port.savePin(3, textDir: '/t', fileDir: '/f', stem: 's'), isNull);
    port.error = MissingPluginException();
    expect(await port.loadPin('/x/s.md'), isNull);
    port.error = null;
    port.reply = {'copy': 3, 'kind': 'files'};
    expect(await port.loadPin('/x/s'), (copy: 3, kind: ClipKind.files));
    expect(port.calls.last.$1, 'pin_load');
    expect(port.calls.last.$2, {'path': '/x/s'});
    port.reply = {'copy': 4, 'kind': 'weird'};
    expect(await port.loadPin('/x/s'), isNull);
    port.reply = null;
    expect(await port.loadPin('/x/s'), isNull);
  });
}

class _PinPort extends SessionPort {
  final calls = <(String, Map<String, Object?>)>[];
  Object? reply;
  Object? error;

  @override
  Stream<SessionEvent> get events => const Stream.empty();

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) async {
    calls.add((method, args));
    if (error != null) throw error!;
    return reply;
  }
}
