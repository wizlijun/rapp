import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/ui/hint_history.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late Directory tmp;
  late FakeStateSync sync;
  late MainState st;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hint_history_test');
    final t = FakeTransport();
    final hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
        {'id': '222', 'name': 'air'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    sync = FakeStateSync(tmp.path)..ids['F'] = '111'..ids['G'] = '222';
    st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), stateSync: sync);
    t.emit({'event': 'presence', 'id': '222', 'online': true});
    await Future<void>.delayed(Duration.zero);
    t.emit({'event': 'presence', 'id': '222', 'online': false});
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() {
    st.dispose();
    tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> row(String eid, String fp, String id, String session, int at) =>
      {'t': 'state', 'eid': eid, 'fp': fp, 'id': id, 'session': session, 'name': session, 'state': 'done', 'at': at};

  testWidgets('a fresh row is bold and reads 新; an offline row is grey, suffixed and not tappable', (tester) async {
    sync
      ..status = StateStatus.connected
      ..rows = [row('F:e:1', 'F', '111', 'a', 200), row('G:e:2', 'G', '222', 'b', 100)]
      ..freshEids.add('F:e:1');
    sync.push();
    await tester.pumpWidget(wrap(SizedBox(width: 600, height: 400, child: HintHistoryList(state: st))));
    final fresh = tester.widget<Text>(find.text('a @ mini：完成'));
    expect(fresh.style?.fontWeight, FontWeight.w600);
    expect(find.bySemanticsLabel(RegExp(r'，新$')), findsOneWidget);
    expect(find.text('b @ air：完成 · 设备离线'), findsOneWidget);
    expect(find.byKey(const Key('queue-0')), findsOneWidget);
    expect(find.byKey(const Key('queue-1')), findsNothing);
  });
}
