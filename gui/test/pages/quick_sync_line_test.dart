import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/quick_sync_line.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/quick/quick_prefs.dart';
import 'package:rapp/quick/quick_sync.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  late Directory tmp;
  late MainState s;
  late QuickSync qs;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('quick_sync_line');
    Directory('${tmp.path}/local').createSync();
    final quick = QuickPrefs.migrate(const []);
    qs = QuickSync(prefs: quick, localDir: '${tmp.path}/local', device: null);
    s = MainState(
        hub: HubClient(FakeTransport()),
        data: DataDir(tmp.path),
        prefs: UiPrefs(),
        port: FakeSessionPort(),
        quick: quick,
        quickSync: qs);
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(wrap(QuickSyncLine(state: s)));
  }

  testWidgets('local', (tester) async {
    await show(tester);
    expect(find.text('只存在本机（没有中心服务）'), findsOneWidget);
  });

  testWidgets('synced with a host', (tester) async {
    qs.status = QuickSyncStatus.synced;
    qs.hostId = '123456789';
    await show(tester);
    expect(find.text('已和 ${s.deviceName('123456789')} 上的中心服务同步'), findsOneWidget);
  });

  testWidgets('synced without a host', (tester) async {
    qs.status = QuickSyncStatus.synced;
    await show(tester);
    expect(find.text('已和中心服务同步'), findsOneWidget);
  });

  testWidgets('waiting', (tester) async {
    qs.status = QuickSyncStatus.waiting;
    await show(tester);
    expect(find.text('连不上中心服务，改动会在连上后同步'), findsOneWidget);
  });

  testWidgets('no QuickSync reads as local', (tester) async {
    final s2 = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort());
    addTearDown(s2.dispose);
    await tester.pumpWidget(wrap(QuickSyncLine(state: s2)));
    expect(find.text('只存在本机（没有中心服务）'), findsOneWidget);
  });
}
