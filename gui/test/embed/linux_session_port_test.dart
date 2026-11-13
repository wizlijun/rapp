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
      port.composerSend(7, [{'text': '你好'}]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final messages = <(int, List<int>)>[];
      for (var i = 0; i + 5 <= received.length;) {
        final n = ByteData.sublistView(Uint8List.fromList(received), i + 1, i + 5).getUint32(0, Endian.little);
        if (i + 5 + n > received.length) break;
        messages.add((received[i], received.sublist(i+5, i+5+n))); i += 5+n;
      }
      expect(messages.map((m) => m.$1), containsAllInOrder([1,6,6,7,7,9,11,14,20]));
      expect(messages.first.$2.first, 6);
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
        peer.add(packet(21, [...u32(2), ...string('A 正在被 Mac 操作')]));
        final done =
            await nextWhere(
                  events,
                  (e) => e is ComposerStateEvent && e.done != null,
                )
                as ComposerStateEvent;
        expect(done.done!.sent, 1);
        expect(done.done!.failure, 'A 正在被 Mac 操作');
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
          '取用没成功：太旧了，A 已不保留',
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
