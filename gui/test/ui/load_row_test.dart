import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/load_model.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/load_row.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/overview.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import 'helpers.dart';
import 'platform_helpers.dart';

const gb = 1000000000;

/// [top]: the device says it can list its processes.
Map<String, dynamic> snapshot({List<Map<String, dynamic>> warnings = const [], bool top = false}) => {
      'at': 1764100000, 'headroom': 30, 'tightest': 'disk', 'term': true,
      if (top) 'top': true,
      'items': {
        'cpu': {'pct': 42.0, 'cores': 8, 'load1': 3.5},
        'mem': {'total': 16 * gb, 'avail': 8 * gb, 'swap_used': gb, 'pressure': 'normal'},
        'heat': {'level': 'normal'},
      },
      'disks': [
        {
          'mount': '/', 'total': 100 * gb, 'avail': 6 * gb, 'level': 'warn',
          'paths': [
            {'kind': 'home', 'path': '/Users/x'},
            {'kind': 'term', 'path': '/Users/x/git/rapp', 'term': 't1'},
          ],
        },
        {'mount': '/Volumes/nas', 'unreadable': true, 'paths': [{'kind': 'data', 'path': '/Volumes/nas/d'}]},
      ],
      'warnings': warnings,
      'history': [
        for (var i = 0; i < 20; i++) {'at': 1764100000 - 5 * (19 - i), 'cpu': 30.0 + i, 'mem': 0.5, 'heat': 0, 'disk': 0.06},
      ],
    };

DeviceLoad load({String? level, bool top = false}) => DeviceLoad.fromJson(snapshot(top: top, warnings: [
      if (level != null) {'item': 'disk:/', 'level': level, 'text': '磁盘只剩 6.0 GB（/，剩 6%）'},
    ]));

/// A local service that answers `status` and `subscribe`, and logs every command.
class _Service {
  late ServerSocket server;
  final received = <String>[];
  final _all = <Socket>[];

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      _all.add(s);
      var authed = false;
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final m = jsonDecode(line) as Map<String, dynamic>;
        if (!authed) {
          authed = true;
          return;
        }
        received.add('${m['cmd']}');
        s.write(m['cmd'] == 'status' ? '{"ok":true,"id":"1","name":"me"}\n' : '{"ok":true}\n');
      }, onError: (_) {});
    });
  }

  Future<void> stop() async {
    for (final s in _all) {
      s.destroy();
    }
    await server.close();
  }
}

void main() {
  group('LoadRow', () {
    Color colourOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style!.color!;

    testWidgets('load_row_three_colours', (tester) async {
      for (final (level, pick) in [
        (null, (RappTokens t) => t.muted),
        ('warn', (RappTokens t) => t.warn),
        ('danger', (RappTokens t) => t.danger),
      ]) {
        await tester.pumpWidget(wrap(LoadRow(id: 'm1', load: load(level: level))));
        final t = RappTokens.of(tester.element(find.byType(LoadRow)));
        expect(find.text('余力'), findsOneWidget);
        expect(find.byKey(const Key('load-bar-m1')), findsOneWidget);
        expect(colourOf(tester, '磁盘 剩 6%'), pick(t), reason: '$level');
      }
    });

    testWidgets('the warning colours differ from muted and from each other in every theme', (tester) async {
      for (final th in RappTheme.values) {
        final t = tokensFor(th);
        expect({t.muted, t.warn, t.danger}.length, 3, reason: '$th');
      }
    });

    testWidgets('no load: nothing', (tester) async {
      await tester.pumpWidget(wrap(const LoadRow(id: 'm1', load: null)));
      expect(find.text('余力'), findsNothing);
      expect(find.byKey(const Key('load-bar-m1')), findsNothing);
    });

    testWidgets('load_detail_opens', (tester) async {
      var asked = <bool>[];
      await tester.pumpWidget(wrap(LoadRow(
        id: 'm1',
        load: load(level: 'warn', top: true),
        loadNow: ({bool top = false}) async {
          asked.add(top);
          return <String, dynamic>{'at': 1};
        },
      )));
      await tester.tap(find.byKey(const Key('load-row-m1')));
      await tester.pumpAndSettle();
      expect(find.byType(LoadDetail), findsOneWidget);
      expect(find.textContaining('/Volumes/nas'), findsOneWidget);
      expect(find.textContaining('读不到'), findsOneWidget); // the hung disk
      expect(find.text('/'), findsOneWidget);
      expect(find.textContaining('~/git/rapp'), findsOneWidget);
      expect(find.byType(Sparkline), findsWidgets);
      expect(find.text('看占用最多的进程'), findsOneWidget);
      // Under the row.
      expect(tester.getTopLeft(find.byType(LoadDetail)).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(find.byKey(const Key('load-row-m1'))).dy));

      // A short window: the detail scrolls.
      await tester.ensureVisible(find.text('看占用最多的进程'));
      await tester.pump();
      await tester.tap(find.text('看占用最多的进程'));
      await tester.pumpAndSettle();
      expect(asked, [true]);
      expect(find.textContaining('读不到'), findsNWidgets(2)); // the disk, and now the processes
    });
  });

  testWidgets('load_detail_top_hidden_without_capability', (tester) async {
    var asked = 0;
    await tester.pumpWidget(wrap(LoadRow(
      id: 'm1',
      load: load(level: 'warn'),
      loadNow: ({bool top = false}) async {
        asked++;
        return <String, dynamic>{'at': 1};
      },
    )));
    await tester.tap(find.byKey(const Key('load-row-m1')));
    await tester.pumpAndSettle();
    expect(find.byType(LoadDetail), findsOneWidget);
    expect(find.text('看占用最多的进程'), findsNothing);
    expect(asked, 0);
  });

  test('canTop: false until a line carries `top`, and it stays', () {
    expect(load().canTop, isFalse);
    final l = load(top: true);
    expect(l.canTop, isTrue);
    expect(l.next({...snapshot(), 'point': {'at': 1764100005}}).canTop, isTrue);
    expect(load().next({...snapshot(top: true), 'point': {'at': 1764100005}}).canTop, isTrue);
  });

  group('an open detail', () {
    DeviceLoad cpuAt(double pct) {
      final m = snapshot();
      (m['items'] as Map)['cpu'] = {'pct': pct, 'cores': 8};
      return DeviceLoad.fromJson(m);
    }

    Future<void> openWith(WidgetTester tester, DeviceLoad l) async {
      await tester.pumpWidget(wrap(LoadRow(id: 'm1', load: l)));
      await tester.tap(find.byKey(const Key('load-row-m1')));
      await tester.pumpAndSettle();
      expect(find.byType(LoadDetail), findsOneWidget);
    }

    testWidgets('follows a new load without notifying during build', (tester) async {
      await openWith(tester, cpuAt(42));
      expect(find.textContaining('42%'), findsWidgets);
      await tester.pumpWidget(wrap(LoadRow(id: 'm1', load: cpuAt(77))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('77%'), findsWidgets);
      expect(find.byType(LoadDetail), findsOneWidget);
    });

    testWidgets('closes when the load goes', (tester) async {
      await openWith(tester, cpuAt(42));
      await tester.pumpWidget(wrap(const LoadRow(id: 'm1', load: null)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(LoadDetail, skipOffstage: false), findsNothing);
    });

    testWidgets('closing it leaves a route pushed on top alone', (tester) async {
      await openWith(tester, cpuAt(42));
      Navigator.of(tester.element(find.byType(LoadDetail)))
          .push(MaterialPageRoute<void>(builder: (_) => const Text('other route')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(wrap(const LoadRow(id: 'm1', load: null)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('other route'), findsOneWidget);
      expect(find.byType(LoadDetail, skipOffstage: false), findsNothing);
    });
  });

  group('the overview column', () {
    late FakeTransport t;
    late MainState s;
    late Directory tmp;
    var offline = <String>{};
    var now = DateTime(2026, 11, 26, 12);

    Future<void> flush() => Future<void>.delayed(Duration.zero);

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('load_row_test');
      offline = {};
      now = DateTime(2026, 11, 26, 12);
    });

    tearDown(() {
      s.dispose();
      tmp.deleteSync(recursive: true);
    });

    Future<void> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      t = FakeTransport();
      t.onSend = (m) {
        if (m['cmd'] == 'hosts') {
          t.emit({'event': 'hosts', 'req': m['req'], 'hosts': [{'id': 'm1', 'name': 'mini'}]});
        } else if (m['cmd'] == 'apps') {
          t.emit(offline.contains(m['id'])
              ? {'event': 'error', 'req': m['req'], 'error': 'connect timed out'}
              : {'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'lan', 'apps': []});
        }
      };
      s = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), clock: () => now);
      await tester.runAsync(() async {
        for (var i = 0; i < 8; i++) {
          await flush();
        }
      });
    }

    Future<void> show(WidgetTester tester, {ServiceMonitor? monitor}) async {
      s.toggleOverview();
      await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 700, child: Overview(state: s, monitor: monitor))));
      await tester.pump();
    }

    Future<void> emit(WidgetTester tester, Map<String, dynamic> m) async {
      t.emit(m);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('load_row_hidden_when_gone', (tester) async {
      await boot(tester);
      await show(tester);
      expect(find.byKey(const Key('load-bar-m1')), findsNothing); // no data yet
      await emit(tester, {'event': 'load', 'id': 'm1', ...snapshot()});
      expect(find.byKey(const Key('load-bar-m1')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('column-m1')), matching: find.byKey(const Key('load-bar-m1'))),
          findsOneWidget);
      await emit(tester, {'event': 'load', 'id': 'm1', 'gone': true});
      expect(find.byKey(const Key('load-bar-m1')), findsNothing);
    });

    testWidgets('load_row_hidden_when_stale: no line for more than 20 s hides it, with no event', (tester) async {
      await boot(tester);
      await show(tester);
      await emit(tester, {'event': 'load', 'id': 'm1', ...snapshot()});
      expect(find.byKey(const Key('load-bar-m1')), findsOneWidget);
      // The sampler on m1 stops; nothing arrives, not even an error.
      now = now.add(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 15));
      expect(find.byKey(const Key('load-bar-m1')), findsOneWidget);
      now = now.add(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(const Key('load-bar-m1')), findsNothing);
      // The next line brings it back.
      await emit(tester, {'event': 'load', 'id': 'm1', ...snapshot()});
      expect(find.byKey(const Key('load-bar-m1')), findsOneWidget);
      await emit(tester, {'event': 'load', 'id': 'm1', 'error': 'connection lost'});
      expect(find.byKey(const Key('load-bar-m1')), findsNothing);
    });

    testWidgets('load_row_hidden_offline', (tester) async {
      offline = {'m1'};
      await boot(tester);
      await show(tester);
      await emit(tester, {'event': 'load', 'id': 'm1', ...snapshot()});
      expect(tester.widget<Text>(find.descendant(of: find.byKey(const Key('column-m1')), matching: find.text('离线'))),
          isNotNull);
      expect(find.byKey(const Key('load-bar-m1')), findsNothing);
    });

    testWidgets('the local column shows the local service\'s load', (tester) async {
      await boot(tester);
      final monitor = ServiceMonitor(readToken: () async => null);
      addTearDown(monitor.dispose);
      monitor.load = load();
      await show(tester, monitor: monitor);
      // Nobody is connected in, so 本机 starts as a strip: open it.
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      expect(find.descendant(of: find.byKey(const Key('column-local')), matching: find.byKey(const Key('load-bar-local'))),
          findsOneWidget);
    });

    testWidgets('ios_local_column_has_no_load_row', (tester) async {
      await onPlatform(TargetPlatform.iOS, () async {
        await boot(tester);
        final svc = _Service();
        late ServiceMonitor monitor;
        await tester.runAsync(() async {
          await svc.start();
          monitor = ServiceMonitor(readToken: () async => 'tok', port: svc.server.port);
          monitor.start();
          final end = DateTime.now().add(const Duration(seconds: 5));
          while (monitor.status == null && DateTime.now().isBefore(end)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        expect(monitor.status, isNotNull);
        expect(svc.received, isNot(contains('watch_load')));
        // Even a load from somewhere would not be shown on iOS's own column.
        monitor.load = load();
        await show(tester, monitor: monitor);
        expect(find.byKey(const Key('column-local')), findsOneWidget);
        expect(find.byKey(const Key('load-bar-local')), findsNothing);
        await tester.runAsync(() async {
          monitor.dispose();
          await svc.stop();
        });
      });
    });
  });
}
