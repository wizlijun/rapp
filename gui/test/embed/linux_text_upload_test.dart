import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/linux_text_upload.dart';

Uint8List u32(int n) =>
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
Uint8List u64(int n) =>
    (ByteData(8)..setUint64(0, n, Endian.little)).buffer.asUint8List();
List<int> string(String s) {
  final b = utf8.encode(s);
  return [
    ...(ByteData(
      2,
    )..setUint16(0, b.length, Endian.little)).buffer.asUint8List(),
    ...b,
  ];
}

List<int> packet(int kind, List<int> bytes) => [
  kind,
  ...u32(bytes.length),
  ...bytes,
];

Stream<(int, Uint8List)> packets(Socket peer) async* {
  var pending = <int>[];
  await for (final chunk in peer) {
    pending.addAll(chunk);
    while (pending.length >= 5) {
      final n = ByteData.sublistView(
        Uint8List.fromList(pending),
      ).getUint32(1, Endian.little);
      if (pending.length < 5 + n) break;
      yield (pending[0], Uint8List.fromList(pending.sublist(5, 5 + n)));
      pending = pending.sublist(5 + n);
    }
  }
}

void main() {
  test(
    'large UTF8 text follows put/resume/chunks/confirmation wire protocol',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final upload = LinuxTextUpload();
      final bytes = Uint8List.fromList(utf8.encode('中文内容' * 60000));
      final accepted = server.first;
      var finished = false;
      final sent = upload
          .send(server.port, 'secret', 9, bytes)
          .then((_) => finished = true);
      final peer = await accepted;
      final input = StreamIterator(packets(peer));
      try {
        expect(await input.moveNext(), true);
        expect(input.current.$1, 23);
        expect(input.current.$2, [
          6,
          ...string('secret'),
          ...u32(9),
          0,
          ...string('public.utf8-plain-text'),
          ...string(''),
          ...u64(bytes.length),
        ]);
        const offset = 37;
        // Fragment the response to exercise the streaming reader.
        final start = packet(24, u64(offset));
        peer.add(start.sublist(0, 3));
        await peer.flush();
        peer.add(start.sublist(3));
        await peer.flush();
        final received = <int>[];
        while (received.length < bytes.length - offset) {
          expect(await input.moveNext(), true);
          expect(input.current.$1, 25);
          expect(input.current.$2.length, lessThanOrEqualTo(256 * 1024));
          received.addAll(input.current.$2);
        }
        expect(received, bytes.sublist(offset));
        expect(
          finished,
          false,
          reason: 'writing bytes does not mean A accepted them',
        );
        peer.add(packet(25, []));
        await peer.flush();
        await sent.timeout(const Duration(seconds: 3));
        expect(finished, true);
      } finally {
        upload.cancel();
        peer.destroy();
        await input.cancel();
        await server.close();
      }
    },
  );

  for (final failure in ['bad offset', 'host error', 'cancel']) {
    test('upload stops cleanly on $failure', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final upload = LinuxTextUpload();
      final accepted = server.first;
      final sent = upload.send(server.port, 'secret', 1, Uint8List(60000));
      final failed = expectLater(sent, throwsA(anything));
      final peer = await accepted;
      final input = StreamIterator(packets(peer));
      try {
        expect(await input.moveNext(), true);
        switch (failure) {
          case 'bad offset':
            peer.add(packet(24, u64(60001)));
          case 'host error':
            peer.add(packet(3, string('disk full')));
          case 'cancel':
            upload.cancel();
        }
        await failed.timeout(const Duration(seconds: 3));
      } finally {
        upload.cancel();
        peer.destroy();
        await input.cancel();
        await server.close();
      }
    });
  }
}
