import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/linux_session_port.dart';
import 'package:rapp/embed/session_port.dart';

Uint8List u32(int n) => (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
Uint8List u16(int n) => (ByteData(2)..setUint16(0, n, Endian.little)).buffer.asUint8List();
Uint8List f32(double n) => (ByteData(4)..setFloat32(0, n, Endian.little)).buffer.asUint8List();
List<int> string(String s) => [...u16(utf8.encode(s).length), ...utf8.encode(s)];
List<int> packet(int type, List<int> bytes) => [type, ...u32(bytes.length), ...bytes];
const full = [120,156,98,100,0,129,31,0,0,0,0,255,255];
const delta = [98,4,145,15,216,1,0,0,0,255,255];
List<int> frame(bool first) => packet(4, [2, ...f32(0), ...f32(0), ...f32(4), ...f32(4),
    ...u16(4), ...u16(4), first ? 1 : 0, ...(first ? full : delta)]);

Future<SessionEvent> nextWhere(StreamIterator<SessionEvent> it, bool Function(SessionEvent) match) async {
  while (await it.moveNext().timeout(const Duration(seconds: 8))) {
    if (match(it.current)) return it.current;
  }
  throw StateError('event stream ended');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('worker packet framing handles fragmentation, multiple packets and rejects truncation', () async {
    final bytes = [ ...u32(3), 0, 5, 7, ...u32(2), 1, 8 ];
    expect(await sessionPackets(Stream.fromIterable(bytes.map((b) => [b]))).toList(), [[0,5,7],[1,8]]);
    await expectLater(sessionPackets(Stream.value([...u32(8), 0, 1])).toList(), throwsFormatException);
    await expectLater(sessionPackets(Stream.value(u32(0xffffffff))).toList(), throwsFormatException);
  });

  test('physical keyboard mapping includes Command, arrows and punctuation', () {
    expect(linuxMacKeyCode(PhysicalKeyboardKey.keyA), 0);
    expect(linuxMacKeyCode(PhysicalKeyboardKey.keyZ), 6);
    expect(linuxMacKeyCode(PhysicalKeyboardKey.controlLeft), 55);
    expect(linuxMacKeyCode(PhysicalKeyboardKey.arrowLeft), 123);
    expect(linuxMacKeyCode(PhysicalKeyboardKey.bracketLeft), 33);
    expect(linuxMacKeyCode(PhysicalKeyboardKey.metaLeft), isNull);
  });

  testWidgets("Ctrl+Enter is rapp's: not sent to A", (tester) async {
    final port = LinuxSessionPort('unused', framePresented: () async {});
    final proc = await tester.runAsync(() => Process.start('cat', const []));
    port.seedSessionForTest(3, proc!);
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
    expect(port.handleKeyEvent(3, enter), true); // Ctrl+Shift+Enter is not rapp's
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

  testWidgets('a compose letter opens the draft with it; digits, Ctrl+letter and compose off go to A',
      (tester) async {
    final port = LinuxSessionPort('unused', framePresented: () async {});
    final proc = await tester.runAsync(() => Process.start('cat', const []));
    port.seedSessionForTest(3, proc!);
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

    // The panel takes the keys before the letter is let go; back on the picture, a letter is a fresh one.
    expect(port.handleKeyEvent(3, a), true);
    await port.invoke('picture_focus', {'sid': null});
    expect(port.handleKeyEvent(3, upA), false); // the editor's now
    await port.invoke('picture_focus', {'sid': 3, 'compose': true});
    expect(port.handleKeyEvent(3, a), true);
    expect(port.handleKeyEvent(3, upA), true);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(events.whereType<ComposerInsertEvent>().map((e) => e.insert.text), ['a', 'a', 'a']);

    // A digit goes to A.
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

  final worker = File('../rust/target/release/rapp-session').absolute.path;
  test('real Linux worker decodes full/delta, crops titlebar, sends input and closes on EOF', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = LinuxSessionPort(worker, framePresented: () async {});
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
      expect(messages.first.$2.first, 8);
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
    final port = LinuxSessionPort(worker, framePresented: () => gate.future);
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
    final port = LinuxSessionPort(worker, framePresented: () async {});
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
    final port = LinuxSessionPort(worker, framePresented: () async {});
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
      // A full snapshot may contain unsupported/truncated entries, which cannot be pinned.
      peer.add(packet(19, [...u32(26), 0, 1, ...u32(1), 65]));
      await nextWhere(events, (e) => e is ClipsEvent && e.clips.length == 26);
      expect((await port.fetchClip(21, 26)).error, contains('完整文字'));
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

  test('pin_save writes text copies only; pin_load reads .md back', () async {
    final port = LinuxSessionPort('/nonexistent-worker', framePresented: () async {});
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
      expect(await port.invoke('pin_load', {'path': '${dir.path}/x.png'}), isNull);
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
      final port = LinuxSessionPort(worker, framePresented: () async {});
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
      final port = LinuxSessionPort(worker, framePresented: () async {});
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
    final port = LinuxSessionPort(worker, framePresented: () async {});
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
      peer.add(packet(4, [2,...f32(0),...f32(0),...f32(4),...f32(4),...u16(4),...u16(4),1,0]));
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
