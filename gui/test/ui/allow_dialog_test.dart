import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/shares.dart';
import 'package:rapp/ui/allow_dialog.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/shares_section.dart';

import 'helpers.dart';

class FakeApi implements SharesApi {
  final calls = <String>[];
  @override
  Future<ShareTable> shares({String? to}) async => ShareTable(
        id: '123456789',
        me: 'a',
        rows: const [ShareRow(port: 8000, note: 'n', allow: [], addr: 'http://localhost:28000', web: true, listening: true, mine: true)],
        known: const [me, mini],
      );
  @override
  Future<List<Shared>> share({String? to, required List<int> ports, String? note, List<String>? allow}) async {
    calls.add('share $to $ports $note $allow');
    return [for (final p in ports) Shared(port: p)];
  }

  @override
  Future<bool> unshare({String? to, required int port}) async => true;
}

const me = Device(fp: 'a', name: '本机');
const mini = Device(fp: 'b', name: 'mini');
const gpu1 = Device(fp: 'c', name: 'gpu1');

Future<void> open(WidgetTester t, List<Device> cands, List<Device> cur, void Function(List<String>?) done) async {
  await t.pumpWidget(wrap(Builder(
    builder: (c) => TextButton(
      onPressed: () async => done(await showAllowDialog(c, candidates: cands, current: cur)),
      child: const Text('go'),
    ),
  )));
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('everyone', (t) async {
    List<String>? got = ['x'];
    await open(t, [me, mini], const [], (v) => got = v);
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(got, <String>[]);
  });

  testWidgets('pick devices', (t) async {
    List<String>? got;
    await open(t, [me, mini, gpu1], const [], (v) => got = v);
    await t.tap(find.text('只给勾选的设备'));
    await t.pump();
    expect(t.widget<RappButton>(find.byKey(const Key('allow-save'))).onPressed, isNull);
    await t.tap(find.text('gpu1'));
    await t.tap(find.text('本机'));
    await t.pump();
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(got, ['a', 'c']);
  });

  testWidgets('one already allowed but not a candidate stays ticked', (t) async {
    List<String>? got;
    await open(t, [me, mini], [const Device(fp: 'x', name: 'abababab')], (v) => got = v);
    expect(t.widget<CheckboxListTile>(find.byKey(const Key('allow-device-x'))).value, isTrue);
    expect(find.text('abababab'), findsOneWidget);
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(got, ['x']);
  });

  testWidgets('only this device to pick', (t) async {
    await open(t, [me], const [], (_) {});
    expect(find.text('别的设备连过这台以后才能选'), findsOneWidget);
  });

  testWidgets('cancel', (t) async {
    List<String>? got = ['x'];
    await open(t, [me, mini], const [], (v) => got = v);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(got, isNull);
  });

  testWidgets('saving from the section sends the fingerprints', (t) async {
    final api = FakeApi();
    await t.pumpWidget(wrap(SingleChildScrollView(child: SharesSection(api: api))));
    await t.pump();
    await t.tap(find.byKey(const Key('share-allow-8000')));
    await t.pumpAndSettle();
    await t.tap(find.text('只给勾选的设备'));
    await t.pump();
    await t.tap(find.text('mini'));
    await t.pump();
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(api.calls, contains('share null [8000] null [b]'));
  });
}
