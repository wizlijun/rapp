import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/term/term_session_port.dart';

Map<String, Object?> pane(String id, String win, String command, {bool active = false, bool dead = false}) => {
      'id': id, 'win': win, 'window': command, 'title': command, 'command': command,
      'cols': 80, 'rows': 24, 'dead': dead, 'active': active,
    };

Future<void> pumpUntil(bool Function() ok) async {
  for (var i = 0; i < 300 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue, reason: 'timed out');
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

String line(Object? m) => '${jsonEncode(m)}\n';

/// A local worker: says hello and shows panes %3 and %4 (and a dead %5), records every line it gets.
class Worker {
  final sockets = <Socket>[];
  final got = <Map<String, Object?>>[];
  late final ServerSocket srv;
  void Function(Socket s, Map<String, Object?> m)? onLine;

  static Future<Worker> start({int v = 2, void Function(Socket s, Map<String, Object?> m)? onLine}) async {
    final w = Worker()..onLine = onLine;
    w.srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    w.srv.listen((s) {
      w.sockets.add(s);
      var first = true;
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        if (first) {
          first = false;
          return; // the token
        }
        final m = (jsonDecode(l) as Map).cast<String, Object?>();
        w.got.add(m);
        w.onLine?.call(s, m);
      }, onError: (_) {});
      s.write(line({'t': 'hello', 'v': v, 'backend': 'tmux'}));
      s.write(line({'t': 'panes', 'panes': [
        pane('%3', '@1', 'claude', active: true),
        pane('%4', '@2', 'nvim'),
        pane('%5', '@3', 'logs', dead: true),
      ]}));
    });
    return w;
  }

  Iterable<Map<String, Object?>> of(String t) => got.where((m) => m['t'] == t);

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

  Future<void> begin(Worker worker) async {
    w = worker;
    port = TermSessionPort();
    events = [];
    port.events.listen(events.add);
    await port.start(StartArgs(1, w.srv.port, 'tk', 'x', 0, 'x'));
    await pumpUntil(() => port.panes(1).length == 3);
  }

  tearDown(() async {
    port.dispose();
    await w.stop();
  });

  test('keys and text go to the pane being viewed; the writing panel keys map to names', () async {
    await begin(await Worker.start());
    port.view(1, 3, 80, 24);
    port.sendKeys(1, ['Ctrl-c', 'Up']);
    port.type(1, '\u001b\r');
    port.key(1, 36, 0);
    port.key(1, 0, 0); // A: not a key the panel uses, dropped
    port.view(1, 4, 80, 24);
    port.key(1, 53, 0);
    await pumpUntil(() => w.of('keys').length == 3);
    await settle();
    expect(w.of('keys').toList(), [
      {'t': 'keys', 'pane': '%3', 'keys': ['Ctrl-c', 'Up']},
      {'t': 'keys', 'pane': '%3', 'keys': ['Enter']},
      {'t': 'keys', 'pane': '%4', 'keys': ['Esc']},
    ]);
    expect(w.of('type').single, {'t': 'type', 'pane': '%3', 'text': '\u001b\r'});
  });

  test('every key code the writing panel sends has its name', () async {
    await begin(await Worker.start());
    port.view(1, 3, 80, 24);
    for (final c in [36, 53, 48, 51, 123, 124, 125, 126, 116, 121]) {
      port.key(1, c, 0);
    }
    await pumpUntil(() => w.of('keys').length == 10);
    expect([for (final m in w.of('keys')) (m['keys'] as List).single],
        ['Enter', 'Esc', 'Tab', 'Backspace', 'Left', 'Right', 'Down', 'Up', 'PageUp', 'PageDown']);
  });

  test('a dead pane, no pane yet, or a dropped link gets no keys and nothing is kept for later', () async {
    await begin(await Worker.start());
    port.sendKeys(1, ['Enter']); // nothing viewed yet
    port.view(1, 5, 80, 24);
    port.sendKeys(1, ['Enter']);
    port.type(1, 'x');
    port.key(1, 36, 0);
    await settle();
    expect(w.of('keys'), isEmpty);
    expect(w.of('type'), isEmpty);
    port.view(1, 3, 80, 24);
    w.sockets.single.destroy();
    await pumpUntil(() => events.whereType<DisconnectedEvent>().isNotEmpty);
    port.sendKeys(1, ['Enter']);
    port.type(1, 'x');
    await settle();
    expect(w.of('keys'), isEmpty);
    expect(w.of('type'), isEmpty);
  });

  test('a paste over several lines waits for one pasted; the next waits its turn', () async {
    await begin(await Worker.start(onLine: (s, m) {
      if (m['t'] == 'text' && m['more'] == false) s.write(line({'t': 'pasted', 'ok': true}));
    }));
    port.view(1, 3, 80, 24);
    final big = '中文测' * 7778;
    final a = port.paste(1, big, enter: true);
    final b = port.paste(1, 'second');
    expect(await a, isNull);
    expect(await b, isNull);
    final texts = w.of('text').toList();
    expect(texts.length, greaterThan(2));
    expect(texts.sublist(0, texts.length - 1).map((m) => m['data']).join(), big);
    expect(texts[texts.length - 2]['enter'], true);
    expect(texts.last, {'t': 'text', 'pane': '%3', 'data': 'second', 'enter': false, 'more': false});
  });

  test('switching tabs mid-paste: each paste goes to its own pane and its own answer', () async {
    final sockets = <Socket>[];
    await begin(await Worker.start(onLine: (s, m) {
      if (m['t'] == 'text') sockets.add(s);
    }));
    port.view(1, 3, 80, 24);
    final a = port.paste(1, 'one');
    port.view(1, 4, 80, 24);
    final b = port.paste(1, 'two');
    await pumpUntil(() => w.of('text').isNotEmpty);
    await settle();
    // The second waits for the first's answer.
    expect(w.of('text').toList(), [
      {'t': 'text', 'pane': '%3', 'data': 'one', 'enter': false, 'more': false},
    ]);
    var aDone = false, bDone = false;
    String? aGot = 'unset';
    unawaited(a.then((v) {
      aDone = true;
      aGot = v;
    }));
    unawaited(b.then((_) => bDone = true));
    sockets.first.write(line({'t': 'pasted', 'ok': false, 'error': 'pane is gone'}));
    await pumpUntil(() => aDone);
    expect(aGot, 'pane is gone');
    expect(bDone, isFalse);
    await pumpUntil(() => w.of('text').length == 2);
    expect(w.of('text').last['pane'], '%4');
    sockets.first.write(line({'t': 'pasted', 'ok': false}));
    expect(await b, '没有贴进去');
  });

  test('a paste over 1 MiB is not sent and says why', () async {
    await begin(await Worker.start());
    port.view(1, 3, 80, 24);
    expect(await port.paste(1, 'x' * (1048576 + 1)), '太长了：终端一次最多贴 1 MiB');
    await settle();
    expect(w.of('text'), isEmpty);
  });

  test('a paste with no link, no pane, or into a dead pane does not go out', () async {
    await begin(await Worker.start());
    expect(await port.paste(1, 'x'), '没有贴进去'); // nothing viewed
    port.view(1, 5, 80, 24);
    expect(await port.paste(1, 'x'), '没有贴进去');
    port.view(1, 3, 80, 24);
    w.sockets.single.destroy();
    await pumpUntil(() => events.whereType<DisconnectedEvent>().isNotEmpty);
    expect(await port.paste(1, 'x'), '连接断了');
    await settle();
    expect(w.of('text'), isEmpty);
  });

  test('the link dropping ends every paste still waiting with 连接断了', () async {
    await begin(await Worker.start());
    port.view(1, 3, 80, 24);
    final a = port.paste(1, 'one'), b = port.paste(1, 'two');
    await pumpUntil(() => w.of('text').isNotEmpty);
    w.sockets.single.destroy();
    expect(await a, '连接断了');
    expect(await b, '连接断了');
  });

  test('closing the session ends pastes and new windows still waiting', () async {
    await begin(await Worker.start());
    port.view(1, 3, 80, 24);
    final a = port.paste(1, 'one'), n = port.newWindow(1);
    await pumpUntil(() => w.of('new_window').isNotEmpty);
    port.close(1);
    expect(await a, '连接断了');
    expect(await n, '连接断了');
  });

  test('an old device cannot open windows; a new one can', () async {
    await begin(await Worker.start(v: 1));
    await pumpUntil(() => port.panes(1).isNotEmpty);
    expect(port.canNewWindow(1), isFalse);
    expect(port.canNewWindow(99), isFalse);
    port.dispose();
    await w.stop();
    await begin(await Worker.start());
    expect(port.canNewWindow(1), isTrue);
  });

  test('a new window answers null, then its pane opens once it is in the pane list', () async {
    late Socket sock;
    await begin(await Worker.start(onLine: (s, m) {
      if (m['t'] == 'new_window') {
        sock = s;
        s.write(line({'t': 'window_opened', 'pane': '%7'}));
      }
    }));
    port.view(1, 4, 80, 24);
    expect(await port.newWindow(1), isNull);
    expect(w.of('new_window').single, {'t': 'new_window', 'pane': '%4'});
    await settle();
    expect(events.whereType<TermOpenedPaneEvent>(), isEmpty);
    sock.write(line({'t': 'panes', 'panes': [pane('%3', '@1', 'claude', active: true), pane('%4', '@2', 'nvim')]}));
    await settle();
    expect(events.whereType<TermOpenedPaneEvent>(), isEmpty);
    sock.write(line({'t': 'panes', 'panes': [
      pane('%3', '@1', 'claude', active: true), pane('%4', '@2', 'nvim'), pane('%7', '@4', 'zsh'),
    ]}));
    await pumpUntil(() => events.whereType<TermOpenedPaneEvent>().isNotEmpty);
    final e = events.whereType<TermOpenedPaneEvent>().single;
    expect((e.sid, e.window), (1, 7));
    // A WindowsEvent with the new pane went out before it.
    final wi = events.lastIndexWhere((e) => e is WindowsEvent && e.windows.any((w) => w.id == 7));
    expect(wi, lessThan(events.indexOf(e)));
  });

  test('a new window already in the pane list when window_opened comes opens at once', () async {
    await begin(await Worker.start(onLine: (s, m) {
      if (m['t'] == 'new_window') {
        s.write(line({'t': 'panes', 'panes': [pane('%3', '@1', 'claude', active: true), pane('%7', '@4', 'zsh')]}));
        s.write(line({'t': 'window_opened', 'pane': '%7'}));
      }
    }));
    port.view(1, 3, 80, 24);
    expect(await port.newWindow(1), isNull);
    await pumpUntil(() => events.whereType<TermOpenedPaneEvent>().isNotEmpty);
    expect(events.whereType<TermOpenedPaneEvent>().single.window, 7);
  });

  test('a new window that could not open answers the device words and leaves the screen alone', () async {
    await begin(await Worker.start(onLine: (s, m) {
      if (m['t'] == 'new_window') s.write(line({'t': 'error', 'error': 'could not open a window'}));
    }));
    port.view(1, 3, 80, 24);
    expect(await port.newWindow(1), 'could not open a window');
    expect(port.model(1)!.note, isNull);
  });

  test('lastCols and lastRows are the latest view sent', () async {
    await begin(await Worker.start());
    expect((port.lastCols, port.lastRows), (null, null));
    port.view(1, 3, 80, 24);
    port.view(1, 3, 132, 50);
    expect((port.lastCols, port.lastRows), (132, 50));
  });
}
