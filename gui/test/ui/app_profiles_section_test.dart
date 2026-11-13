import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/pages/app_profiles_section.dart';
import 'package:rapp/ui/app_profile_store.dart';

import 'helpers.dart';

void main() {
  late Directory dir;
  late AppProfileStore store;
  late List<String> openedDirs;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('apps');
    openedDirs = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> show(WidgetTester tester, {String? problem}) async {
    store = AppProfileStore(dir.path,
        builtin: [AppProfile(ids: ['b1'], name: 'B1', tested: false), AppProfile(ids: ['b2'], name: 'B2', tested: false)],
        mine: [AppProfile(ids: ['B2'], fps: 5), AppProfile(ids: ['m'], name: 'M'), AppProfile(ids: ['m'], name: 'M2')],
        problem: problem);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(SingleChildScrollView(
      child: AppProfilesSection(store: store, openFolder: (d) async => openedDirs.add(d)),
    )));
  }

  testWidgets('rows show source, 未实测 and duplicates', (tester) async {
    await show(tester);
    expect(find.text('内置'), findsOneWidget);
    expect(find.text('内置 + 我改过'), findsOneWidget);
    expect(find.text('我的'), findsNWidgets(2));
    expect(find.text('未实测'), findsNWidgets(2));
    expect(find.text('和 M 重复'), findsOneWidget);
  });

  testWidgets('恢复内置 and 删除 need a second tap', (tester) async {
    await show(tester);
    await tester.tap(find.text('恢复内置'));
    await tester.pump();
    expect(store.mine.length, 3);
    await tester.tap(find.text('再点一次确认'));
    await tester.pump();
    expect(store.mine.length, 2);
    await tester.tap(find.text('删除').first);
    await tester.pump();
    expect(store.mine.length, 2);
    await tester.tap(find.text('再点一次确认'));
    await tester.pump();
    expect(store.mine.length, 1);
  });

  testWidgets('打开配置文件夹 opens the store dir', (tester) async {
    await show(tester);
    await tester.tap(find.text('打开配置文件夹'));
    expect(openedDirs, [dir.path]);
  });

  testWidgets('a load problem shows at the top', (tester) async {
    await show(tester, problem: appsLoadProblem);
    expect(find.text(appsLoadProblem), findsOneWidget);
  });
}
