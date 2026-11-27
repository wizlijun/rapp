import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/worker_session_port.dart';
import 'package:rapp/embed/linux_session_host.dart';
import 'package:rapp/embed/session_link.dart';
import 'package:rapp/embed/session_worker.dart';
import 'package:rapp/embed/modifier_latch.dart';
import 'package:rapp/embed/session_port.dart';

const aDown = KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: LogicalKeyboardKey.keyA, character: 'a', timeStamp: Duration.zero);
const aRepeat = KeyRepeatEvent(physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: LogicalKeyboardKey.keyA, character: 'a', timeStamp: Duration.zero);
const aUp = KeyUpEvent(physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: LogicalKeyboardKey.keyA, timeStamp: Duration.zero);

Future<List<(int, int, bool)>> keysDuring(
    Future<void> Function(WorkerSessionPort, List<SessionEvent>) body) async {
  final process = await Process.start('cat', const []);
  final output = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).toList();
  final port = WorkerSessionPort(ProcessSessionLinks('unused'), LinuxSessionHost(), framePresented: () async {});
  port.seedSessionForTest(3, ProcessSessionLink(SessionWorker.fromProcess(process)));
  final events = <SessionEvent>[];
  final sub = port.events.listen(events.add);
  try {
    await body(port, events);
  } finally {
    port.dispose();
    await sub.cancel();
  }
  return [for (final line in await output.timeout(const Duration(seconds: 5)))
    if (jsonDecode(line) case final Map m when m['cmd'] == 'key')
      (m['keyCode'] as int, m['modifiers'] as int, m['down'] as bool),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the app key bar sends modifier down/up and consumes a once latch on a hardware key', () async {
    final keys = await keysDuring((port, events) async {
      final latch = ModifierLatch();
      final sender = AppKeySender(sid: 3, latch: latch, port: () => port)..start();
      try {
        latch.tap(latchCtrl);
        await port.invoke('picture_focus', {'sid': 3, 'compose': true});
        expect(port.handleKeyEvent(3, aDown), true);
        await Future<void>.delayed(Duration.zero);
        expect(events.whereType<ComposerInsertEvent>(), isEmpty);
        expect(events.whereType<LatchUsedEvent>().map((e) => e.sid), [3]);
        expect(latch.flags, 0);
        // Repeats and the release belong to this stroke, even after the once latch went out.
        port.handleKeyEvent(3, aRepeat);
        port.handleKeyEvent(3, aUp);
        await port.invoke('picture_focus', {'sid': 3});
        port.handleKeyEvent(3, aDown);
        port.handleKeyEvent(3, aUp);
      } finally {
        sender.stop();
        latch.dispose();
      }
    });
    expect(keys, [(59, latchCtrl, true), (0, latchCtrl, true), (59, 0, false),
      (0, latchCtrl, true), (0, latchCtrl, false), (0, 0, true), (0, 0, false)]);
  }, skip: !Platform.isLinux);

  test('a locked modifier is rearmed for the next hardware stroke and released when the bar goes away', () async {
    final keys = await keysDuring((port, events) async {
      final latch = ModifierLatch();
      final sender = AppKeySender(sid: 3, latch: latch, port: () => port)..start();
      try {
        latch.tap(latchCmd);
        latch.tap(latchCmd, sinceLast: Duration.zero);
        for (var i = 0; i < 2; i++) {
          port.handleKeyEvent(3, aDown);
          await Future<void>.delayed(Duration.zero);
          port.handleKeyEvent(3, aUp);
          expect(latch.of(latchCmd), LatchState.locked);
        }
        expect(events.whereType<LatchUsedEvent>(), hasLength(2));
      } finally {
        sender.stop();
        latch.dispose();
      }
      port.handleKeyEvent(3, aDown);
      port.handleKeyEvent(3, aUp);
    });
    expect(keys, [(55, latchCmd, true), (0, latchCmd, true), (0, latchCmd, false),
      (0, latchCmd, true), (0, latchCmd, false), (55, 0, false), (0, 0, true), (0, 0, false)]);
  }, skip: !Platform.isLinux);

  test('focus loss clears hardware strokes and a pending latch; an unrelated session cannot set it', () async {
    final keys = await keysDuring((port, events) async {
      await port.invoke('latch', {'sid': 3, 'modifiers': latchOpt});
      port.handleKeyEvent(3, aDown);
      await port.invoke('picture_focus', {'sid': null});
      await port.invoke('picture_focus', {'sid': 3});
      await port.invoke('latch', {'sid': 99, 'modifiers': latchCmd});
      port.handleKeyEvent(3, aDown);
      port.handleKeyEvent(3, aUp);
      await port.invoke('latch', {'sid': 3, 'modifiers': latchCtrl});
      await port.invoke('picture_focus', {'sid': null});
      await port.invoke('picture_focus', {'sid': 3});
      port.handleKeyEvent(3, aDown);
      port.handleKeyEvent(3, aUp);
    });
    expect(keys, [(0, latchOpt, true), (0, 0, false),
      (0, 0, true), (0, 0, false), (0, 0, true), (0, 0, false)]);
  }, skip: !Platform.isLinux);

  test('modifiers and a local-only key leave the pending latch for the next remote letter', () async {
    final keys = await keysDuring((port, events) async {
      await port.invoke('latch', {'sid': 3, 'modifiers': latchCtrl});
      expect(port.handleKeyEvent(3, const KeyDownEvent(physicalKey: PhysicalKeyboardKey.f11,
          logicalKey: LogicalKeyboardKey.f11, timeStamp: Duration.zero)), false);
      port.handleKeyEvent(3, const KeyDownEvent(physicalKey: PhysicalKeyboardKey.shiftLeft,
          logicalKey: LogicalKeyboardKey.shiftLeft, timeStamp: Duration.zero));
      port.handleKeyEvent(3, const KeyUpEvent(physicalKey: PhysicalKeyboardKey.shiftLeft,
          logicalKey: LogicalKeyboardKey.shiftLeft, timeStamp: Duration.zero));
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<LatchUsedEvent>(), isEmpty);
      port.handleKeyEvent(3, aDown);
      port.handleKeyEvent(3, aUp);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<LatchUsedEvent>().map((e) => e.sid), [3]);
    });
    expect(keys, [(56, latchCtrl, true), (56, latchCtrl, false),
      (0, latchCtrl, true), (0, latchCtrl, false)]);
  }, skip: !Platform.isLinux);
}
