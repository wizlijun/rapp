import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/linux_session_port.dart';
import 'package:rapp/embed/session_port.dart';
import 'linux_session_port_test.dart' as wire;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rapp/linux');
  test('closing during pending native detach removes the native session', () async {
    final calls = <MethodCall>[];
    final gate = Completer<void>();
    final entered = Completer<void>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'init') return true;
      if (call.method == 'detach') {
        entered.complete();
        await gate.future;
      }
      return null;
    });
    final process = await Process.start('cat', const []);
    final port = LinuxSessionPort('/bin/cat', framePresented: () async {});
    final events = <SessionEvent>[];
    final sub = port.events.listen(events.add);
    try {
      await port.init();
      port.seedSessionForTest(91, process);
      final pending = port.detach(91, text: 'keep draft');
      await entered.future;
      await port.invoke('close', {'sid': 91});
      gate.complete();
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'attach'), hasLength(1));
      expect((calls.firstWhere((c) => c.method == 'attach').arguments as Map)['discard'], true);
      expect(calls.where((c) => c.method == 'windows'), isEmpty);
      expect(events.whereType<DetachedEvent>(), isEmpty);
    } finally {
      port.dispose();
      await sub.cancel();
      process.kill();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });
  test('native insertion reaches an existing window before detach acknowledgement', () async {
    final calls = <MethodCall>[];
    final gate = Completer<void>(), entered = Completer<void>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'init') return true;
      if (call.method == 'windows') { entered.complete(); await gate.future; }
      return null;
    });
    final process = await Process.start('cat', const []);
    final port = LinuxSessionPort('/bin/cat', framePresented: () async {});
    final events = <SessionEvent>[];
    final sub = port.events.listen(events.add);
    try {
      await port.init();
      port.seedSessionForTest(91, process);
      final pending = port.detach(91);
      await entered.future;
      expect(events.whereType<DetachedEvent>(), isEmpty);
      final visibilitySent = Completer<void>();
      binding.channelBuffers.push('rapp/linux',
          const StandardMethodCodec().encodeMethodCall(
              const MethodCall('window_visible', {'sid': 91, 'visible': false})),
          (_) => visibilitySent.complete());
      await visibilitySent.future;
      port.nativeComposerInsert(91, 'late paste', [const BlockChip(1, 'file', mark: 0xe000)]);
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'composer_insert').single.arguments, {
        'sid': 91, 'text': 'late paste', 'blocks': [{'n': 1, 'label': 'file', 'mark': 0xe000}],
      });
      gate.complete();
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<DetachedEvent>().single.detached, true);
      expect(events.whereType<WindowVisibleEvent>().last.visible, false,
          reason: 'detach completion must retain visibility reported while opening');
    } finally {
      if (!gate.isCompleted) gate.complete();
      port.dispose();
      await sub.cancel();
      process.kill();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('disconnecting during pending native detach returns to the frozen stage', () async {
    final calls = <MethodCall>[];
    final gate = Completer<void>();
    final entered = Completer<void>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'init') return true;
      if (call.method == 'detach') {
        entered.complete();
        await gate.future;
      }
      return null;
    });
    final process = await Process.start('cat', const []);
    final port = LinuxSessionPort('/bin/cat', framePresented: () async {});
    final events = <SessionEvent>[];
    final sub = port.events.listen(events.add);
    try {
      await port.init();
      port.seedSessionForTest(91, process);
      final pending = port.detach(91, text: 'keep draft');
      await entered.future;
      port.freeze(91, 'lost connection');
      gate.complete();
      await expectLater(pending, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'attach'), hasLength(1));
      expect((calls.firstWhere((c) => c.method == 'attach').arguments as Map)['discard'], true);
      expect(calls.where((c) => c.method == 'windows'), isEmpty);
      expect(events.whereType<DetachedEvent>(), isEmpty);
    } finally {
      port.dispose();
      await sub.cancel();
      process.kill();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });
  for (final disconnect in [false, true]) {
  test(
    'native detach/attach restores latest frame without duplicate Flutter uploads (disconnected=$disconnect)',
    () async {
      final calls = <MethodCall>[];
      Completer<void>? nativeFrame;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'frame' && nativeFrame?.isCompleted == false) {
          nativeFrame!.complete();
        }
        return call.method == 'init' ? true : null;
      });
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      var connections = 0;
      final listener = server.listen((peer) {
        connections++;
        if (!accepted.isCompleted) accepted.complete(peer);
      });
      final presentationStarted = Completer<void>();
      final stalledPresentation = Completer<void>();
      final port = LinuxSessionPort(
        File('../rust/target/release/rapp-session').absolute.path,
        framePresented: () {
          if (!presentationStarted.isCompleted) presentationStarted.complete();
          return stalledPresentation.future;
        },
      );
      final events = StreamIterator(port.events);
      Socket? peer;
      Future<void> native(String method, Map<String, Object?> args) async {
        final done = Completer<void>();
        binding.channelBuffers.push(
          'rapp/linux',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, args),
          ),
          (_) {
            done.complete();
          },
        );
        await done.future;
      }

      try {
        await port.init();
        expect(port.supportsDetach, true);
        await port.start(
          StartArgs(
            91,
            server.port,
            'fixture-token',
            'color16',
            15,
            'adaptive',
          ),
        );
        peer = await accepted.future.timeout(const Duration(seconds: 5));
        peer.listen((_) {});
        peer.add(
          wire.packet(2, [
            ...wire.string('Fixture'),
            ...wire.u16(4),
            ...wire.u16(4),
          ]),
        );
        peer.add(
          wire.packet(13, [
            ...wire.u16(1),
            ...wire.u32(1),
            ...wire.u32(0),
            0,
            2,
            ...wire.f32(0),
            ...wire.f32(0),
            ...wire.f32(4),
            ...wire.f32(4),
            ...wire.f32(1),
            ...wire.string('Window'),
          ]),
        );
        peer.add(wire.frame(true));
        await peer.flush();
        final first = await wire.nextWhere(
          events,
          (e) => e is WindowsEvent && e.windows.any((w) => w.image != null),
        ) as WindowsEvent;
        final frames = first.windows.single.frames!;
        var flutterUpdates = 0;
        final restored = Completer<void>();
        void onFrame() {
          flutterUpdates++;
          if (!restored.isCompleted) restored.complete();
        }
        frames.addListener(onFrame);
        await presentationStarted.future.timeout(const Duration(seconds: 5));
        await port.invoke('detach', {
          'sid': 91,
          'text': '中文草稿',
          'blocks': [
            {'n': 8, 'label': '附件'},
          ],
        });
        expect(
          (await wire.nextWhere(events, (e) => e is DetachedEvent)
                  as DetachedEvent)
              .detached,
          true,
        );
        expect(
          calls.lastWhere((c) => c.method == 'detach').arguments['text'],
          '中文草稿',
        );
        expect(calls.any((c) => c.method == 'frame'), true);
        expect(calls.any((c) => c.method == 'windows'), true);
        for (final visible in [false, true]) {
          await native('window_visible', {'sid': 91, 'visible': visible});
          final event = await wire.nextWhere(events,
              (e) => e is WindowVisibleEvent && e.visible == visible) as WindowVisibleEvent;
          expect(event.visible, visible);
        }
        await native('draft', {'sid': 91, 'text': '已编辑'});
        expect(
          (await wire.nextWhere(events, (e) => e is ComposerDraftEvent)
                  as ComposerDraftEvent)
              .text,
          '已编辑',
        );
        await native('set_stream', {
          'sid': 91,
          'mode': 'duogray',
          'density': 'original',
          'fps': 5,
        });
        final choice =
            await wire.nextWhere(events, (e) => e is StreamChoiceEvent)
                as StreamChoiceEvent;
        expect(
          [choice.mode, choice.density, choice.fps],
          ['duogray', 'original', 5],
        );
        await native('select_window', {'sid': 91, 'window': 1});
        nativeFrame = Completer<void>();
        peer.add(wire.frame(false));
        await peer.flush();
        await nativeFrame.future.timeout(const Duration(seconds: 5));
        // Let the native frame call and its rendering tick finish.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(flutterUpdates, 0, reason: 'the detached stage is hidden');
        if (disconnect) {
          peer.destroy();
          await wire.nextWhere(events, (e) => e is DisconnectedEvent);
        }
        await port.invoke('attach', {'sid': 91});
        final back =
            await wire.nextWhere(events, (e) => e is DetachedEvent)
                as DetachedEvent;
        expect(back.detached, false);
        expect(back.current, 1);
        expect(connections, 1);
        await restored.future.timeout(const Duration(seconds: 5));
        final pixels = await frames.value!.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        expect(pixels!.buffer.asUint8List().take(4), [0, 255, 0, 255]);
        frames.removeListener(onFrame);
        await port.invoke('close', {'sid': 91});
      } finally {
        port.dispose();
        peer?.destroy();
        await events.cancel();
        await listener.cancel();
        await server.close();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
  }
}
