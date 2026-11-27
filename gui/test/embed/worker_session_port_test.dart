import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/worker_session_port.dart';
import 'package:rapp/embed/linux_session_host.dart';
import 'package:rapp/embed/frame_sink.dart';
import 'package:rapp/embed/session_link.dart';
import 'package:rapp/embed/session_worker.dart';
import 'fake_session_link.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/session_protocol.dart';
import 'package:rapp/embed/voice_key_gate.dart';

Uint8List u32(int n) => (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
Uint8List u16(int n) => (ByteData(2)..setUint16(0, n, Endian.little)).buffer.asUint8List();
Uint8List f32(double n) => (ByteData(4)..setFloat32(0, n, Endian.little)).buffer.asUint8List();
List<int> string(String s) => [...u16(utf8.encode(s).length), ...utf8.encode(s)];
List<int> packet(int type, List<int> bytes) => [type, ...u32(bytes.length), ...bytes];
const full = [120,156,98,100,0,129,31,0,0,0,0,255,255];
const delta = [98,4,145,15,216,1,0,0,0,255,255];
List<int> frame(bool first) => packet(4, [2, ...f32(0), ...f32(0), ...f32(4), ...f32(4),
    ...u16(4), ...u16(4), first ? 7 : 6, if (!first) ...[...u32(0), ...u32(0)], ...(first ? full : delta)]);

Future<SessionEvent> nextWhere(StreamIterator<SessionEvent> it, bool Function(SessionEvent) match) async {
  while (await it.moveNext().timeout(const Duration(seconds: 8))) {
    if (match(it.current)) return it.current;
  }
  throw StateError('event stream ended');
}

/// A pipe frame packet: 2×2 canvas covering (0,0)–(2,2), white BGRA.
List<int> frame2x2() => [1, ...u32(2), ...u32(2), ...f32(0), ...f32(0), ...f32(2), ...f32(2), ...List.filled(16, 255)];

/// A pipe event packet: one 2×2 window at the origin, no title bar.
List<int> windowsEvent() => [0, ...utf8.encode(jsonEncode({
  'event': 'windows',
  'windows': [
    {'id': 1, 'parent': 0, 'kind': 'normal', 'title': 't', 'x': 0, 'y': 0, 'w': 2, 'h': 2,
     'titleBar': 0, 'resizable': true, 'focused': true, 'texture': null, 'visible': [0, 0, 1, 1]},
  ],
}))];

Future<void> until(bool Function() ok) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Decodes like [ImageFrameSink] but only after the test opens the gate.
class GatedSink implements FrameSink {
  final gate = Completer<void>();
  final _real = const ImageFrameSink();
  int decodes = 0;
  @override
  Future<ui.Image> decode(Uint8List bgra, int width, int height) async {
    decodes++;
    await gate.future;
    return _real.decode(bgra, width, height);
  }

  @override
  void retire(ui.Image? image) => _real.retire(image);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  englishFirstTests();
  test('every frame packet is acked once, dropped ones too', () async {
    final link = FakeLink();
    final port = WorkerSessionPort(OneLink(link), FakeHost(), framePresented: () async {});
    final events = <SessionEvent>[];
    final sub = port.events.listen(events.add);
    port.seedSessionForTest(3, link, reading: true);
    // 事件不 ack；三帧连着来，信箱顶掉的那帧也 ack
    link.push(windowsEvent());
    link.push(frame2x2());
    link.push(frame2x2());
    link.push(frame2x2());
    await until(() => link.acks == 3);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(link.acks, 3);
    // 解码失败的那帧：ack，然后会话断开
    link.push([1, 1, 2, 3]);
    await until(() => events.any((e) => e is DisconnectedEvent));
    expect((events.whereType<DisconnectedEvent>().single).reason, contains('画面解码失败'));
    expect(link.acks, 4);
    // 断开之后读到的帧：读循环丢掉它，也 ack
    link.push(frame2x2());
    await until(() => link.acks == 5);
    port.dispose();
    await sub.cancel();
  });

  test('a frame waiting in the mailbox is acked once when the session stops', () async {
    final link = FakeLink();
    final sink = GatedSink();
    final port = WorkerSessionPort(OneLink(link), FakeHost(), framePresented: () async {}, sink: sink);
    final events = <SessionEvent>[];
    final sub = port.events.listen(events.add);
    port.seedSessionForTest(3, link, reading: true);
    link.push(windowsEvent());
    link.push(frame2x2()); // in flight: decode is held at the gate
    await until(() => sink.decodes == 1);
    link.push(frame2x2()); // waits in the mailbox behind it
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(link.acks, 0);
    port.freeze(3, 'test'); // stops the transport: the mailbox frame is acked now
    await until(() => events.any((e) => e is DisconnectedEvent));
    expect(link.acks, 1);
    sink.gate.complete(); // the in-flight frame finishes: its own ack
    await until(() => link.acks == 2);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(link.acks, 2); // two frames, each acked exactly once
    port.dispose();
    await sub.cancel();
  });

  test('dropTextures forgets pictures and restoreStage brings them back', () async {
    final link = FakeLink();
    final port = WorkerSessionPort(OneLink(link), FakeHost(), framePresented: () async {});
    final events = <SessionEvent>[];
    final sub = port.events.listen(events.add);
    port.seedSessionForTest(3, link, reading: true);
    link.push(windowsEvent());
    link.push(frame2x2());
    await until(() => events.any((e) => e is WindowsEvent && e.windows.any((w) => w.image != null)));
    // 会话断开、不在台上：memoryWarning 调 dropTextures 的情形
    link.failInput();
    await until(() => events.any((e) => e is DisconnectedEvent));
    final before = events.length;
    port.dropTextures(3);
    expect(port.picturesForTest(3), isEmpty);
    await Future<void>.delayed(Duration.zero); // the broadcast stream delivers a tick later
    final told = events.skip(before).whereType<WindowsEvent>().toList();
    expect(told, isNotEmpty);
    expect(told.last.windows.every((w) => w.image == null), isTrue);
    port.restoreStageForTest(3); // 等于会话回到台上
    await until(() => port.picturesForTest(3).isNotEmpty);
    expect(link.acks, 1); // 只有那一帧；重画不是新帧，不 ack
    port.dispose();
    await sub.cancel();
  });

  test('a worker that dies mid-session gives one disconnected', () async {
    final link = ProcessSessionLink(SessionWorker.fromProcess(await Process.start('sh', ['-c', 'exit 3'])));
    final port = WorkerSessionPort(OneLink(link), FakeHost(), framePresented: () async {});
    final events = <SessionEvent>[];
    final sub = port.events.listen(events.add);
    port.seedSessionForTest(3, link, reading: true);
    // 读循环到头和输入断开两条路都会喊断开，只能出一次
    await until(() => events.any((e) => e is DisconnectedEvent));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(events.whereType<DisconnectedEvent>().length, 1);
    port.dispose();
    await sub.cancel();
  }, skip: Platform.isWindows ? '要 sh' : null);

  test('an input that breaks gives one disconnected', () async {
    final link = FakeLink();
    final port = WorkerSessionPort(OneLink(link), FakeHost(), framePresented: () async {});
    final events = <SessionEvent>[];
    final sub = port.events.listen(events.add);
    port.seedSessionForTest(3, link, reading: true);
    link.failInput();
    await until(() => events.any((e) => e is DisconnectedEvent));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(events.whereType<DisconnectedEvent>().length, 1);
    port.dispose();
    await sub.cancel();
  });

  test('init asks the links and the host first', () async {
    final host = FakeHost();
    final links = FailingLinks(StateError('rapp-session not found: x'));
    await expectLater(
      WorkerSessionPort(links, host).init(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'rapp-session not found: x')),
    );
    expect(host.inits, 0);
    final order = <String>[];
    final ok = WorkerSessionPort(OrderLinks(order), OrderHost(order));
    await ok.init();
    expect(order.take(2), ['check', 'host.init']);
    ok.dispose();
  });

  testWidgets('Linux picture voice holds cancel, edit and preserve ordinary Alt combinations', (t) async {
    final port = WorkerSessionPort(ProcessSessionLinks('unused'), LinuxSessionHost(), framePresented: () async {});
    final proc = (await t.runAsync(() => Process.start('cat', const [])))!;
    port.seedSessionForTest(3, ProcessSessionLink(SessionWorker.fromProcess(proc)));
    final phases = <VoiceKeyPhase>[];
    final sub = (await t.runAsync(() async => port.events.where((e) => e is VoiceKeyEvent).listen((e) => phases.add((e as VoiceKeyEvent).phase))))!;
    bool route(KeyEvent e) => port.handleKeyEvent(3, e);
    HardwareKeyboard.instance.addHandler(route);
    await port.invoke('picture_focus', {'sid': 3, 'voice': true});
    // A normal Alt+B flushes the delayed Alt down before B and sends both releases.
    await t.sendKeyDownEvent(LogicalKeyboardKey.altRight);
    await t.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await t.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    await t.pump(const Duration(milliseconds: 400));
    expect(phases, isEmpty);
    for (final decision in [LogicalKeyboardKey.escape, LogicalKeyboardKey.tab]) {
      await t.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await t.pump(const Duration(milliseconds: 301));
      expect(phases.last, VoiceKeyPhase.start);
      await t.sendKeyEvent(decision);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      await t.pump();
      expect(phases.last, decision == LogicalKeyboardKey.escape ? VoiceKeyPhase.cancel : VoiceKeyPhase.edit);
    }
    // Losing permission to start before the hold deadline never starts the microphone.
    final before = phases.length;
    await t.sendKeyDownEvent(LogicalKeyboardKey.altRight);
    await port.invoke('picture_focus', {'sid': 3});
    await t.pump(const Duration(milliseconds: 400));
    await t.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    expect(phases.length, before);
    // Focus loss during an active hold cancels it.
    await port.invoke('picture_focus', {'sid': 3, 'voice': true});
    await t.sendKeyDownEvent(LogicalKeyboardKey.altRight);
    await t.pump(const Duration(milliseconds: 301));
    await port.invoke('picture_focus', {'sid': null});
    await t.pump();
    expect(phases.last, VoiceKeyPhase.cancel);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    HardwareKeyboard.instance.removeHandler(route);
    await t.runAsync(sub.cancel);
    final sent = await t.runAsync(() async {
      await proc.stdin.close();
      return utf8.decode(await proc.stdout.expand((b) => b).toList());
    });
    final keys = sent!.trim().split('\n').map((l) => jsonDecode(l) as Map).where((m) => m['cmd'] == 'key');
    expect(keys.map((m) => (m['keyCode'], m['down'])).toList(), [(61, true), (11, true), (11, false), (61, false)]);
    port.dispose();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }, skip: !Platform.isLinux);
  test('view density increases detail within the full-window pixel budget', () {
    double density(double zoom, ui.Size range, {bool original = false}) => linuxViewDensity(
      base: original ? 8 : 2, original: original, zoom: zoom,
      content: const ui.Size(800, 600), range: range);
    expect(density(2, const ui.Size(400, 300)), 4);
    expect(density(8, const ui.Size(400, 300)), 4);
    expect(density(1, const ui.Size(800, 600)), 2);
    expect(density(0.5, const ui.Size(400, 300)), 1);
    expect(density(4, const ui.Size(400, 300), original: true), 8);
  });
  test('side connections track the strict Rust protocol version', () {
    final source = File('../rust/client-core/src/protocol.rs').readAsStringSync();
    final version = RegExp(r'pub const VERSION: u8 = ([0-9]+);').firstMatch(source)!;
    expect(sessionProtocolVersion, int.parse(version.group(1)!));
  });

  test('worker packet framing handles fragmentation, multiple packets and rejects truncation', () async {
    final bytes = [ ...u32(3), 0, 5, 7, ...u32(2), 1, 8 ];
    expect(await sessionPackets(Stream.fromIterable(bytes.map((b) => [b]))).toList(), [[0,5,7],[1,8]]);
    await expectLater(sessionPackets(Stream.value([...u32(8), 0, 1])).toList(), throwsFormatException);
    await expectLater(sessionPackets(Stream.value(u32(0xffffffff))).toList(), throwsFormatException);
  });

  test('physical keyboard mapping includes Command, arrows and punctuation', () {
    expect(hidMacKeyCode(PhysicalKeyboardKey.keyA), 0);
    expect(hidMacKeyCode(PhysicalKeyboardKey.keyZ), 6);
    expect(hidMacKeyCode(PhysicalKeyboardKey.controlLeft), 55);
    expect(hidMacKeyCode(PhysicalKeyboardKey.arrowLeft), 123);
    expect(hidMacKeyCode(PhysicalKeyboardKey.bracketLeft), 33);
    expect(hidMacKeyCode(PhysicalKeyboardKey.metaLeft), isNull);
  });

  testWidgets("Ctrl+Enter is rApp's: not sent to A", (tester) async {
    final port = WorkerSessionPort(ProcessSessionLinks('unused'), LinuxSessionHost(), framePresented: () async {});
    final proc = await tester.runAsync(() => Process.start('cat', const []));
    port.seedSessionForTest(3, ProcessSessionLink(SessionWorker.fromProcess(proc!)));
    KeyDownEvent down(PhysicalKeyboardKey p, LogicalKeyboardKey l) =>
        KeyDownEvent(physicalKey: p, logicalKey: l, timeStamp: Duration.zero);
    final enter = down(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter);
    final numpad = down(PhysicalKeyboardKey.numpadEnter, LogicalKeyboardKey.numpadEnter);
    final j = down(PhysicalKeyboardKey.keyJ, LogicalKeyboardKey.keyJ);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(port.handleKeyEvent(3, enter), false);
    expect(port.handleKeyEvent(3, numpad), false);
    expect(port.handleKeyEvent(3, j), true); // Ctrl+J still goes
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(port.handleKeyEvent(3, enter), true); // Shift+Enter goes
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(port.handleKeyEvent(3, enter), true); // so does plain Enter

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(port.handleKeyEvent(3, enter), true); // Ctrl+Shift+Enter is not rApp's
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    // Let go of what A holds, so the port has nothing left to release on dispose.
    expect(port.handleKeyEvent(3, const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyJ, logicalKey: LogicalKeyboardKey.keyJ, timeStamp: Duration.zero)), true);
    expect(port.handleKeyEvent(3, const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.enter, logicalKey: LogicalKeyboardKey.enter, timeStamp: Duration.zero)), true);
    final sent = await tester.runAsync(() async {
      await proc.stdin.close();
      return utf8.decode(await proc.stdout.expand((b) => b).toList());
    });
    final keys = [
      for (final m in [for (final l in sent!.trim().split('\n')) jsonDecode(l) as Map])
        if (m['down'] == true) (m['keyCode'], m['modifiers']),
    ];
    // J, Shift+Enter, Enter, Ctrl+Shift+Enter; no Ctrl+Enter. Ctrl goes as A's ⌘ (1 << 20), Shift as 1 << 17.
    expect(keys, [(38, 1 << 20), (36, 1 << 17), (36, 0), (36, 1 << 20 | 1 << 17)]);
    port.dispose();
    // The close's kill timer is cancelled once the (already ended) worker's exit is seen.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }, skip: Platform.isWindows);

  testWidgets('state_rules goes to rapp-session as it is; an oversized pack is dropped', (tester) async {
    final port = WorkerSessionPort(ProcessSessionLinks('unused'), LinuxSessionHost(), framePresented: () async {});
    final proc = await tester.runAsync(() => Process.start('cat', const []));
    port.seedSessionForTest(3, ProcessSessionLink(SessionWorker.fromProcess(proc!)));
    await tester.runAsync(() async {
      await port.invoke('state_rules', {'sid': 3, 'json': '{}'});
      await port.invoke('state_rules', {'sid': 3, 'json': 'x' * 70000});
    });
    final sent = await tester.runAsync(() async {
      await proc.stdin.close();
      return utf8.decode(await proc.stdout.expand((b) => b).toList());
    });
    expect(sent!.trim().split('\n').map((l) => jsonDecode(l) as Map).toList(), [
      {'cmd': 'state_rules', 'json': '{}'},
    ]);
    port.dispose();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }, skip: Platform.isWindows);

  testWidgets('a compose letter opens the draft with it; digits, Ctrl+letter and compose off go to A',
      (tester) async {
    final port = WorkerSessionPort(ProcessSessionLinks('unused'), LinuxSessionHost(), framePresented: () async {});
    final proc = await tester.runAsync(() => Process.start('cat', const []));
    port.seedSessionForTest(3, ProcessSessionLink(SessionWorker.fromProcess(proc!)));
    final events = <SessionEvent>[];
    // Listen outside the fake-async zone: a fake-zone subscription keeps the test from finishing.
    final sub = (await tester.runAsync(() async => port.events.listen(events.add)))!;
    KeyDownEvent down(PhysicalKeyboardKey p, LogicalKeyboardKey l, String ch) =>
        KeyDownEvent(physicalKey: p, logicalKey: l, character: ch, timeStamp: Duration.zero);
    KeyUpEvent up(PhysicalKeyboardKey p, LogicalKeyboardKey l) =>
        KeyUpEvent(physicalKey: p, logicalKey: l, timeStamp: Duration.zero);
    final a = down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'a');
    final upA = up(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA);

    await port.invoke('picture_focus', {'sid': 3, 'compose': true});
    expect(port.handleKeyEvent(3, a), true);
    expect(port.handleKeyEvent(3, upA), true); // its release is not A's either
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(events.whereType<ComposerInsertEvent>().map((e) => e.insert.text), ['a']);
    // Typed in as text, not replayed through the input method: the panel keeps the input method as it is.
    expect(events.whereType<ComposerInsertEvent>().single.letter, isTrue);

    // The panel takes the keys before the letter is let go; back on the picture, a letter is a fresh one.
    expect(port.handleKeyEvent(3, a), true);
    await port.invoke('picture_focus', {'sid': null});
    expect(port.handleKeyEvent(3, upA), false); // the editor's now
    await port.invoke('picture_focus', {'sid': 3, 'compose': true});
    expect(port.handleKeyEvent(3, a), true);
    expect(port.handleKeyEvent(3, upA), true);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(events.whereType<ComposerInsertEvent>().map((e) => e.insert.text), ['a', 'a', 'a']);

    // The panel took the keys and the picture got them back: no compose is pending. A digit goes to A.
    await port.invoke('picture_focus', {'sid': null});
    await port.invoke('picture_focus', {'sid': 3, 'compose': true});
    expect(port.handleKeyEvent(3, down(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1, '1')), true);
    expect(port.handleKeyEvent(3, up(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1)), true);
    // Ctrl+A goes to A (as ⌘A).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(port.handleKeyEvent(3, a), true);
    expect(port.handleKeyEvent(3, upA), true);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // compose off (picture_focus without it): the letter goes to A.
    await port.invoke('picture_focus', {'sid': 3});
    expect(port.handleKeyEvent(3, a), true);
    expect(port.handleKeyEvent(3, upA), true);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(events.whereType<ComposerInsertEvent>(), hasLength(3));

    final sent = await tester.runAsync(() async {
      await proc.stdin.close();
      return utf8.decode(await proc.stdout.expand((b) => b).toList());
    });
    final keys = [
      for (final m in [for (final l in sent!.trim().split('\n')) jsonDecode(l) as Map])
        if (m['cmd'] == 'key') (m['keyCode'], m['down']),
    ];
    // 1 down/up, ⌘A down/up, A down/up; the compose A (keyCode 0) never went.
    expect(keys, [(18, true), (18, false), (0, true), (0, false), (0, true), (0, false)]);
    port.dispose();
    await tester.runAsync(sub.cancel);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }, skip: Platform.isWindows);

  testWidgets('before the panel takes the keys, a space or digit after the letter goes into the draft too',
      (tester) async {
    final port = WorkerSessionPort(ProcessSessionLinks('unused'), LinuxSessionHost(), framePresented: () async {});
    final proc = await tester.runAsync(() => Process.start('cat', const []));
    port.seedSessionForTest(3, ProcessSessionLink(SessionWorker.fromProcess(proc!)));
    final events = <SessionEvent>[];
    final sub = (await tester.runAsync(() async => port.events.listen(events.add)))!;
    KeyDownEvent down(PhysicalKeyboardKey p, LogicalKeyboardKey l, String ch) =>
        KeyDownEvent(physicalKey: p, logicalKey: l, character: ch, timeStamp: Duration.zero);
    KeyUpEvent up(PhysicalKeyboardKey p, LogicalKeyboardKey l) =>
        KeyUpEvent(physicalKey: p, logicalKey: l, timeStamp: Duration.zero);
    final one = down(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1, '1');
    final upOne = up(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1);

    await port.invoke('picture_focus', {'sid': 3, 'compose': true});
    expect(port.handleKeyEvent(3, down(PhysicalKeyboardKey.keyN, LogicalKeyboardKey.keyN, 'n')), true);
    expect(port.handleKeyEvent(3, down(PhysicalKeyboardKey.space, LogicalKeyboardKey.space, ' ')), true);
    expect(port.handleKeyEvent(3, up(PhysicalKeyboardKey.space, LogicalKeyboardKey.space)), true);
    expect(port.handleKeyEvent(3, one), true);
    expect(port.handleKeyEvent(3, upOne), true);
    expect(port.handleKeyEvent(3, up(PhysicalKeyboardKey.keyN, LogicalKeyboardKey.keyN)), true);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(events.whereType<ComposerInsertEvent>().map((e) => e.insert.text), ['n', ' ', '1']);

    // Focus moved (here: compose re-sent for the picture): nothing is pending, the digit is A's again.
    await port.invoke('picture_focus', {'sid': 3, 'compose': true});
    expect(port.handleKeyEvent(3, one), true);
    expect(port.handleKeyEvent(3, upOne), true);

    final sent = await tester.runAsync(() async {
      await proc.stdin.close();
      return utf8.decode(await proc.stdout.expand((b) => b).toList());
    });
    final keys = [
      for (final m in [for (final l in sent!.trim().split('\n')) jsonDecode(l) as Map])
        if (m['cmd'] == 'key') (m['keyCode'], m['down']),
    ];
    expect(keys, [(18, true), (18, false)]); // only the last 1
    port.dispose();
    await tester.runAsync(sub.cancel);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }, skip: Platform.isWindows);

  final worker = File('../rust/target/release/rapp-session').absolute.path;
  test('v13 hints survive real worker and reach detached native windows', () async {
    const channel = MethodChannel('rapp/linux');
    const codec = StandardMethodCodec();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    final firstNativeFrame = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'frame' && !firstNativeFrame.isCompleted) {
        firstNativeFrame.complete();
      }
      return call.method == 'init' ? true : null;
    });
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = WorkerSessionPort(ProcessSessionLinks(worker), LinuxSessionHost(), framePresented: () async {});
    final events = StreamIterator(port.events);
    Socket? peer;
    try {
      await port.init();
      final accepted = server.first;
      await port.start(StartArgs(81, server.port, 'fixture', 'color16', 15, 'adaptive'));
      peer = await accepted;
      peer.listen((_) {});
      peer.add(packet(2, [...string('Fixture'), ...u16(4), ...u16(4)]));
      await nextWhere(events, (e) => e is ReadyEvent);
      peer.add(packet(40, [1]));
      expect((await nextWhere(events, (e) => e is SecureFocusEvent) as SecureFocusEvent).on, true);
      await port.detach(81, text: '前\ue000后', blocks: [const BlockChip(1, '文件', mark: 0xe000)]);
      await nextWhere(events, (e) => e is DetachedEvent);
      expect((calls.lastWhere((c) => c.method == 'secure_focus').arguments as Map)['on'], true);
      expect((calls.firstWhere((c) => c.method == 'detach').arguments as Map)['blocks'],
          [{'n': 1, 'label': '文件', 'mark': 0xe000}]);
      peer.add(packet(37, [...u32(77), ...string('提示'), ...string('bundle'), 1]));
      expect((await nextWhere(events, (e) => e is CoveredEvent) as CoveredEvent).dismissable, true);
      peer.add(packet(39, [...string('new.bundle'), ...string('新应用')]));
      expect((await nextWhere(events, (e) => e is AppOpenedEvent) as AppOpenedEvent).bundle, 'new.bundle');
      port.nativeHostNotice(81, epoch: 5, text: '提示', actions: [{'id': 'dismiss', 'label': '关闭'}]);
      await messenger.handlePlatformMessage(channel.name,
          codec.encodeMethodCall(const MethodCall('host_notice_action', {'sid': 81, 'action': 'dismiss', 'epoch': 5})), (_) {});
      final action = await nextWhere(events, (e) => e is HostNoticeActionEvent) as HostNoticeActionEvent;
      expect((action.sid, action.action, action.epoch), (81, 'dismiss', 5));
      await messenger.handlePlatformMessage(channel.name,
          codec.encodeMethodCall(const MethodCall('draft', {'sid': 81, 'text': '前\ue000后'})), (_) {});
      expect((await nextWhere(events, (e) => e is ComposerDraftEvent) as ComposerDraftEvent).inline, true);
      for (final direction in ['up', 'down']) {
        await messenger.handlePlatformMessage(channel.name,
            codec.encodeMethodCall(MethodCall('composer_action', {
              'sid': 81, 'text': 'edited draft', 'action': direction,
            })), (_) {});
        final recall = await nextWhere(events, (e) => e is ComposerDraftEvent) as ComposerDraftEvent;
        expect((recall.sid, recall.text, recall.action, recall.inline), (81, 'edited draft', direction, true));
      }
      port.nativeComposerDraft(81, 'restored draft');
      await Future<void>.delayed(Duration.zero);
      expect(calls.lastWhere((c) => c.method == 'composer_draft').arguments,
          {'sid': 81, 'text': 'restored draft'});
      peer.add(packet(40, [0]));
      await nextWhere(events, (e) => e is SecureFocusEvent);
      expect((calls.lastWhere((c) => c.method == 'secure_focus').arguments as Map)['on'], false);
      // The hints have not broken the following frame.
      peer.add(packet(13, [...u16(1), ...u32(1), ...u32(0), 0, 2,
          ...f32(0), ...f32(0), ...f32(4), ...f32(4), ...f32(1), ...string('Window')]));
      peer.add(frame(true));
      // Native presentation must not also upload an invisible Flutter image.
      // Reattaching reconstructs it from the cached canvas without a new frame.
      await firstNativeFrame.future.timeout(const Duration(seconds: 5));
      await port.invoke('attach', {'sid': 81});
      await nextWhere(events, (e) => e is WindowsEvent && e.windows.any((w) => w.image != null));
    } finally {
      port.dispose();
      await events.cancel();
      peer?.destroy();
      await server.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  }, skip: !Platform.isLinux || !File(worker).existsSync() ? 'Build rapp-session first on Linux' : false);

  test('v16 state_rules and appState roundtrip through real Linux worker', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = WorkerSessionPort(ProcessSessionLinks(worker), LinuxSessionHost(), framePresented: () async {});
    final events = StreamIterator(port.events);
    Socket? peer;
    final wire = <int>[];
    final gotRules = Completer<String>();
    try {
      await port.init();
      final accepted = server.first;
      await port.start(StartArgs(82, server.port, 'fixture', 'color16', 15, 'adaptive'));
      peer = await accepted;
      peer.listen((chunk) {
        wire.addAll(chunk);
        while (wire.length >= 5) {
          final type = wire[0];
          final len = ByteData.sublistView(Uint8List.fromList(wire), 1, 5).getUint32(0, Endian.little);
          if (wire.length < 5 + len) break;
          final body = wire.sublist(5, 5 + len);
          wire.removeRange(0, 5 + len);
          if (type == 43 && !gotRules.isCompleted) {
            gotRules.complete(utf8.decode(body));
          }
        }
      });
      peer.add(packet(2, [...string('Fixture'), ...u16(4), ...u16(4)]));
      await nextWhere(events, (e) => e is ReadyEvent);
      const pack = '{"format":"1.0","id":"generic-chat","rev":1}';
      await port.invoke('state_rules', {'sid': 82, 'json': pack});
      expect(await gotRules.future.timeout(const Duration(seconds: 5)), pack);
      const report = '{"pack":"generic-chat","rev":1,"state":"working","sure":true}';
      peer.add(packet(44, utf8.encode(report)));
      final ev = await nextWhere(events, (e) => e is AppStateEvent) as AppStateEvent;
      expect((ev.sid, ev.json), (82, report));
    } finally {
      port.dispose();
      await events.cancel();
      peer?.destroy();
      await server.close();
    }
  }, skip: !Platform.isLinux || !File(worker).existsSync() ? 'Build rapp-session first on Linux' : false);

  test('real Linux worker decodes full/delta, crops titlebar, sends input and closes on EOF', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = WorkerSessionPort(ProcessSessionLinks(worker), LinuxSessionHost(), framePresented: () async {});
    final events = StreamIterator(port.events);
    Socket? peer;
    var metadataEvents = 0;
    final observer = port.events.listen((e) { if (e is WindowsEvent) metadataEvents++; });
    final received = <int>[];
    final disconnected = Completer<void>();
    try {
      await port.init();
      final accepted = server.first;
      await port.start(StartArgs(7, server.port, 'fixture-token', 'color16', 15, 'adaptive'));
      peer = await accepted.timeout(const Duration(seconds: 5));
      var parsed = 0;
      peer.listen((bytes) {
        received.addAll(bytes);
        final all = Uint8List.fromList(received);
        while (parsed + 5 <= all.length) {
          final n = ByteData.sublistView(all).getUint32(parsed + 1, Endian.little);
          if (parsed + 5 + n > all.length) break;
          if (all[parsed] == 20) {
            peer!.add(packet(21, [...all.sublist(parsed + 5, parsed + 9), ...string('')]));
          }
          parsed += 5 + n;
        }
      }, onDone: disconnected.complete);
      peer.add(packet(2, [...string('Fixture'), ...u16(4), ...u16(4)]));
      peer.add(packet(13, [...u16(1), ...u32(1), ...u32(0), 0, 2,
          ...f32(0), ...f32(0), ...f32(4), ...f32(4), ...f32(1), ...string('Window')]));
      peer.add(frame(true));
      await peer.flush();
      expect((await nextWhere(events, (e) => e is ReadyEvent) as ReadyEvent).appName, 'Fixture');
      var e = await nextWhere(events, (e) => e is WindowsEvent && e.windows.any((w) => w.image != null)) as WindowsEvent;
      expect(e.windows.single.source, const ui.Rect.fromLTWH(0, 1, 4, 3));
      expect(e.windows.single.visible, const ui.Rect.fromLTWH(0, 0, 1, 1));
      var pixels = await e.windows.single.image!.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(pixels!.buffer.asUint8List().take(4), [255, 0, 0, 255]);
      final changed = Completer<void>();
      final frames = e.windows.single.frames!;
      void listener() { if (!changed.isCompleted) changed.complete(); }
      frames.addListener(listener);
      peer.add(frame(false)); await peer.flush();
      await changed.future.timeout(const Duration(seconds: 5));
      frames.removeListener(listener);
      expect(metadataEvents, 2, reason: 'pixel-only updates must not rebuild the app');
      pixels = await e.windows.single.image!.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(pixels!.buffer.asUint8List().take(4), [0, 255, 0, 255]);
      port.key(7, 0, 1 << 20);
      port.mouse(7, 1, 'down', 'left', 2, 3, 1);
      port.mouse(7, 1, 'up', 'left', 2, 3, 1);
      port.resize(7, 1, 500, 300);
      port.setStream(7, 'duogray', 5, 'original');
      port.closeWindow(7, 1);
      port.selectInput(7, '');
      port.composerSend(7, [{'text': '你好'}]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final messages = <(int, List<int>)>[];
      for (var i = 0; i + 5 <= received.length;) {
        final n = ByteData.sublistView(Uint8List.fromList(received), i + 1, i + 5).getUint32(0, Endian.little);
        if (i + 5 + n > received.length) break;
        messages.add((received[i], received.sublist(i+5, i+5+n))); i += 5+n;
      }
      expect(messages.map((m) => m.$1), containsAllInOrder([1,6,6,7,7,9,11,15,30,14,20]));
      expect(messages.first.$2.first, sessionProtocolVersion);
      expect(messages.firstWhere((m) => m.$1 == 15).$2, u32(1));
      expect(messages.firstWhere((m) => m.$1 == 30).$2, string(''));
      expect(utf8.decode(messages.last.$2.sublist(7)), '你好');
      final resize = messages.firstWhere((m) => m.$1 == 9).$2;
      expect(resize, [...u32(1), ...u16(500), ...u16(300)]);
      final traffic = await nextWhere(events, (e) => e is TrafficEvent && e.frames > 0) as TrafficEvent;
      expect(traffic.frames, 2);
      expect(traffic.bytes, greaterThan(0));
      port.close(7);
      expect((await nextWhere(events, (e) => e is ClosedEvent) as ClosedEvent).reason, 'closed');
      await disconnected.future.timeout(const Duration(seconds: 5));
    } finally {
      await observer.cancel();
      port.dispose(); await events.cancel(); peer?.destroy(); await server.close();
    }
  }, skip: !Platform.isLinux || !File(worker).existsSync() ? 'Build rapp-session first on Linux' : false);

  test('stalled renderer does not delay remote errors or disconnect', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final gate = Completer<void>();
    final port = WorkerSessionPort(ProcessSessionLinks(worker), LinuxSessionHost(), framePresented: () => gate.future);
    final events = StreamIterator(port.events);
    Socket? peer;
    try {
      await port.init(); final accepted = server.first;
      await port.start(StartArgs(11, server.port, 'fixture-token', 'color16', 15, 'adaptive'));
      peer = await accepted; peer.listen((_) {});
      peer.add(packet(2, [...string('Fixture'), ...u16(4), ...u16(4)]));
      peer.add(packet(13, [...u16(1), ...u32(1), ...u32(0), 0, 2,
          ...f32(0), ...f32(0), ...f32(4), ...f32(4), ...f32(1), ...string('Window')]));
      peer.add(frame(true));
      final picture = await nextWhere(events, (e) => e is WindowsEvent && e.windows.any((w) => w.image != null)) as WindowsEvent;
      peer.add(frame(false)); // this frame waits, the error must not
      peer.add(packet(26, string('客厅的 Mac')));
      expect((await nextWhere(events, (e) => e is InputBlockedEvent) as InputBlockedEvent).by, '客厅的 Mac');
      peer.add(packet(3, string('taken over by 客厅的 Mac')));
      final end = await nextWhere(events, (e) => e is DisconnectedEvent) as DisconnectedEvent;
      expect(end.reason, 'taken over by 客厅的 Mac');
      // Link loss retains the displayed red frame, even with a newer frame queued.
      final pixels = await picture.windows.single.image!.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(pixels!.buffer.asUint8List().take(4), [255, 0, 0, 255]);
      expect(port.handleKeyEvent(11, const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA, logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero)), false);
      port.close(11);
      expect((await nextWhere(events, (e) => e is ClosedEvent)).sid, 11);
    } finally {
      port.dispose(); gate.complete(); await events.cancel(); peer?.destroy(); await server.close();
    }
  }, skip: !Platform.isLinux || !File(worker).existsSync() ? 'Build rapp-session first on Linux' : false);

  test('ending while the worker is starting cancels it and allows a new start', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = WorkerSessionPort(ProcessSessionLinks(worker), LinuxSessionHost(), framePresented: () async {});
    final events = StreamIterator(port.events);
    Socket? peer;
    try {
      await port.init();
      final pending = port.start(StartArgs(12, server.port, 'fixture-token', 'color16', 15, 'adaptive'));
      port.close(12);
      await expectLater(pending, throwsStateError);
      final accepted = server.first;
      await port.start(StartArgs(12, server.port, 'fixture-token', 'color16', 15, 'adaptive'));
      peer = await accepted.timeout(const Duration(seconds: 5));
      peer.listen((_) {});
      peer.add(packet(2, [...string('Restarted'), ...u16(4), ...u16(4)]));
      expect((await nextWhere(events, (e) => e is ReadyEvent) as ReadyEvent).appName, 'Restarted');
      port.close(12);
      expect((await nextWhere(events, (e) => e is ClosedEvent)).sid, 12);
    } finally {
      port.dispose(); await events.cancel(); peer?.destroy(); await server.close();
    }
  }, skip: !Platform.isLinux || !File(worker).existsSync() ? 'Build rapp-session first on Linux' : false);

  test('Linux resource copies survive session end and retain more than 20 text clips', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = WorkerSessionPort(ProcessSessionLinks(worker), LinuxSessionHost(), framePresented: () async {});
    final events = StreamIterator(port.events);
    Socket? peer;
    String? clipboard;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
        return null;
      });
    try {
      await port.init(); final accepted = server.first;
      await port.start(StartArgs(21, server.port, 'fixture-token', 'color16', 15, 'adaptive'));
      peer = await accepted; peer.listen((_) {});
      peer.add(packet(2, [...string('Resources'), ...u16(4), ...u16(4)]));
      for (var i = 1; i <= 25; i++) {
        final text = utf8.encode('文字 $i');
        peer.add(packet(19, [...u32(i), 0, 0, ...u32(text.length), ...text]));
      }
      final clips = await nextWhere(events, (e) => e is ClipsEvent && e.clips.length == 25) as ClipsEvent;
      expect(clips.clips.last.kind, ClipKind.text);
      final copy = await port.fetchClip(21, 1);
      expect(copy.error, isNull); expect(copy.copy, isNotNull);
      // Like macOS, a truncated text announcement remains available as a text summary.
      peer.add(packet(19, [...u32(26), 0, 1, ...u32(1), 65]));
      await nextWhere(events, (e) => e is ClipsEvent && e.clips.length == 26);
      expect((await port.fetchClip(21, 26)).copy, isNotNull);
      port.close(21);
      await nextWhere(events, (e) => e is ClosedEvent);
      expect(await port.copyLocal(copy.copy!), true);
      expect(clipboard, '文字 1');
      expect((await port.fetchClip(21, 1)).error, contains('断开'));
      port.dropCopy(copy.copy!);
      expect(await port.copyLocal(copy.copy!), false);
    } finally {
      port.dispose(); await events.cancel(); peer?.destroy(); await server.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }
  }, skip: !Platform.isLinux || !File(worker).existsSync() ? 'Build rapp-session first on Linux' : false);

  test('pin_save preserves text; pin_load restores text and image copies', () async {
    final port = WorkerSessionPort(ProcessSessionLinks('/nonexistent-worker'), LinuxSessionHost(), framePresented: () async {});
    final dir = Directory.systemTemp.createTempSync('rapp-pin-');
    try {
      final copy = port.seedCopyForTest('# 钉住\n原文');
      final args = {'copy': copy, 'text_dir': '${dir.path}/clipboard', 'file_dir': '${dir.path}/files', 'stem': 's'};
      expect(await port.invoke('pin_save', args), {'path': '${dir.path}/clipboard/s.md'});
      expect(await port.invoke('pin_save', args), {'path': '${dir.path}/clipboard/s-2.md'});
      expect(File('${dir.path}/clipboard/s.md').readAsStringSync(), '# 钉住\n原文');
      expect(await port.invoke('pin_save', {...args, 'copy': 999}), isNull);
      expect(Directory('${dir.path}/files').existsSync(), false);
      final loaded = await port.invoke('pin_load', {'path': '${dir.path}/clipboard/s.md'}) as Map;
      expect(loaded['kind'], 'text');
      expect(await port.invoke('copy_local', {'copy': loaded['copy']}), true);
      expect(await port.invoke('pin_load', {'path': '${dir.path}/clipboard/missing.md'}), isNull);
      File('${dir.path}/x.png').writeAsBytesSync([1]);
      expect((await port.invoke('pin_load', {'path': '${dir.path}/x.png'}) as Map)['kind'], 'image');
      File('${dir.path}/bad.md').writeAsBytesSync([0xff, 0xfe, 0x00]);
      expect(await port.invoke('pin_load', {'path': '${dir.path}/bad.md'}), isNull);
    } finally {
      port.dispose();
      dir.deleteSync(recursive: true);
    }
  });

  test(
    'composer waits for matching ack, keeps refused text and settles on disconnect',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = WorkerSessionPort(ProcessSessionLinks(worker), LinuxSessionHost(), framePresented: () async {});
      final events = StreamIterator(port.events);
      final replies = <ComposerDone>[];
      final observer = port.events.listen((e) {
        if (e is ComposerStateEvent && e.done != null) replies.add(e.done!);
      });
      Socket? peer;
      final commands = <int>[];
      try {
        await port.init();
        final accepted = server.first;
        await port.start(
          StartArgs(31, server.port, 'token', 'color16', 15, 'adaptive'),
        );
        peer = await accepted;
        peer.listen(commands.addAll);
        peer.add(packet(2, [...string('Composer'), ...u16(4), ...u16(4)]));
        await nextWhere(events, (e) => e is ReadyEvent);
        port.composerSend(31, [
          {'text': '第一段'},
          {'text': '第二段'},
        ]);
        await nextWhere(
          events,
          (e) => e is ComposerStateEvent && e.sending == true,
        );
        // A duplicate send is ignored, and a stale acknowledgement cannot finish this one.
        port.composerSend(31, [
          {'text': '重复'},
        ]);
        peer.add(packet(21, [...u32(999), ...string('')]));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(replies, isEmpty);
        peer.add(packet(21, [...u32(1), ...string('')]));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        peer.add(packet(26, string('Mac')));
        peer.add(packet(21, [...u32(2), ...string('远端正在被 Mac 操作')]));
        final done =
            await nextWhere(
                  events,
                  (e) => e is ComposerStateEvent && e.done != null,
                )
                as ComposerStateEvent;
        expect(done.done!.sent, 1);
        expect(done.done!.failure, '远端正在被 Mac 操作');
        port.composerSend(31, [
          {'text': '第二段'},
        ]);
        await nextWhere(
          events,
          (e) => e is ComposerStateEvent && e.sending == true,
        );
        peer.add(
          packet(21, [...u32(2), ...string('')]),
        ); // late ack from previous round
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(replies.length, 1);
        peer.add(packet(3, string('taken over')));
        await nextWhere(events, (e) => e is DisconnectedEvent);
        final stopped =
            await nextWhere(
                  events,
                  (e) => e is ComposerStateEvent && e.done != null,
                )
                as ComposerStateEvent;
        expect(stopped.done!.sent, 0);
        expect(stopped.done!.failure, contains('发送未确认'));
      } finally {
        await observer.cancel();
        port.dispose();
        await events.cancel();
        peer?.destroy();
        await server.close();
      }
    },
    skip: !Platform.isLinux || !File(worker).existsSync()
        ? 'Build rapp-session first on Linux'
        : false,
  );

  test(
    'expired clip pick reports a visible reason instead of doing nothing',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = WorkerSessionPort(ProcessSessionLinks(worker), LinuxSessionHost(), framePresented: () async {});
      final events = StreamIterator(port.events);
      Socket? peer;
      try {
        await port.init();
        final accepted = server.first;
        await port.start(
          StartArgs(32, server.port, 'token', 'color16', 15, 'adaptive'),
        );
        peer = await accepted;
        peer.listen((_) {});
        peer.add(packet(2, [...string('Clips'), ...u16(4), ...u16(4)]));
        await nextWhere(events, (e) => e is ReadyEvent);
        port.clipPick(32, 999, false);
        expect(
          (await nextWhere(events, (e) => e is TransferStatusEvent)
                  as TransferStatusEvent)
              .status,
          '取用没成功：太旧了，远端已不保留',
        );
        expect((await port.fetchClip(32, 999)).error, 'unknown clip');
      } finally {
        port.dispose();
        await events.cancel();
        peer?.destroy();
        await server.close();
      }
    },
    skip: !Platform.isLinux || !File(worker).existsSync()
        ? 'Build rapp-session first on Linux'
        : false,
  );

  test('malformed frame closes only the affected session', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final second = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = WorkerSessionPort(ProcessSessionLinks(worker), LinuxSessionHost(), framePresented: () async {});
    final events = StreamIterator(port.events);
    Socket? peer, healthy;
    try {
      await port.init();
      final accepted = server.first, acceptedSecond = second.first;
      await port.start(StartArgs(9, server.port, 'fixture-token', 'color16', 15, 'adaptive'));
      await port.start(StartArgs(10, second.port, 'fixture-token', 'color16', 15, 'adaptive'));
      peer = await accepted; healthy = await acceptedSecond;
      peer.listen((_) {}); healthy.listen((_) {});
      peer.add(packet(2, [...string('Fixture'), ...u16(4), ...u16(4)]));
      peer.add(packet(4, [2,...f32(0),...f32(0),...f32(4),...f32(4),...u16(4),...u16(4),7,0]));
      final end = await nextWhere(events, (e) => e is DisconnectedEvent) as DisconnectedEvent;
      expect(end.sid, 9); expect(end.reason, contains('zlib'));
      healthy.add(packet(2, [...string('Healthy'), ...u16(4), ...u16(4)]));
      healthy.add(packet(13, [...u16(1), ...u32(1), ...u32(0), 0, 2,
          ...f32(0), ...f32(0), ...f32(4), ...f32(4), ...f32(1), ...string('Window')]));
      healthy.add(frame(true));
      final event = await nextWhere(events, (e) => e is WindowsEvent && e.windows.any((w) => w.image != null));
      expect(event.sid, 10);
    } finally {
      port.dispose(); await events.cancel(); peer?.destroy(); healthy?.destroy();
      await server.close(); await second.close();
    }
  }, skip: !Platform.isLinux || !File(worker).existsSync() ? 'Build rapp-session first on Linux' : false);
}

// English first: the Linux client has no native layer, so the port does what the Swift session does.
void englishFirstTests() {
  const aDown = KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA, character: 'a', timeStamp: Duration.zero);
  const aRepeat = KeyRepeatEvent(physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA, character: 'a', timeStamp: Duration.zero);
  const aUp = KeyUpEvent(physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA, timeStamp: Duration.zero);
  const shiftDown = KeyDownEvent(physicalKey: PhysicalKeyboardKey.shiftLeft,
      logicalKey: LogicalKeyboardKey.shiftLeft, timeStamp: Duration.zero);

  /// What the worker received, as `cmd` or `cmd:down` strings, in order.
  Future<List<String>> sent(Future<void> Function(WorkerSessionPort port) body) async {
    final process = await Process.start('cat', const []);
    final output = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).toList();
    final port = WorkerSessionPort(ProcessSessionLinks('unused'), LinuxSessionHost(), framePresented: () async {});
    port.seedSessionForTest(3, ProcessSessionLink(SessionWorker.fromProcess(process)));
    try {
      await body(port);
    } finally {
      port.dispose();
    }
    return [
      for (final line in await output.timeout(const Duration(seconds: 5)))
        if (jsonDecode(line) case final Map m)
          m['cmd'] == 'key' ? 'key:${m['keyCode']}:${m['down']}' : '${m['cmd']}:${m['id'] ?? ''}',
    ];
  }

  group('English first', () {
    test('the first key-down after a non-English report selects English first', () async {
      final out = await sent((port) async {
        port.inputSourceForTest(3, false);
        port.handleKeyEvent(3, aDown);
        port.handleKeyEvent(3, aUp);
      });
      expect(out, ['select_input:', 'key:0:true', 'key:0:false']);
    });

    test('repeat sends one select', () async {
      final out = await sent((port) async {
        port.inputSourceForTest(3, false);
        port.handleKeyEvent(3, aDown);
        port.handleKeyEvent(3, aRepeat);
        port.handleKeyEvent(3, aRepeat);
      });
      expect(out.where((e) => e.startsWith('select_input')), hasLength(1));
    });

    test('a fresh non-English report re-arms it', () async {
      final out = await sent((port) async {
        port.inputSourceForTest(3, false);
        port.handleKeyEvent(3, aDown);
        port.inputSourceForTest(3, false);
        port.handleKeyEvent(3, aDown);
      });
      expect(out.where((e) => e.startsWith('select_input')), hasLength(2));
    });

    test('nothing extra when A is English, never reported, a modifier alone, Ctrl combo or key-up', () async {
      final out = await sent((port) async {
        port.handleKeyEvent(3, aDown); // never reported
        port.inputSourceForTest(3, true);
        port.handleKeyEvent(3, aDown); // ascii
        port.inputSourceForTest(3, false);
        port.handleKeyEvent(3, shiftDown); // modifier alone
        port.handleKeyEvent(3, aUp); // up
        await port.invoke('key', {'sid': 3, 'keyCode': 0, 'modifiers': 1 << 20}); // remote Command
      });
      expect(out.where((e) => e.startsWith('select_input')), isEmpty);
    });

    test('the key command (key bar) selects first, unless it is an up', () async {
      final out = await sent((port) async {
        port.inputSourceForTest(3, false);
        await port.invoke('key', {'sid': 3, 'keyCode': 36, 'modifiers': 0, 'down': false});
        await port.invoke('key', {'sid': 3, 'keyCode': 36, 'modifiers': 0});
      });
      expect(out, ['key:36:false', 'select_input:', 'key:36:null']);
    });

    test('auto_english pauses and resumes, and is not sent to the worker', () async {
      final out = await sent((port) async {
        port.inputSourceForTest(3, false);
        await port.invoke('auto_english', {'sid': 3, 'on': false});
        port.handleKeyEvent(3, aDown);
        await port.invoke('auto_english', {'sid': 3, 'on': true});
        port.handleKeyEvent(3, aDown);
      });
      expect(out.take(3), ['key:0:true', 'select_input:', 'key:0:true']);
    });
  });
}
