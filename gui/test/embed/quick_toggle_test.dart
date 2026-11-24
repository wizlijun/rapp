// The 快捷区 toggle in the writing box (quick-toggle spec §1, §8): lit while the 快捷区 shows, one pref per kind.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/quick_toggle.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  late Directory tmp;
  late FakeSessionPort port;
  late MainState es;
  late RemoteSession app, tapp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('quick_toggle_test');
    final t = FakeTransport();
    final hub = HubClient(t);
    port = FakeSessionPort();
    es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    app = RemoteSession(1, 'Safari')..composer.open = true;
    tapp = RemoteSession(4, 'Terminal', appId: 'com.apple.Terminal')..composer.open = true;
  });

  tearDown(() {
    app.dispose();
    tapp.dispose();
    es.dispose();
    tmp.deleteSync(recursive: true);
  });

  void big(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget layer(RemoteSession s) => wrap(SizedBox(
      width: 1000,
      height: 700,
      child: Stack(children: composerLayer(state: es, session: s, port: port, editor: FlutterEditor.new))));

  final toggle = find.byKey(const Key('quick-toggle'));
  bool lit(WidgetTester tester) => tester.widget<RappButton>(toggle).active;
  // The toggle's own label: the old corner handle (gone in Task 4) is also named 显示快捷区.
  String? label(WidgetTester tester) => tester.widget<RappButton>(toggle).semanticLabel;

  test('quickToggleLabel names the action', () {
    expect(quickToggleLabel(shown: true), '收起快捷区');
    expect(quickToggleLabel(shown: false), '显示快捷区');
  });

  testWidgets('label and light follow the kind: a terminal sets quickHiddenTerm only', (tester) async {
    big(tester);
    await tester.pumpWidget(layer(tapp));
    await tester.pump();
    expect(lit(tester), isTrue);
    expect(label(tester), '收起快捷区');
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(es.prefs.quickHiddenTerm, isTrue);
    expect(es.prefs.quickHiddenApp, isTrue, reason: 'the app kind keeps its default');
    expect(lit(tester), isFalse);
    expect(label(tester), '显示快捷区');
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(es.prefs.quickHiddenTerm, isFalse);
    expect(lit(tester), isTrue);
  });

  testWidgets('an app session flips quickHiddenApp only', (tester) async {
    big(tester);
    await tester.pumpWidget(layer(app));
    await tester.pump();
    expect(lit(tester), isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(es.prefs.quickHiddenApp, isFalse);
    expect(es.prefs.quickHiddenTerm, isFalse);
    expect(lit(tester), isTrue);
  });

  testWidgets('the light follows foldKeyBar and the other kind is untouched', (tester) async {
    big(tester);
    es.setQuickAutoHide(true);
    await tester.pumpWidget(layer(tapp));
    await tester.pump();
    expect(lit(tester), isTrue);
    es.setQuickHidden(term: !termKind(es, tapp), hidden: false);
    await tester.pumpAndSettle();
    expect(lit(tester), isTrue);
    foldKeyBar(es, tapp);
    await tester.pumpAndSettle();
    expect(lit(tester), isFalse);
  });

  testWidgets('tapping the toggle keeps the draft and the panel open', (tester) async {
    big(tester);
    await tester.pumpWidget(layer(app));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('composer-field')), 'abc');
    await tester.pump();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.composer.open, isTrue);
    expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.text, 'abc');
  });

  testWidgets('Linux: a mouse click on the toggle keeps the caret in the text', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      big(tester);
      await tester.pumpWidget(layer(app));
      await tester.pump();
      final field = find.byKey(const Key('composer-field'));
      await tester.tap(field, kind: PointerDeviceKind.mouse);
      await tester.pump();
      FocusNode node() => tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).focusNode;
      expect(node().hasFocus, isTrue);
      await tester.tap(toggle, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(node().hasFocus, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a screen reader hears the toggle\'s name once, not again from its tooltip', (tester) async {
    big(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(layer(tapp));
    await tester.pump();
    final node = tester.getSemantics(toggle);
    expect(node.label, '收起快捷区');
    expect(node.tooltip, isEmpty);
    handle.dispose();
  });

  testWidgets('beside 输入 the toggle fades in as the box folds, at once under reduced motion', (tester) async {
    big(tester);
    app.composer.open = false;
    final fade = find.byKey(const Key('quick-toggle-fade'));
    double opacity() => tester.widget<Opacity>(fade).opacity;
    await tester.pumpWidget(layer(app));
    expect(opacity(), lessThan(0.5));
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(wrap(
        SizedBox(
            width: 1000,
            height: 700,
            child: Stack(children: composerLayer(state: es, session: app, port: port, editor: FlutterEditor.new))),
        disableAnimations: true));
    expect(opacity(), 1);
  });

  testWidgets('tooltip names the action', (tester) async {
    big(tester);
    await tester.pumpWidget(layer(tapp));
    await tester.pump();
    expect(find.byTooltip('收起快捷区'), findsOneWidget);
  });
}
