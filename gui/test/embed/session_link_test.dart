import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_link.dart';
import 'package:rapp/embed/session_worker.dart';

void main() {
  test('ProcessSessionLinks.check names a missing executable', () async {
    await expectLater(ProcessSessionLinks('/nope/rapp-session').check(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('rapp-session not found'))));
  });

  test('ProcessSessionLink passes packets, lines and close through', () async {
    // 子进程读一行命令，回一个管道格式的包：长度 3（u32 LE），种类 0，内容就是那一行；再等输入关掉
    final proc = await Process.start('sh', ['-c', r'''read line; printf '\003\000\000\000\000'; printf '%s' "$line"; cat >/dev/null''']);
    final link = ProcessSessionLink(SessionWorker.fromProcess(proc));
    final first = link.packets.first;
    link.send('{}');
    expect(await first, [0, 0x7b, 0x7d]);
    link.ack(); // 子进程那边是空操作：不抛、不往输入里写东西
    await link.close();
    expect(await link.exitCode, 0);
    expect(link.id, proc.pid);
  }, skip: Platform.isWindows ? '要 sh' : null);

  test('a worker that exits early gives no packets and its exit code', () async {
    final link = ProcessSessionLink(SessionWorker.fromProcess(await Process.start('sh', ['-c', 'exit 3'])));
    expect(await link.packets.toList(), isEmpty);
    expect(await link.exitCode, 3);
    link.kill(); // 已经结束，再杀不抛
  }, skip: Platform.isWindows ? '要 sh' : null);
}
