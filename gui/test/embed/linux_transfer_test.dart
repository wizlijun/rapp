import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/linux_transfer.dart';
import 'package:rapp/embed/linux_clipboard.dart';
import 'linux_text_upload_test.dart' as wire;

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('rapp-transfer-');
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test(
    'file upload resumes at host offset and only completes after acknowledgement',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final progress = <LinuxTransferProgress>[];
      final transfers = LinuxTransfers(
        server.port,
        'secret',
        downloads: () => dir.path,
        progress: progress.add,
      );
      final data = Uint8List.fromList(List.generate(700000, (i) => i % 251));
      final file = File('${dir.path}/upload.bin')..writeAsBytesSync(data);
      final accepted = server.first;
      var done = false;
      final upload = transfers
          .upload(
            item: 7,
            kind: 'files',
            uti: 'public.file-url',
            name: 'upload.bin',
            file: file.path,
          )
          .then((_) => done = true);
      final peer = await accepted;
      final input = StreamIterator(wire.packets(peer));
      try {
        expect(await input.moveNext(), true);
        expect(input.current.$1, 23);
        expect(input.current.$2, [
          6,
          ...wire.string('secret'),
          ...wire.u32(7),
          2,
          ...wire.string('public.file-url'),
          ...wire.string('upload.bin'),
          ...wire.u64(data.length),
        ]);
        peer.add(wire.packet(24, wire.u64(19)));
        final got = BytesBuilder();
        while (got.length < data.length - 19) {
          expect(await input.moveNext(), true);
          expect(input.current.$1, 25);
          expect(input.current.$2.length, lessThanOrEqualTo(linuxChunkSize));
          got.add(input.current.$2);
        }
        expect(got.takeBytes(), data.sublist(19));
        expect(done, false);
        peer.add(wire.packet(25, []));
        await upload.timeout(const Duration(seconds: 3));
        expect(progress.last.state, 'done');
        expect(progress.last.done, data.length);
      } finally {
        transfers.close();
        peer.destroy();
        await input.cancel();
        await server.close();
      }
    },
  );

  test(
    'cancelled download keeps its partial file and resumes on the next request',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepts = StreamIterator(server);
      final progress = <LinuxTransferProgress>[];
      final transfers = LinuxTransfers(
        server.port,
        't',
        downloads: () => dir.path,
        progress: progress.add,
        retryDelays: const [],
      );
      File('${dir.path}/report.txt').writeAsStringSync('keep');
      final download = transfers.download(
        clip: 1,
        index: 0,
        name: '../../report.txt',
        total: 6,
        toDisk: true,
      );
      final failure = expectLater(download, throwsA(anything));
      await accepts.moveNext();
      final first = accepts.current;
      final input = StreamIterator(wire.packets(first));
      expect(await input.moveNext(), true);
      expect(input.current.$2.last, 0);
      first.add(wire.packet(24, wire.u64(6)));
      first.add(wire.packet(25, [1, 2, 3]));
      while (!progress.any((p) => p.done == 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      transfers.cancel(progress.first.id);
      await failure.timeout(const Duration(seconds: 3));
      expect(progress.last.state, 'cancelled');
      first.destroy();
      await input.cancel();
      final resumed = transfers.download(
        clip: 1,
        index: 0,
        name: '../../report.txt',
        total: 6,
        toDisk: true,
      );
      await accepts.moveNext();
      final second = accepts.current;
      final again = StreamIterator(wire.packets(second));
      try {
        expect(await again.moveNext(), true);
        expect(
          again.current.$2.sublist(again.current.$2.length - 8),
          wire.u64(3),
        );
        second.add(wire.packet(24, wire.u64(6)));
        second.add(wire.packet(25, [4, 5, 6]));
        final path =
            await resumed.timeout(const Duration(seconds: 3)) as String;
        expect(path, '${dir.path}/report (2).txt');
        expect(File(path).readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
        expect(File('${dir.path}/report.txt').readAsStringSync(), 'keep');
        expect(File('$path.rapp-part').existsSync(), false);
      } finally {
        transfers.close();
        second.destroy();
        await again.cancel();
        await accepts.cancel();
        await server.close();
      }
    },
  );

  test(
    'malformed chunks cannot overflow an announced image or allocate beyond the memory cap',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final transfers = LinuxTransfers(
        server.port,
        't',
        downloads: () => dir.path,
        progress: (_) {},
        retryDelays: const [],
      );
      await expectLater(
        transfers.download(
          clip: 1,
          index: 0,
          name: '图片',
          total: linuxMemoryLimit + 1,
          toDisk: false,
        ),
        throwsStateError,
      );
      final accepted = server.first;
      final download = transfers.download(
        clip: 1,
        index: 0,
        name: '图片',
        total: 2,
        toDisk: false,
      );
      final failure = expectLater(download, throwsFormatException);
      final peer = await accepted;
      final input = StreamIterator(wire.packets(peer));
      try {
        await input.moveNext();
        peer.add(wire.packet(24, wire.u64(2)));
        peer.add(wire.packet(25, [1, 2, 3]));
        await failure;
      } finally {
        transfers.close();
        peer.destroy();
        await input.cancel();
        await server.close();
      }
    },
  );

  test(
    'pinned images, arbitrary data and files survive reload independently of the source',
    () async {
      final source = File('${dir.path}/source.txt')
        ..writeAsStringSync('original');
      final copies = [
        LinuxCopy(
          'image',
          bytes: Uint8List.fromList([1, 2, 3]),
          uti: 'public.png',
        ),
        LinuxCopy(
          'data',
          bytes: Uint8List.fromList([4, 5]),
          uti: 'application/x-rapp-test',
        ),
        LinuxCopy('files', files: [source.path]),
      ];
      for (final copy in copies) {
        final path = await saveLinuxCopy(
          copy,
          '${dir.path}/text',
          '${dir.path}/pins',
          'same',
        );
        final loaded = await loadLinuxCopy(path);
        expect(loaded!.kind, copy.kind);
        if (copy.kind == 'files') {
          source.deleteSync();
          expect(File(loaded.files.single).readAsStringSync(), 'original');
        } else {
          expect(loaded.bytes, copy.bytes);
          expect(loaded.uti, copy.uti);
        }
      }
      expect(
        Directory(
          '${dir.path}/pins',
        ).listSync().where((e) => e.path.split('/').last.startsWith('.')),
        isEmpty,
      );
    },
  );
}
