import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/pages/update_section.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/update.dart';

import 'ui/helpers.dart';

void main() {
  late List<String> calls;
  late List<String> opened;
  Object? applyError;

  setUp(() {
    calls = [];
    opened = [];
    applyError = null;
  });

  Widget section(UpdateInfo u) => wrap(SizedBox(
        width: 600,
        child: UpdateSection(
          info: u,
          onCheck: () async => calls.add('check'),
          onApply: (confirm) async {
            calls.add('apply:$confirm');
            if (applyError != null) throw applyError!;
          },
          onDismiss: (v) async => calls.add('dismiss:$v'),
          onRollback: () async => calls.add('rollback'),
          onSetAuto: (on) async => calls.add('auto:$on'),
          onOpenPage: opened.add,
        ),
      ));

  const ready = UpdateInfo(current: '0.4.1', state: 'ready', latest: '0.5.0', notes: '修好了剪贴板');

  testWidgets('ready shows apply and dismiss', (tester) async {
    await tester.pumpWidget(section(ready));
    expect(find.text('版本与升级'), findsOneWidget);
    expect(find.text('0.5.0 已下载，没人在用时会自动装好'), findsOneWidget);
    for (final label in ['立即升级', '这一版先不装']) {
      expect(tester.getSize(find.widgetWithText(OutlinedButton, label)).height, greaterThanOrEqualTo(48));
    }
    await tester.tap(find.text('立即升级'));
    await tester.pump();
    await tester.tap(find.text('这一版先不装'));
    await tester.pump();
    expect(calls, ['apply:false', 'dismiss:0.5.0']);
  });

  testWidgets('apply anyway confirms the signature change', (tester) async {
    await tester.pumpWidget(section(const UpdateInfo(
        current: '0.4.1', state: 'ready', latest: '0.5.0', needsConfirm: true)));
    expect(find.text('立即升级'), findsNothing);
    await tester.tap(find.text('仍然安装'));
    await tester.pump();
    expect(calls, ['apply:true']);
  });

  testWidgets('check and open page', (tester) async {
    await tester.pumpWidget(section(const UpdateInfo(current: '0.4.1', state: 'up_to_date', latest: '0.4.1')));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(calls, ['check']);

    await tester.pumpWidget(section(const UpdateInfo(
        current: '0.4.1', state: 'ready', latest: '0.5.0', needsAdmin: true, page: 'https://example.invalid/tag')));
    await tester.tap(find.text('打开安装包'));
    await tester.pump();
    expect(opened, ['https://example.invalid/tag']);
  });

  testWidgets('a failed call shows its error in the section, with the page when it has one', (tester) async {
    applyError = ServiceException('服务不是由系统启动的，请从 release 页面手动装 pkg', page: 'https://example.invalid/tag');
    await tester.pumpWidget(section(ready));
    await tester.tap(find.text('立即升级'));
    await tester.pump();
    expect(find.text('服务不是由系统启动的，请从 release 页面手动装 pkg'), findsOneWidget);
    await tester.tap(find.text('打开安装包'));
    await tester.pump();
    expect(opened, ['https://example.invalid/tag']);
  });

  testWidgets('rollback needs two taps', (tester) async {
    await tester.pumpWidget(section(const UpdateInfo(current: '0.4.1', state: 'up_to_date', canRollback: true)));
    await tester.tap(find.text('回到上一版'));
    await tester.pump();
    expect(find.text('再点一次确认'), findsOneWidget);
    expect(calls, isEmpty);
    await tester.tap(find.text('再点一次确认'));
    await tester.pump();
    expect(calls, ['rollback']);

    await tester.pumpWidget(section(const UpdateInfo(current: '0.4.1', state: 'up_to_date')));
    expect(find.text('回到上一版'), findsNothing);
  });

  testWidgets('auto switch calls set', (tester) async {
    await tester.pumpWidget(section(const UpdateInfo(current: '0.4.1', state: 'up_to_date')));
    expect(find.text('自动升级'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(calls, ['auto:false']);
  });

  testWidgets('off shows only the line', (tester) async {
    await tester.pumpWidget(section(const UpdateInfo(current: '', state: 'off')));
    expect(find.text('开发构建，不检查更新'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('检查更新'), findsNothing);
  });

  testWidgets('notes shown only when ready', (tester) async {
    await tester.pumpWidget(section(ready));
    expect(find.text('修好了剪贴板'), findsOneWidget);
    await tester.pumpWidget(section(const UpdateInfo(
        current: '0.4.1', state: 'up_to_date', latest: '0.4.1', notes: '修好了剪贴板')));
    expect(find.text('修好了剪贴板'), findsNothing);
  });

  testWidgets('no accent colour', (tester) async {
    await tester.pumpWidget(section(const UpdateInfo(
        current: '0.4.1', state: 'ready', latest: '0.5.0', notes: 'n', canRollback: true)));
    final t = RappTokens.of(tester.element(find.byType(UpdateSection)));
    final inside = find.descendant(of: find.byType(UpdateSection), matching: find.byType(Container));
    for (final c in tester.widgetList<Container>(inside)) {
      expect(c.color, isNot(t.accent));
      final d = c.decoration;
      if (d is BoxDecoration) expect(d.color, isNot(t.accent));
    }
    final boxes = find.descendant(of: find.byType(UpdateSection), matching: find.byType(DecoratedBox));
    for (final b in tester.widgetList<DecoratedBox>(boxes)) {
      final d = b.decoration;
      if (d is BoxDecoration) expect(d.color, isNot(t.accent));
    }
  });
}
