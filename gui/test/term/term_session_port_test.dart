import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/term/term_session_port.dart';

import '../fakes.dart';

Map<String, Object?> pane(String id, String win, String command, {bool active = false}) => {
      'id': id, 'win': win, 'window': command, 'title': command, 'command': command,
      'cols': 80, 'rows': 24, 'dead': false, 'active': active,
    };

Map<String, Object?> screenJson(String pane, {required int rev, String text = 'hi'}) => {
      't': 'screen', 'pane': pane, 'rev': rev, 'cols': 80, 'rows': 1, 'cx': 0, 'cy': 0,
      'cursor': true, 'alt': false, 'full': true, 'more': false,
      'lines': [[0, text]],
    };

Future<void> pumpUntil(bool Function() ok) async {
  for (var i = 0; i < 300 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue, reason: 'timed out');
}

String line(Object? m) => '${jsonEncode(m)}\n';

class Worker {
  final sockets = <Socket>[];
  final got = <String>[];
  late final ServerSocket srv;
  void Function(Socket s)? onConnect;
  static Future<Worker> start([void Function(Socket s)? onConnect]) async {
    final w = Worker()..onConnect = onConnect;
    w.srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    w.srv.listen((s) {
      w.sockets.add(s);
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(w.got.add, onError: (_) {});
      w.onConnect?.call(s);
    });
    return w;
  }

  Future<void> stop() async {
    for (final s in sockets) {
      s.destroy();
    }
    await srv.close();
  }
}

void main() {
  late Worker w;
  late TermSessionPort port;
  late List<SessionEvent> events;

  Future<void> begin(Worker worker, {Duration traffic = const Duration(seconds: 1)}) async {
    w = worker;
    port = TermSessionPort(trafficEvery: traffic);
    events = [];
    port.events.listen(events.add);
    await port.start(StartArgs(1, w.srv.port, 'tk', 'x', 0, 'x'));
  }

  tearDown(() async {
    port.dispose();
    await w.stop();
  });

  test('start sends the token, answers screens with acks, and reports panes and traffic', () async {
    await begin(
        await Worker.start((s) {
          s.write(line({'t': 'hello', 'v': 1, 'backend': 'tmux'}));
          s.write(line({'t': 'panes', 'panes': [pane('%3', '@1', 'claude', active: true)]}));
          s.write(line(screenJson('%3', rev: 7)));
        }),
        traffic: const Duration(milliseconds: 50));
    expect(port.owns(1), isTrue);
    port.view(1, 3, 80, 24);
    await pumpUntil(() => w.got.contains(jsonEncode({'t': 'ack', 'rev': 7})));
    expect(w.got.first, 'tk');
    final win = events.whereType<WindowsEvent>().single.windows.single;
    expect((win.id, win.title, win.focused), (3, '1 claude', true));
    expect(events.whereType<ReadyEvent>().single.appName, 'claude');
    await pumpUntil(() => events.whereType<TrafficEvent>().any((e) => e.bytes > 0));
    expect(port.pane(1, 3)!.command, 'claude');
  });

  test('view is not resent on one connection, but is on a new start', () async {
    await begin(await Worker.start());
    port.view(1, 3, 80, 24);
    port.view(1, 3, 80, 24);
    port.view(1, 3, 100, 24);
    await pumpUntil(() => w.got.length >= 3);
    expect(w.got.where((l) => l.contains('"view"')).length, 2);
    await port.start(StartArgs(1, w.srv.port, 'tk', 'x', 0, 'x'));
    port.view(1, 3, 100, 24);
    await pumpUntil(() => w.got.where((l) => l.contains('"view"')).length == 3);
    port.refit(1);
    await pumpUntil(() => w.got.any((l) => l.contains('"refit"')));
    expect(w.got.last, jsonEncode({'t': 'refit', 'pane': '%3', 'cols': 100, 'rows': 24}));
  });

  test('a line split in the middle of a Chinese character is put back together', () async {
    final bytes = utf8.encode(line(screenJson('%3', rev: 1, text: '中文')));
    final cut = bytes.indexOf(utf8.encode('中')[0]) + 1;
    await begin(await Worker.start((s) async {
      s.add(bytes.sublist(0, cut));
      await s.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      s.add(bytes.sublist(cut));
    }));
    port.view(1, 3, 80, 24);
    await pumpUntil(() => port.model(1)!.screen.isNotEmpty);
    expect(port.model(1)!.screen.first.text, contains('中文'));
  });

  test('a line over 64 KiB is dropped and the link stays up', () async {
    await begin(await Worker.start((s) {
      s.write('${'x' * 70000}\n');
      s.write(line(screenJson('%3', rev: 5)));
    }));
    await pumpUntil(() => w.got.contains(jsonEncode({'t': 'ack', 'rev': 5})));
    expect(events.whereType<DisconnectedEvent>(), isEmpty);
  });

  test('the worker going away is one DisconnectedEvent; close is one ClosedEvent', () async {
    await begin(await Worker.start());
    await pumpUntil(() => w.sockets.isNotEmpty);
    w.sockets.single.destroy();
    await pumpUntil(() => events.whereType<DisconnectedEvent>().isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events.whereType<DisconnectedEvent>().single.reason, 'connection lost');
    expect(port.model(1), isNotNull);
    port.close(1);
    await pumpUntil(() => events.whereType<ClosedEvent>().isNotEmpty);
    expect(events.whereType<ClosedEvent>().single.reason, 'closed');
    expect(port.owns(1), isFalse);
    expect(events.whereType<DisconnectedEvent>().length, 1);
  });

  test('close does not report a lost connection', () async {
    await begin(await Worker.start());
    port.close(1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(events.whereType<DisconnectedEvent>(), isEmpty);
    expect(events.whereType<ClosedEvent>().length, 1);
  });

  test('session ended disconnects; other errors go to the model', () async {
    await begin(await Worker.start((s) {
      s.write(line({'t': 'error', 'error': 'no such pane'}));
    }));
    await pumpUntil(() => port.model(1)!.note == 'no such pane');
    w.sockets.single.write(line({'t': 'error', 'error': 'session ended'}));
    await pumpUntil(() => events.whereType<DisconnectedEvent>().isNotEmpty);
    expect(events.whereType<DisconnectedEvent>().single.reason, 'session ended');
  });

  test('a screen for the pane switched away from is still acked', () async {
    await begin(await Worker.start());
    port.view(1, 3, 80, 24);
    port.view(1, 4, 80, 24);
    await pumpUntil(() => w.got.where((l) => l.contains('"view"')).length == 2);
    w.sockets.single.write(line(screenJson('%3', rev: 9)));
    await pumpUntil(() => w.got.contains(jsonEncode({'t': 'ack', 'rev': 9})));
  });

  test('calls for app sessions are ignored', () async {
    await begin(await Worker.start());
    port.resize(1, 3, 10, 10);
    port.selectInput(1, 'x');
    port.key(1, 1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(w.got, ['tk']);
  });

  test('a failed connection throws and owns nothing', () async {
    port = TermSessionPort();
    w = await Worker.start();
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = dead.port;
    await dead.close();
    await expectLater(port.start(StartArgs(2, p, 'tk', 'x', 0, 'x')), throwsA(isA<SocketException>()));
    expect(port.owns(2), isFalse);
  });

  test('the fake records calls without a network', () async {
    final f = FakeTermSessionPort();
    await f.start(StartArgs(1, 1, 't', 'x', 0, 'x'));
    f.view(1, 3, 80, 24);
    expect(f.owns(1), isTrue);
    expect(f.calls.map((c) => c.$1), ['start', 'view']);
  });
}
