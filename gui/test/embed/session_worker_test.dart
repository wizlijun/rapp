import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_worker.dart';

void main() {
  if (Platform.isWindows) {
    test('SessionWorker subprocess tests on Windows', () {}, skip: 'C 段做完时打开');
    return;
  }
  late Directory temp;
  Future<String> fixture(String body) async {
    final file = File('${temp.path}/worker.py');
    await file.writeAsString('#!/usr/bin/python3\n$body');
    await Process.run('chmod', ['+x', file.path]);
    return file.path;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rapp-worker-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('isolated pipe preserves large fragmented packets and exits', () async {
    final executable = await fixture('''
import sys,struct
for value in range(3):
 data=bytes([value])*1048576
 sys.stdout.buffer.write(struct.pack('<I',len(data))+data)
 sys.stdout.buffer.flush()
''');
    final worker = await SessionWorker.start(executable);
    var count = 0;
    await for (final packet in worker.packets) {
      expect(packet.length, 1048576);
      expect(packet.every((byte) => byte == count), isTrue);
      count++;
    }
    expect(count, 3);
    expect(await worker.exitCode, 0);
  });

  test(
    'input remains live while packet consumer pauses; cancel reaps child',
    () async {
      final marker = File('${temp.path}/input');
      final executable = await fixture('''
import sys,struct,threading,time
from pathlib import Path
def read():
 for line in sys.stdin:
  Path(__file__).with_name('input').write_text(line)
threading.Thread(target=read,daemon=True).start()
while True:
 sys.stdout.buffer.write(struct.pack('<I',1)+b'x')
 sys.stdout.buffer.flush()
 time.sleep(.01)
''');
      final worker = await SessionWorker.start(executable);
      addTearDown(() {
        worker.kill(ProcessSignal.sigkill);
      });
      final iterator = StreamIterator(worker.packets);
      expect(await iterator.moveNext(), isTrue);
      worker.send('still responsive');
      for (var n = 0; n < 100 && !await marker.exists(); n++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await marker.readAsString(), 'still responsive\n');
      await iterator.cancel();
      await worker.exitCode.timeout(const Duration(seconds: 3));
      expect(Process.killPid(worker.pid, ProcessSignal.sigcont), isFalse);
    },
  );

  test('missing executable fails promptly', () async {
    await expectLater(
      SessionWorker.start('${temp.path}/missing'),
      throwsStateError,
    );
  });

  test(
    'child exit is reported before its buffered packet is consumed',
    () async {
      final executable = await fixture(
        "import sys,struct\nsys.stdout.buffer.write(struct.pack('<I',1)+b'x')\n",
      );
      final worker = await SessionWorker.start(executable);
      addTearDown(() => worker.kill(ProcessSignal.sigkill));
      expect(await worker.exitCode.timeout(const Duration(seconds: 3)), 0);
      expect(await worker.packets.toList(), [
        [120],
      ]);
    },
  );

  test(
    'late input after close cannot crash the reader or orphan the child',
    () async {
      final executable = await fixture('''
import sys,struct,time
sys.stdin.read()
time.sleep(.05)
sys.stdout.buffer.write(struct.pack('<I',1)+b'x')
''');
      final worker = await SessionWorker.start(executable);
      addTearDown(() => worker.kill(ProcessSignal.sigkill));
      final packets = worker.packets.toList();
      final closed = worker.closeInput();
      worker.send('late input');
      await closed;
      expect(await worker.exitCode.timeout(const Duration(seconds: 3)), 0);
      expect(await packets, [
        [120],
      ]);
    },
  );

  test('truncated packet propagates error and terminates subprocess', () async {
    final executable = await fixture(
      "import sys,struct\nsys.stdout.buffer.write(struct.pack('<I',5)+b'x')\n",
    );
    final worker = await SessionWorker.start(executable);
    await expectLater(worker.packets.drain<void>(), throwsStateError);
    await worker.exitCode.timeout(const Duration(seconds: 3));
  });
}
