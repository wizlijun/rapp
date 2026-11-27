import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/phone/home_model.dart';
import 'package:rapp/phone/widgets.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/tokens.dart';

HomeItem item({
  HomeKind kind = HomeKind.waiting,
  String line = goLookLine,
  String? key = 'k',
  HomeButton button = HomeButton.goLook,
}) =>
    HomeItem(
      kind: kind,
      id: 'x',
      lamp: kind == HomeKind.waiting ? Lamp.waiting : Lamp.idle,
      what: kind == HomeKind.waiting ? '在等确认' : '做完了',
      program: 'Claude',
      device: 'mac2',
      line: line,
      since: 1,
      button: button,
      sessionKey: key,
    );

Widget wrap(RappTheme th, Widget child, {Size size = const Size(390, 844), double scale = 1}) => MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        theme: themeDataFor(th),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  for (final th in RappTheme.values) {
    group(th.name, () {
      testWidgets('buttons are tall enough', (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(wrap(th, Column(children: [
          PhoneButton(key: const Key('a'), label: '好', onPressed: () {}),
          PhoneButton(key: const Key('b'), label: '好', primary: true, onPressed: () {}),
        ])));
        expect(tester.getSize(find.byKey(const Key('a'))).height, 56);
        expect(tester.getSize(find.byKey(const Key('b'))).height, 64);
      });

      testWidgets('card with empty msg lays out', (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(wrap(th, PhoneCard(item: item(), onOpen: () {}, onButton: () {})));
        expect(find.text('在等确认 · Claude · mac2'), findsOneWidget);
        expect(find.text('它没说要做什么。点上面的字进去看。'), findsOneWidget);
        expect(find.text('进去看'), findsOneWidget);
        expect(find.text(''), findsNothing);
      });

      testWidgets('waiting card uses accent edge', (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(wrap(th, Column(children: [
          PhoneCard(key: const Key('w'), item: item(), onOpen: () {}, onButton: () {}),
          PhoneCard(
              key: const Key('d'),
              item: item(kind: HomeKind.done, line: '好了', button: HomeButton.gotIt),
              onOpen: () {},
              onButton: () {}),
        ])));
        final t = RappTokens.of(tester.element(find.byKey(const Key('w'))));
        BoxDecoration deco(String k) => tester
            .widget<DecoratedBox>(find.descendant(of: find.byKey(Key(k)), matching: find.byType(DecoratedBox)).first)
            .decoration as BoxDecoration;
        final w = deco('w');
        expect((w.border as Border).top.color, t.accent);
        expect(w.color, t.tint);
        final d = deco('d');
        expect(d.color, t.panel.first);
        expect((d.border as Border).top.color, isNot(t.accent));
      });

      testWidgets('card reads as one sentence', (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final h = tester.ensureSemantics();
        await tester.pumpWidget(wrap(th, PhoneCard(item: item(line: '要删文件'), onOpen: () {}, onButton: () {})));
        expect(tester.getSemantics(find.byType(PhoneCard)).label, '在等确认，Claude 在 mac2，要删文件');
        h.dispose();
      });
    });
  }

  testWidgets('page centers at 480', (tester) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(844, 390)),
      child: MaterialApp(
        theme: themeDataFor(RappTheme.avatar),
        home: const PhonePage(child: SizedBox.expand(key: Key('c'))),
      ),
    ));
    final r = tester.getRect(find.byKey(const Key('c')));
    expect(r.width, 480);
    expect(r.left, 182);
    expect(844 - r.right, 182);
  });

  testWidgets('matrix wraps not truncates', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final line = List.filled(40, '字').join();
    await tester.pumpWidget(wrap(RappTheme.matrix, PhoneCard(item: item(line: line), onOpen: () {}, onButton: () {}),
        size: const Size(375, 667), scale: 1.5));
    expect(tester.takeException(), isNull);
    final txt = tester.widget<Text>(find.text(line));
    expect(txt.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.getSize(find.text(line)).height, greaterThan(30));
  });
}
