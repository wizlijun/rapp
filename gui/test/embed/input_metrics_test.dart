import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/input_metrics.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/key_bar_keys.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  test('standard equals today\'s constants', () {
    const m = InputMetrics.standard;
    expect(m.keyHeight, keyBarKeyHeight);
    expect(m.gap, keyBarGap);
    expect(m.chip, phraseStripChip);
    expect(m.panelButton, 40);
    for (final rows in [1, 2]) {
      expect(keyBarHeightFor(m, rows), keyBarHeight(rows));
    }
    expect(stripHeightFor(m), phraseStripHeight);
  });

  testWidgets('of() is standard with nothing above, phone below the wrapper', (tester) async {
    InputMetrics? plain, wrapped;
    await tester.pumpWidget(Builder(builder: (c) {
      plain = InputMetrics.of(c);
      return InputMetrics.phone.wrap(Builder(builder: (c) {
        wrapped = InputMetrics.of(c);
        return const SizedBox();
      }));
    }));
    expect(plain!.keyHeight, 42);
    expect(wrapped!.keyHeight, 56);
    expect(wrapped!.gap, 12);
    expect(wrapped!.chip, 56);
    expect(wrapped!.panelButton, 56);
  });

  group('widgets', () {
    late Directory tmp;
    late MainState st;
    late FakeSessionPort port;
    late FakeTermSessionPort term;
    late RemoteSession ts, app;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('input_metrics_test');
      Directory('${tmp.path}/local').createSync();
      File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"123456789"}');
      port = FakeSessionPort();
      term = FakeTermSessionPort()..seed(2);
      st = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term);
      st.setStripItems(const [Phrase('继续'), Phrase('确认')]);
      ts = RemoteSession(2, 'term');
      app = RemoteSession(1, 'Safari');
      app.composer.open = true;
    });
    tearDown(() {
      ts.dispose();
      app.dispose();
      st.dispose();
      term.dispose();
      tmp.deleteSync(recursive: true);
    });

    Widget bar(bool phone) {
      final child = SizedBox(width: 390, child: KeyBar(state: st, session: ts, port: term));
      return wrap(Align(alignment: Alignment.topLeft, child: phone ? InputMetrics.phone.wrap(child) : child));
    }

    void iosTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
          try {
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });

    Future<void> small(WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    iosTest('phone: keys, chips, 命令▾ and 常用语▾ are at least 56 high and 12 apart', (tester) async {
      await small(tester);
      await tester.pumpWidget(bar(true));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final keys = [for (final id in ['tab', 'esc', 'cc', 'bksp', 'enter', 'up']) tester.getRect(find.byKey(Key('bar-$id')))];
      for (final r in keys) {
        expect(r.height, greaterThanOrEqualTo(56));
        expect(r.width, greaterThan(0));
      }
      for (var i = 1; i < keys.length; i++) {
        final gap = keys[i].left - keys[i - 1].right;
        if (gap > 0 && keys[i].top == keys[i - 1].top) expect(gap, greaterThanOrEqualTo(12));
      }
      final cmds = tester.getRect(find.byKey(const Key('quick-menu-cmds')));
      final phrases = tester.getRect(find.byKey(const Key('quick-menu-phrases')));
      expect(cmds.height, greaterThanOrEqualTo(56));
      expect(phrases.height, greaterThanOrEqualTo(56));
      expect(phrases.left - cmds.right, greaterThanOrEqualTo(12));
      expect(tester.getSize(find.byType(KeyBar)).height, keyBarHeightOf(st, ts, InputMetrics.phone));
      final firstRow = tester.getRect(find.byKey(const Key('bar-tab')));
      expect(firstRow.top - cmds.bottom, greaterThanOrEqualTo(12));
    });

    iosTest('phone: both rows, every key is 56 high and 12 from its neighbours', (tester) async {
      await small(tester);
      st.prefs.keyBarMore = true;
      await tester.pumpWidget(bar(true));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final rows = <double, List<Rect>>{};
      for (final id in barKeys.keys) {
        final f = find.byKey(Key('bar-$id'));
        if (f.evaluate().isEmpty) continue;
        final r = tester.getRect(f);
        expect(r.height, greaterThanOrEqualTo(56), reason: id);
        if (const bool.fromEnvironment('PRINT_WIDTHS')) debugPrint('width $id ${r.width}');
        rows.putIfAbsent(r.top, () => []).add(r);
      }
      expect(rows.length, 2);
      for (final r in rows.values) {
        r.sort((x, y) => x.left.compareTo(y.left));
        for (var i = 1; i < r.length; i++) {
          expect(r[i].left - r[i - 1].right, greaterThanOrEqualTo(12));
        }
      }
      final tops = rows.keys.toList()..sort();
      expect(tops[1] - (tops[0] + rows[tops[0]]!.first.height), greaterThanOrEqualTo(12));
    });

    iosTest('pad: no wrapper, the bar is today\'s height', (tester) async {
      await small(tester);
      await tester.pumpWidget(bar(false));
      await tester.pump();
      expect(tester.getSize(find.byType(KeyBar)).height, keyBarHeight(1) + phraseStripHeight);
      expect(tester.getSize(find.byKey(const Key('quick-menu-cmds'))).height, phraseStripChip);
      expect(tester.getSize(find.byKey(const Key('bar-esc'))).height, keyBarKeyHeight - 2); // the box's border, as today
    });

    Widget panel(bool phone) {
      final child = SizedBox(
          width: 390, child: ComposerPanel(state: st, session: app, port: port, maxHeight: 300, editor: FlutterEditor.new));
      return wrap(Align(alignment: Alignment.bottomLeft, child: phone ? InputMetrics.phone.wrap(child) : child));
    }

    iosTest('phone: ＋ and 发送 are 56 square; pad: 40', (tester) async {
      await small(tester);
      await tester.pumpWidget(panel(true));
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('composer-plus'))), const Size(56, 56));
      expect(tester.getSize(find.byKey(const Key('composer-send'))), const Size(56, 56));
      await tester.pumpWidget(panel(false));
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('composer-plus'))), const Size(40, 40));
      expect(tester.getSize(find.byKey(const Key('composer-send'))), const Size(40, 40));
    });
  });
}
