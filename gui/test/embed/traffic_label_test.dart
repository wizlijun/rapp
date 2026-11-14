import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_menu.dart';
import 'package:rapp/embed/traffic_label.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  test('level bars thresholds', () {
    expect([0, 4999, 5000, 14999, 39999, 99999, 100000].map(levelBars), [0, 1, 2, 2, 3, 4, 5]);
  });

  test('formatRate', () {
    expect([0, 1500, 999949, 2500000].map(formatRate), ['0 KB/s', '1.5 KB/s', '999.9 KB/s', '2.5 MB/s']);
  });

  var open = false;

  Widget anchor(RemoteSession rs, FakeSessionPort port) => SizedBox(
        width: 400,
        height: 600,
        child: Align(
          alignment: Alignment.topRight,
          child: StatefulBuilder(
            builder: (context, set) => StreamMenuAnchor(
              port: port,
              session: rs,
              path: 'lan',
              status: '活动',
              disconnected: false,
              onDisconnect: () {},
              onReconnect: () {},
              onEnd: () {},
              clips: const [],
              canCopy: (_) => true,
              canInsert: (_) => true,
              onCopy: (_) {},
              onAllClips: () {},
              open: open,
              onToggle: () => set(() => open = !open),
              onClose: () => set(() => open = false),
            ),
          ),
        ),
      );

  testWidgets('traffic label shows the rate and opens the menu by tap and by right click', (tester) async {
    open = false;
    final port = FakeSessionPort();
    final rs = RemoteSession(1, 'Calc')..apply(const TrafficEvent(1, 12000));
    await tester.pumpWidget(wrap(anchor(rs, port)));
    expect(find.text('12.0 KB/s'), findsOneWidget);
    expect(find.bySemanticsLabel('流量 12.0 KB/s，打开流量优化菜单'), findsOneWidget);
    expect(find.text('最省流（双色·灰度 + 自适应 + 1 fps）'), findsNothing);
    await tester.tap(find.byKey(const Key('traffic')));
    await tester.pump();
    expect(find.text('最省流（双色·灰度 + 自适应 + 1 fps）'), findsOneWidget);
    // Tapping the label again closes it.
    await tester.tap(find.byKey(const Key('traffic')), warnIfMissed: false);
    await tester.pump();
    expect(find.text('最省流（双色·灰度 + 自适应 + 1 fps）'), findsNothing);
    await tester.tap(find.byKey(const Key('traffic')), buttons: kSecondaryButton);
    await tester.pump();
    expect(find.text('最省流（双色·灰度 + 自适应 + 1 fps）'), findsOneWidget);
  });
}
