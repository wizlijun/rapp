// Release-mode regression fixture for Flutter's Linux process-pipe scheduling.
// Build: flutter --no-version-check build linux --release -t benchmark/linux_session_pipe.dart
// Run the benchmark bundle on a test display (not the installed rapp binary).
// Requires python3. No network, app state, or rapp services are used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:rapp/embed/session_worker.dart';

const width = 3840, height = 2160, frameCount = 10;
final picture = ValueNotifier<ui.Image?>(null);

Future<void> draw(Uint8List packet) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(
    Uint8List.sublistView(packet, 25),
  );
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.bgra8888,
  );
  ui.Codec? codec;
  try {
    codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final old = picture.value;
    picture.value = frame.image;
    await WidgetsBinding.instance.endOfFrame;
    old?.dispose();
  } finally {
    codec?.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: ValueListenableBuilder<ui.Image?>(
        valueListenable: picture,
        builder: (_, value, _) => RawImage(image: value, fit: BoxFit.contain),
      ),
    ),
  );
  final temp = await Directory.systemTemp.createTemp('rapp-pipe-benchmark-');
  try {
    final producer = File('${temp.path}/frames.py');
    await producer.writeAsString('''#!/usr/bin/env python3
import sys,struct
w,h=$width,$height
body=b'\\1'+struct.pack('<IIffff',w,h,0.,0.,w,h)+bytes([40,40,40,255])*(w*h)
for i in range($frameCount):
 sys.stdout.buffer.write(struct.pack('<I',len(body))+body)
 sys.stdout.buffer.flush()
''');
    if ((await Process.run('chmod', ['+x', producer.path])).exitCode != 0) {
      throw StateError('Cannot make benchmark producer executable');
    }
    await WidgetsBinding.instance.endOfFrame;
    for (final isolated in [false, true]) {
      final worker = isolated
          ? await SessionWorker.start(producer.path)
          : SessionWorker.fromProcess(await Process.start(producer.path, []));
      final packets = StreamIterator(worker.packets);
      final total = Stopwatch()..start();
      final reads = <double>[];
      try {
        while (true) {
          final read = Stopwatch()..start();
          if (!await packets.moveNext()) break;
          reads.add(read.elapsedMicroseconds / 1000);
          if (packets.current.length != 25 + width * height * 4) {
            throw StateError('Wrong frame size');
          }
          await draw(packets.current);
        }
        if (reads.length != frameCount || await worker.exitCode != 0) {
          throw StateError('Incomplete benchmark');
        }
        reads.sort();
        stderr.writeln(
          'SESSION_PIPE_BENCH ${jsonEncode({'isolated': isolated, 'frames': reads.length, 'total_ms': total.elapsedMilliseconds, 'read_p50_ms': reads[reads.length ~/ 2], 'read_max_ms': reads.last})}',
        );
      } finally {
        await packets.cancel();
        worker.kill();
      }
    }
  } finally {
    await temp.delete(recursive: true);
  }
  picture.value?.dispose();
  exit(0);
}
