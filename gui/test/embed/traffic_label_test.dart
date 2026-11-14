import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_menu.dart';
import 'package:rapp/embed/traffic_label.dart';
import 'package:rapp/hub_client.dart';

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

  testWidgets('traffic label shows the saving level', (tester) async {
    open = false;
    final port = FakeSessionPort();
    final rs = RemoteSession(1, 'Calc')
      ..apply(const TrafficEvent(1, 12000))
      ..apply(const WeakEvent(1, true, 1));
    await tester.pumpWidget(wrap(anchor(rs, port)));
    expect(find.text('12.0 KB/s · 省流·1'), findsOneWidget);
    expect(find.bySemanticsLabel('流量 12.0 KB/s，省流·1，打开流量优化菜单'), findsOneWidget);
    rs.apply(const WeakEvent(1, true, 2));
    await tester.pump();
    expect(find.text('12.0 KB/s · 省流·2'), findsOneWidget);
    rs.apply(const WeakEvent(1, false));
    await tester.pump();
    expect(find.text('12.0 KB/s'), findsOneWidget);
  });

  test('trafficWord: which end is weak, else the saving level', () {
    expect(trafficWord(saving: 0), isNull);
    expect(trafficWord(saving: 1), '省流·1');
    expect(trafficWord(saving: 2, localWeak: true), '本机网络弱');
    expect(trafficWord(saving: 2, peerWeak: true), '对方网络弱');
    expect(trafficWord(saving: 2, localWeak: true, peerWeak: true), '弱网');
  });

  test('a relayed session: the local part from the marker, the far part worked out', () {
    const weak = NetStatus(NetLevel.weak, 350, 0);
    const ok = NetStatus(NetLevel.ok, 80, 0);
    expect(sessionTrafficWord(path: 'relay', saving: 1, wholeMs: 420, net: ok), '对方网络弱'); // 340 far
    expect(sessionTrafficWord(path: 'relay', saving: 1, wholeMs: 300, net: ok), '省流·1'); // 220 far
    expect(sessionTrafficWord(path: 'relay', saving: 0, wholeMs: 400, net: weak), '本机网络弱');
    expect(sessionTrafficWord(path: 'relay', saving: 2, wholeMs: 700, net: weak), '弱网');
    expect(sessionTrafficWord(path: 'lan', saving: 0, wholeMs: 900, net: weak), isNull); // not through the relay
    expect(segments(path: 'relay', wholeMs: 50, net: ok).peer, 0);
    expect(segments(path: 'relay', wholeMs: 420, net: const NetStatus(NetLevel.down, 80, 1)).local, isNull);
  });

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
