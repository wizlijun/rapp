import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/overview.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import 'helpers.dart';

/// The corner illustration sits under the page: it is painted first and never takes a pointer, so
/// a session block that lands beneath it still opens on a tap.
void main() {
  testWidgets('blocks under the corner illustration still take taps', (tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tmp = Directory.systemTemp.createTempSync('overview_art_hit');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final t = FakeTransport();
    var sid = 0;
    t.onSend = (m) {
      if (m['cmd'] == 'hosts') {
        t.emit({
          'event': 'hosts',
          'req': m['req'],
          'hosts': [for (var i = 1; i <= 5; i++) {'id': 'm$i', 'name': 'host$i'}],
        });
      } else if (m['cmd'] == 'apps') {
        t.emit({'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'lan', 'apps': []});
      } else if (m['cmd'] == 'open') {
        t.emit({'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req']});
      }
    };
    final s = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs());
    addTearDown(s.dispose);
    Future<void> flush() async {
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    await tester.runAsync(() async {
      await flush();
      await flush();
      for (var h = 1; h <= 5; h++) {
        for (var k = 0; k < 4; k++) {
          s.openOrSwitch('m$h', 'app$k', 'app$k');
          await flush();
        }
      }
    });
    s.toggleOverview();
    await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 700, child: Overview(state: s)), theme: RappTheme.avatar));
    await tester.pump(const Duration(seconds: 1)); // MaterialApp animates a theme change

    final art = find.byKey(const Key('overview-art'));
    expect(art, findsOneWidget);
    final r = tester.getRect(art);

    // Painted first: the illustration is the bottom child of the page's stack.
    final stack = tester.widget<Stack>(find.descendant(of: find.byType(Overview), matching: find.byType(Stack)).first);
    expect((stack.children.first as Positioned).child, isA<OverviewArt>());

    // Nothing at the illustration's centre or corners hits it.
    for (final p in [r.center, r.topLeft + const Offset(8, 8), r.bottomRight - const Offset(8, 8)]) {
      final res = HitTestResult();
      tester.binding.hitTestInView(res, p, tester.view.viewId);
      expect(res.path.any((e) => e.target is RenderImage), isFalse, reason: '$p');
    }

    final under = [
      for (final e in s.entries)
        if (r.contains(tester.getCenter(find.byKey(Key('block-${e.key}'))))) e.key,
    ];
    expect(under, isNotEmpty, reason: 'the layout should put some blocks under the illustration');
    for (final k in under) {
      await tester.tapAt(tester.getCenter(find.byKey(Key('block-$k'))));
      await tester.pump();
      expect(s.currentKey, k);
    }
  });
}
