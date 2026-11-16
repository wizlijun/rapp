import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/shares.dart';
import 'package:rapp/ui/shares_section.dart';

import 'helpers.dart';

const _me = Device(fp: 'a', name: '本机');
const _mini = Device(fp: 'b', name: 'mini');

ShareRow row(int port,
        {String note = '', List<Device> allow = const [], bool web = true, bool listening = true, bool mine = true, String? addr,
        String proto = 'http', bool protoAuto = false, int? local, int? wanted, bool taken = false, Renumbered? renumbered}) =>
    ShareRow(
      port: port,
      note: note,
      allow: allow,
      // Like the service: no local port for a share that leaves this device out.
      addr: addr ?? (!mine ? '' : web ? 'http://localhost:28000' : 'ssh -p 28001 localhost'),
      web: web,
      listening: listening,
      mine: mine,
      proto: proto,
      protoAuto: protoAuto,
      local: local,
      wanted: wanted,
      taken: taken,
      renumbered: renumbered,
    );

ShareTable table(List<ShareRow> rows, {bool old = false}) =>
    ShareTable(id: '123456789', me: 'a', rows: rows, known: const [_me, _mini], old: old);

class FakeApi implements SharesApi {
  FakeApi(this.next);
  Future<ShareTable> Function(String? to) next;
  final calls = <String>[];
  Future<List<Shared>> Function()? onShare;
  Future<bool> Function()? onUnshare;

  @override
  Future<ShareTable> shares({String? to}) {
    calls.add('shares $to');
    return next(to);
  }

  @override
  Future<List<Shared>> share({String? to, required List<int> ports, String? note, List<String>? allow, String? proto}) {
    calls.add('share $to $ports $note $allow${proto == null ? '' : ' $proto'}');
    return onShare?.call() ?? Future.value([for (final p in ports) Shared(port: p)]);
  }

  @override
  Future<bool> unshare({String? to, required int port}) {
    calls.add('unshare $to $port');
    return onUnshare?.call() ?? Future.value(true);
  }
}

Future<FakeApi> show(WidgetTester t, ShareTable tb, {String? to, Future<void> Function(String)? open, PickAllow? pick}) async {
  final api = FakeApi((_) async => tb);
  await t.pumpWidget(wrap(SingleChildScrollView(
    child: SharesSection(api: api, to: to, open: open ?? (_) async {}, pickAllow: pick ?? (c, r, k) async => null),
  )));
  await t.pump();
  return api;
}

Future<FakeApi> showErr(WidgetTester t, Object e) async {
  final api = FakeApi((_) => Future.error(e));
  await t.pumpWidget(wrap(SharesSection(api: api, to: 'x')));
  await t.pump();
  return api;
}

void main() {
  testWidgets('rows', (t) async {
    await show(t, table([row(8000, note: 'jupyter'), row(22, web: false, listening: false, allow: const [_me, _mini])]));
    expect(find.text('端口'), findsWidgets);
    expect(find.text('http://localhost:28000'), findsOneWidget);
    expect(find.text('ssh -p 28001 localhost'), findsOneWidget);
    expect(find.text('所有设备'), findsOneWidget);
    expect(find.text('只给 本机、mini'), findsOneWidget);
    expect(find.byKey(const Key('share-open-22')), findsNothing);
    expect(find.byKey(const Key('share-copy-22')), findsOneWidget);
    expect(find.byKey(const Key('share-open-8000')), findsOneWidget);
  });

  testWidgets('open works with nothing to switch on first', (t) async {
    final opened = <String>[];
    await show(t, table([row(8000)]), open: (u) async => opened.add(u));
    expect(find.textContaining('.rapp'), findsNothing);
    await t.tap(find.byKey(const Key('share-open-8000')));
    expect(opened, ['http://localhost:28000']);
  });

  testWidgets('a share with no address on this computer cannot be opened or copied', (t) async {
    final opened = <String>[];
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    // 8000 is for mini alone; 9000 is for this computer, but the service had no local port left.
    await show(t, table([row(8000, allow: const [_mini], mine: false, addr: ''), row(9000, addr: '')]), open: (u) async => opened.add(u));
    for (final port in [8000, 9000]) {
      await t.tap(find.byKey(Key('share-open-$port')), warnIfMissed: false);
      await t.tap(find.byKey(Key('share-copy-$port')), warnIfMissed: false);
    }
    expect(opened, isEmpty);
    expect(copied, isNull);
    expect(find.text('只给 mini（不含本机）'), findsOneWidget);
    expect(find.text('没有空的号'), findsOneWidget);
  });

  testWidgets('the address is shown, copied and opened as the service sent it', (t) async {
    final opened = <String>[];
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await show(t, table([row(8000)]), open: (u) async => opened.add(u));
    expect(find.text('http://localhost:28000'), findsOneWidget);
    expect(find.textContaining('http://http://'), findsNothing);
    await t.tap(find.byKey(const Key('share-open-8000')));
    await t.tap(find.byKey(const Key('share-copy-8000')));
    expect(opened, ['http://localhost:28000']);
    expect(copied, 'http://localhost:28000');
  });

  for (final w in [400.0, 360.0]) {
    testWidgets('a long scope at ${w.toInt()}px wide does not overflow and unshare stays tappable', (t) async {
      t.view.physicalSize = Size(w, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final long = [for (var i = 0; i < 3; i++) Device(fp: 'f$i', name: '很长很长的设备名称' * 6 + '$i')];
      final api = await show(t, table([row(8000, allow: long, note: 'jupyter')]));
      expect(t.takeException(), isNull);
      final f = find.byKey(const Key('share-unshare-8000'));
      expect(t.getRect(f).right, lessThanOrEqualTo(w));
      await t.tap(f);
      await t.pump();
      await t.tap(f);
      await t.pump();
      await t.pump();
      expect(api.calls.any((c) => c.startsWith('unshare')), isTrue);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('the section reloads once when the service comes back', (t) async {
    final api = FakeApi((_) => Future.error(ServiceException('service not running')));
    Widget host(bool online) => wrap(SharesSection(api: api, online: online));
    await t.pumpWidget(host(false));
    await t.pump();
    expect(find.text('本机的 rapp 服务没有在运行'), findsOneWidget);
    api.next = (_) async => table([row(8000)]);
    await t.pumpWidget(host(true));
    await t.pump();
    expect(find.text('http://localhost:28000'), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('shares')).length, 2);
    await t.pumpWidget(host(true));
    await t.pump();
    expect(api.calls.where((c) => c.startsWith('shares')).length, 2);
  });

  testWidgets('a share that leaves this device out', (t) async {
    final opened = <String>[];
    await show(t, table([row(8000, allow: const [_mini], mine: false)]), open: (u) async => opened.add(u));
    expect(find.text('只给 mini（不含本机）'), findsOneWidget);
    await t.tap(find.byKey(const Key('share-open-8000')), warnIfMissed: false);
    expect(opened, isEmpty);
  });

  testWidgets('the states', (t) async {
    final c = Completer<ShareTable>();
    final api = FakeApi((_) => c.future);
    await t.pumpWidget(wrap(SharesSection(api: api)));
    expect(find.text('正在读取…'), findsOneWidget);
    c.complete(table([]));
    await t.pump();
    expect(find.text('没有分享端口'), findsOneWidget);
    expect(find.byKey(const Key('share-port')), findsOneWidget);

    for (final (e, text) in <(Object, String)>[
      (ServiceException('offline'), '离线，读不到它的端口'),
      (ServiceException('old version'), '对方的 rapp 还不支持分享端口'),
      (ServiceException('policy'), '对方的策略不允许远程设置'),
      (ServiceException('service not running'), '本机的 rapp 服务没有在运行'),
    ]) {
      await showErr(t, e);
      expect(find.text(text), findsOneWidget, reason: text);
      expect(find.byKey(const Key('share-port')), findsNothing);
    }
  });

  testWidgets('share a port', (t) async {
    final api = await show(t, table([]));
    final gate = Completer<List<Shared>>();
    api.onShare = () => gate.future;
    await t.enterText(find.byKey(const Key('share-port')), ' 8000 ');
    await t.enterText(find.byKey(const Key('share-note')), 'jupyter');
    await t.tap(find.byKey(const Key('share-add')));
    await t.pump();
    await t.tap(find.byKey(const Key('share-add')), warnIfMissed: false);
    await t.pump();
    expect(api.calls.where((c) => c.startsWith('share ')), ['share null [8000] jupyter null']);
    gate.complete([const Shared(port: 8000)]);
    await t.pump();
    await t.pump();
    expect(api.calls.where((c) => c.startsWith('shares')).length, 2);
  });

  testWidgets('the inputs carry their placeholders', (t) async {
    await show(t, table([]));
    InputDecoration deco(String k) => t.widget<TextField>(find.byKey(Key(k))).decoration!;
    expect(deco('share-port').hintText, '端口号');
    expect(deco('share-note').hintText, '备注，可不填');
  });

  testWidgets('the port spellings', (t) async {
    final api = await show(t, table([]));
    for (final s in ['', '0', '65536', '80a', '８０００', '-1']) {
      await t.enterText(find.byKey(const Key('share-port')), s);
      await t.tap(find.byKey(const Key('share-add')));
      await t.pump();
      expect(find.text('端口号是 1 到 65535 的数字'), findsOneWidget, reason: '"$s"');
    }
    expect(api.calls.where((c) => c.startsWith('share ')), isEmpty);
  });

  testWidgets('limit keeps the input', (t) async {
    final api = await show(t, table([]));
    api.onShare = () => Future.error(ServiceException('limit'));
    await t.enterText(find.byKey(const Key('share-port')), '8000');
    await t.tap(find.byKey(const Key('share-add')));
    await t.pump();
    await t.pump();
    expect(find.text('最多分享 64 个端口'), findsOneWidget);
    expect(find.text('8000'), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('shares')).length, 1);
  });

  testWidgets('a sensitive port shows the warning under its row', (t) async {
    final api = FakeApi((_) async => table([row(22, web: false)]));
    api.onShare = () async => [const Shared(port: 22, warn: '22 是 ssh，请确认')];
    await t.pumpWidget(wrap(SharesSection(api: api)));
    await t.pump();
    await t.enterText(find.byKey(const Key('share-port')), '22');
    await t.tap(find.byKey(const Key('share-add')));
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('share-warn-22')), findsOneWidget);
    expect(find.text('22 是 ssh，请确认'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('unshare takes two taps', (t) async {
    final api = await show(t, table([row(22, web: false)]));
    await t.tap(find.byKey(const Key('share-unshare-22')));
    await t.pump();
    expect(find.text('再点一次确认'), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('unshare')), isEmpty);
    await t.tap(find.byKey(const Key('share-unshare-22')));
    await t.pump();
    await t.pump();
    expect(api.calls.skip(1), ['unshare null 22', 'shares null']);
  });

  testWidgets('the note is edited in place', (t) async {
    final api = await show(t, table([row(8000, note: 'old')]));
    await t.tap(find.text('old'));
    await t.pump();
    await t.enterText(find.descendant(of: find.byKey(const Key('share-row-8000')), matching: find.byType(TextField)), 'x');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(api.calls, contains('share null [8000] x null'));
  });

  testWidgets('the scope hook sets who may use it', (t) async {
    ShareRow? got;
    final api = await show(t, table([row(8000, note: 'n')]), pick: (c, r, k) async {
      got = r;
      expect(k, [_me, _mini]);
      return ['b'];
    });
    await t.tap(find.byKey(const Key('share-allow-8000')));
    await t.pump();
    expect(got?.port, 8000);
    expect(api.calls, contains('share null [8000] null [b]'));
  });

  testWidgets('refresh asks again; nothing is asked on a timer', (t) async {
    final api = await show(t, table([]));
    await t.pump(const Duration(seconds: 60));
    expect(api.calls, ['shares null']);
    await t.tap(find.byKey(const Key('shares-refresh')));
    await t.pump();
    expect(api.calls, ['shares null', 'shares null']);
  });

  testWidgets('a late reply for the previous device is dropped', (t) async {
    final a = Completer<ShareTable>();
    final api = FakeApi((to) => to == 'A' ? a.future : Future.value(table([row(9000)])));
    Widget host(String to) => wrap(SharesSection(key: ValueKey(to), api: api, to: to));
    await t.pumpWidget(host('A'));
    await t.pumpWidget(host('B'));
    await t.pump();
    expect(find.byKey(const Key('share-row-9000')), findsOneWidget);
    a.completeError(ServiceException('offline'));
    await t.pump();
    expect(find.byKey(const Key('share-row-9000')), findsOneWidget);
    expect(find.text('离线，读不到它的端口'), findsNothing);
  });

  testWidgets('the same section switched to another device drops the old reply', (t) async {
    final a = Completer<ShareTable>();
    final api = FakeApi((to) => to == 'A' ? a.future : Future.value(table([row(9000)])));
    await t.pumpWidget(wrap(SharesSection(api: api, to: 'A')));
    await t.pumpWidget(wrap(SharesSection(api: api, to: 'B')));
    await t.pump();
    a.completeError(ServiceException('offline'));
    await t.pump();
    expect(find.byKey(const Key('share-row-9000')), findsOneWidget);
    expect(find.text('离线，读不到它的端口'), findsNothing);
  });

  testWidgets('protocol picker: shows the proto, 自动, and chooses tcp', (t) async {
    final api = await show(t, table([row(8000, protoAuto: true), row(22, proto: 'ssh', web: false)]));
    expect(find.byKey(const Key('share-proto-8000')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('share-proto-8000')), matching: find.text('http')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('share-row-8000')), matching: find.text('自动')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('share-row-22')), matching: find.text('自动')), findsNothing);
    await t.tap(find.byKey(const Key('share-proto-8000')));
    await t.pumpAndSettle();
    await t.tap(find.text('tcp').last);
    await t.pumpAndSettle();
    expect(api.calls, contains('share null [8000] null null tcp'));
  });

  testWidgets('choosing the proto already set does nothing', (t) async {
    final api = await show(t, table([row(8000)]));
    await t.tap(find.byKey(const Key('share-proto-8000')));
    await t.pumpAndSettle();
    await t.tap(find.text('http').last);
    await t.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('share ')), isEmpty);
  });

  testWidgets('an old table has no protocol picker', (t) async {
    await show(t, table([row(8000)], old: true));
    expect(find.byKey(const Key('share-proto-8000')), findsNothing);
  });

  testWidgets('copy gives addr exactly, open only when web', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String;
      return null;
    });
    await show(t, table([
      row(9000, proto: 'tcp', web: false, addr: 'tcp://localhost:28000'),
      row(22, proto: 'ssh', web: false, addr: 'ssh -p 28001 localhost'),
    ]));
    await t.tap(find.byKey(const Key('share-copy-9000')));
    expect(copied, 'tcp://localhost:28000');
    await t.tap(find.byKey(const Key('share-copy-22')));
    expect(copied, 'ssh -p 28001 localhost');
    expect(find.byKey(const Key('share-open-9000')), findsNothing);
    expect(find.byKey(const Key('share-open-22')), findsNothing);
  });

  testWidgets('notices: yielded, taken, renumbered', (t) async {
    final api = await show(t, table([
      row(8000, wanted: 28000, local: 28005),
      row(8007, taken: true, local: 28000),
      row(8008, local: 28003, renumbered: const Renumbered(from: 28000, with_: 'Mini')),
    ]));
    expect(find.text('这台上是 28005（28000 被占）'), findsOneWidget);
    expect(find.text('本机上 28000 被别的程序占着，本机请用 localhost:8007'), findsOneWidget);
    expect(find.text('28000 和 Mini 撞了，换成 28003'), findsOneWidget);
    await t.tap(find.byKey(const Key('share-renumbered-ok-8008')));
    await t.pump();
    expect(api.calls, contains('share null [8008] null null'));
  });

  testWidgets('a renumbered share with no number here has no notice (never null)', (t) async {
    await show(t, table([row(8008, addr: '', renumbered: const Renumbered(from: 28000, with_: 'Mini'))]));
    expect(find.textContaining('撞了'), findsNothing);
    expect(find.textContaining('null'), findsNothing);
    expect(find.byKey(const Key('share-renumbered-ok-8008')), findsNothing);
  });

  testWidgets('no address: own table says 没有空的号, remote keeps 没有本机端口可用', (t) async {
    await show(t, table([row(8000, addr: '')]));
    expect(find.text('没有空的号'), findsOneWidget);
    await show(t, table([row(8000, addr: '')]), to: 'x');
    await t.pump();
    expect(find.text('没有本机端口可用'), findsOneWidget);
  });
}
