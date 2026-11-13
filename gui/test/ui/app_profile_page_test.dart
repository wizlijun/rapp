import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/pages/app_profile_page.dart';
import 'package:rapp/ui/app_profile_store.dart';
import 'package:rapp/ui/tokens.dart';

import 'helpers.dart';

const _chrome = 'com.google.Chrome';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('apps'));
  tearDown(() => dir.deleteSync(recursive: true));

  AppProfileStore storeWith({bool tested = false}) => AppProfileStore(dir.path, builtin: [
        AppProfile(ids: [_chrome], name: 'Google Chrome', mode: 'color16', density: 'adaptive', fps: 15, tested: tested),
      ]);

  Future<void> open(WidgetTester tester, AppProfileStore store, {String? appId, String appName = ''}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(Builder(
      builder: (c) => TextButton(
        onPressed: () => openAppProfilePage(c, store, appId: appId, appName: appName),
        child: const Text('go'),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, Key dd, String label) async {
    await tester.tap(find.byKey(dd));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('built-in values show grey; changing one saves only that field', (tester) async {
    final store = storeWith();
    await open(tester, store, appId: _chrome);
    expect(find.text('未实测'), findsOneWidget);
    expect(find.text('app 配置 · Google Chrome'), findsOneWidget);
    final mode = tester.widget<Text>(find.text('高彩').first);
    expect(mode.style?.color, RappTokens.of(tester.element(find.text('高彩').first)).muted);
    await pick(tester, const Key('fps-dd'), '5 fps');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.mine.single.toJson(), {
      'ids': [_chrome],
      'stream': {'fps': 5}
    });
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('a non-built-in app with no profile is saved under its app name', (tester) async {
    final store = storeWith();
    await open(tester, store, appId: 'com.apple.finder', appName: 'Finder');
    await pick(tester, const Key('fps-dd'), '5 fps');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.mine.single.name, 'Finder');
    expect(store.mine.single.ids, ['com.apple.finder']);
  });

  testWidgets('saving without changes writes nothing', (tester) async {
    final store = storeWith();
    await open(tester, store, appId: _chrome);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.mine, isEmpty);
    expect(File('${dir.path}/apps.json').existsSync(), isFalse);
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('rules: add, warnings, move and delete', (tester) async {
    final store = storeWith();
    await open(tester, store, appId: _chrome);
    await tester.tap(find.text('加一条'));
    await tester.pumpAndSettle();
    expect(find.text('这条会作用于这个 app 的所有子窗口'), findsOneWidget);
    expect(find.text('它可能在等你回应'), findsNothing);
    await pick(tester, const Key('rule-kind-0'), '对话框');
    expect(find.text('这条会作用于这个 app 的所有子窗口'), findsNothing);
    expect(find.text('它可能在等你回应'), findsOneWidget);
    await pick(tester, const Key('rule-action-0'), '不要输入区');
    expect(find.text('它可能在等你回应'), findsNothing);

    await tester.tap(find.text('加一条'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rule-title-1')), 'b');
    await tester.pumpAndSettle();
    await tester.tap(find.text('上移').at(1));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.descendant(of: find.byKey(const Key('rule-title-0')), matching: find.byType(TextField))).controller!.text, 'b');

    // a third rule, deleted again
    await tester.tap(find.text('加一条'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsNWidgets(3));
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsNWidgets(2));

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final w = store.mine.single.windows!;
    expect(w.length, 2);
    expect(w.first.title, 'b');
    expect(w.first.action, RuleAction.hide);
    expect(w.last.kind, WindowKind.dialog);
    expect(w.last.action, RuleAction.noComposer);
  });

  testWidgets('new: no ids, no save', (tester) async {
    final store = storeWith();
    await open(tester, store);
    expect(find.text('新建 app 配置'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('至少写一个标识'), findsOneWidget);
    expect(store.mine, isEmpty);

    await tester.enterText(find.byKey(const Key('ids-field')), 'com.foo, com.bar');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.mine.single.ids, ['com.foo', 'com.bar']);
  });

  testWidgets('no English words like profile or regex on the page', (tester) async {
    final store = storeWith();
    await open(tester, store, appId: _chrome);
    await tester.tap(find.text('加一条'));
    await tester.pumpAndSettle();
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      expect(t.data?.toLowerCase() ?? '', isNot(anyOf(contains('profile'), contains('regex'))));
    }
  });
}
