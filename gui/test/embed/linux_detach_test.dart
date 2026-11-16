import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/linux_session_port.dart';
import 'package:rapp/embed/session_port.dart';
import 'linux_session_port_test.dart' as wire;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rapp/linux');
  test(
    'native detach/attach shares connection, frames, draft and stream settings',
    () async {
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'init' ? true : null;
      });
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      var connections = 0;
      final listener = server.listen((peer) {
        connections++;
        if (!accepted.isCompleted) accepted.complete(peer);
      });
      final port = LinuxSessionPort(
        File('../rust/target/release/rapp-session').absolute.path,
        framePresented: () async {},
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
        await wire.nextWhere(
          events,
          (e) => e is WindowsEvent && e.windows.any((w) => w.image != null),
        );
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
        await port.invoke('attach', {'sid': 91});
        final back =
            await wire.nextWhere(events, (e) => e is DetachedEvent)
                as DetachedEvent;
        expect(back.detached, false);
        expect(back.current, 1);
        expect(connections, 1);
        // A delta after attach still uses the same stateful decoder.
        peer.add(wire.frame(false));
        await peer.flush();
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
