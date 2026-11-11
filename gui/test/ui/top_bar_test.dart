import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('top_bar_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    s = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs());
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, int sid, String app) async {
    t.emit({'event': 'opened', 'sid': sid, 'id': '111', 'app': app, 'path': 'lan'});
    await tester.runAsync(flush);
    await tester.pump();
  }

  Widget bar({bool fullscreen = false}) => SizedBox(
        width: 800,
        child: TopBar(state: s, fullscreen: fullscreen, onToggleFullscreen: () {}),
      );

  testWidgets('top bar shows current session name, device and path', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    expect(find.text('没有选中的会话'), findsOneWidget);
    await tester.runAsync(() async {
      t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'Safari', 'path': 'lan'});
      await flush();
    });
    s.select('111/Safari');
    await tester.pump();
    expect(find.text('Safari'), findsOneWidget);
    expect(find.text('mini · 局域网'), findsOneWidget);
  });

  testWidgets('prev/next disabled with fewer than two sessions', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    await open(tester, 1, 'Safari');
    IconButton b(String k) => tester.widget<IconButton>(find.byKey(Key(k)));
    expect(b('prev').onPressed, isNull);
    expect(b('next').onPressed, isNull);
    expect(find.byTooltip('上一个'), findsOneWidget);
    expect(find.byTooltip('下一个'), findsOneWidget);
    expect(find.byTooltip('面板'), findsOneWidget);
    expect(find.byTooltip('进入全屏'), findsOneWidget);
  });

  testWidgets('next moves current', (tester) async {
    await tester.pumpWidget(wrap(bar(fullscreen: true)));
    await open(tester, 1, 'Mail');
    await open(tester, 2, 'Safari');
    s.select('111/Mail');
    await tester.pump();
    await tester.tap(find.byKey(const Key('next')));
    await tester.pump();
    expect(s.currentKey, '111/Safari');
    expect(find.byTooltip('退出全屏'), findsOneWidget);
  });

  testWidgets('panel button toggles the panel', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    await tester.tap(find.byKey(const Key('panel-button')));
    expect(s.panel, isNotNull);
  });

  testWidgets('long hint is one line with ellipsis', (tester) async {
    s.hint = 'x' * 500;
    await tester.pumpWidget(wrap(bar()));
    final txt = tester.widget<Text>(find.text('x' * 500));
    expect(txt.maxLines, 1);
    expect(txt.overflow, TextOverflow.ellipsis);
  });
}
