import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/phone/hold_button.dart';
import 'package:rapp/ui/tokens.dart';

Widget wrap(Widget child) => MediaQuery(
      data: const MediaQueryData(size: Size(390, 844)),
      child: MaterialApp(
        theme: themeDataFor(RappTheme.values.first),
        home: Scaffold(body: Center(child: SizedBox(width: 300, child: child))),
      ),
    );

RappTokens tokens(WidgetTester tester) => RappTokens.of(tester.element(find.byType(PhoneHoldButton)));

Color? bg(WidgetTester tester) {
  final box = tester.widget<Container>(find.byKey(const Key('hold-box')));
  return (box.decoration as BoxDecoration).color;
}

Color? fg(WidgetTester tester, String label) => tester.widget<Text>(find.text(label)).style?.color;

void main() {
  late int sent;
  setUp(() => sent = 0);

  Widget button({Object key = 1, bool risky = false, VoidCallback? onSend, bool useDefault = true}) => wrap(
        PhoneHoldButton(label: '允许', armKey: key, risky: risky, onSend: useDefault ? () => sent++ : onSend),
      );

  testWidgets('sends on release over the button', (tester) async {
    await tester.pumpWidget(button());
    final g = await tester.startGesture(tester.getCenter(find.byType(PhoneHoldButton)));
    expect(sent, 0);
    await g.up();
    expect(sent, 1);
  });

  testWidgets('press shows pressed look', (tester) async {
    await tester.pumpWidget(button());
    final t = tokens(tester);
    final before = bg(tester);
    final g = await tester.startGesture(tester.getCenter(find.byType(PhoneHoldButton)));
    await tester.pump();
    expect(bg(tester), t.accent);
    expect(fg(tester, '允许'), t.accentInk);
    await g.up();
    await tester.pump();
    expect(bg(tester), before);
    expect(fg(tester, '允许'), isNot(t.accentInk));
  });

  testWidgets('slide off cancels', (tester) async {
    await tester.pumpWidget(button());
    final t = tokens(tester);
    final c = tester.getCenter(find.byType(PhoneHoldButton));
    final g = await tester.startGesture(c);
    await g.moveTo(c + const Offset(0, 200));
    await tester.pump();
    expect(bg(tester), isNot(t.accent));
    await g.up();
    expect(sent, 0);
  });

  testWidgets('slide off and back in still sends', (tester) async {
    await tester.pumpWidget(button());
    final c = tester.getCenter(find.byType(PhoneHoldButton));
    final g = await tester.startGesture(c);
    await g.moveTo(c + const Offset(0, 200));
    await g.moveTo(c);
    await g.up();
    expect(sent, 1);
  });

  testWidgets('voids when the card changes under the finger', (tester) async {
    await tester.pumpWidget(button());
    final c = tester.getCenter(find.byType(PhoneHoldButton));
    final g = await tester.startGesture(c);
    await tester.pumpWidget(button(key: 2));
    await g.up();
    expect(sent, 0);
  });

  testWidgets('voids when removed mid-press', (tester) async {
    await tester.pumpWidget(button());
    final c = tester.getCenter(find.byType(PhoneHoldButton));
    final g = await tester.startGesture(c);
    await tester.pumpWidget(wrap(const SizedBox()));
    await g.up();
    expect(sent, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('risky needs two releases within 3 s', (tester) async {
    await tester.pumpWidget(button(risky: true));
    final t = tokens(tester);
    final c = tester.getCenter(find.byType(PhoneHoldButton));
    var g = await tester.startGesture(c);
    await g.up();
    await tester.pump();
    expect(sent, 0);
    expect(find.text('再点一次确认'), findsOneWidget);
    expect(fg(tester, '再点一次确认'), t.accent);
    g = await tester.startGesture(c);
    await g.up();
    await tester.pump();
    expect(sent, 1);
    expect(find.text('允许'), findsOneWidget);
  });

  testWidgets('risky arm resets after 3 s', (tester) async {
    await tester.pumpWidget(button(risky: true));
    final c = tester.getCenter(find.byType(PhoneHoldButton));
    var g = await tester.startGesture(c);
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('允许'), findsOneWidget);
    g = await tester.startGesture(c);
    await g.up();
    expect(sent, 0);
  });

  testWidgets('risky arm cancelled by slide off', (tester) async {
    await tester.pumpWidget(button(risky: true));
    final c = tester.getCenter(find.byType(PhoneHoldButton));
    var g = await tester.startGesture(c);
    await g.moveTo(c + const Offset(0, 200));
    await g.up();
    await tester.pump();
    expect(find.text('允许'), findsOneWidget);
    g = await tester.startGesture(c);
    await g.up();
    await tester.pump();
    expect(sent, 0);
    expect(find.text('再点一次确认'), findsOneWidget);
  });

  testWidgets('armKey change clears the risky arm', (tester) async {
    await tester.pumpWidget(button(risky: true));
    final c = tester.getCenter(find.byType(PhoneHoldButton));
    final g = await tester.startGesture(c);
    await g.up();
    await tester.pump();
    await tester.pumpWidget(button(risky: true, key: 2));
    expect(find.text('允许'), findsOneWidget);
  });

  testWidgets('semantics tap sends; risky takes two', (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(button());
    tester.semantics.tap(find.semantics.byLabel('允许'));
    await tester.pump();
    expect(sent, 1);
    await tester.pumpWidget(button(risky: true, key: 5));
    tester.semantics.tap(find.semantics.byLabel('允许'));
    await tester.pump();
    expect(sent, 1);
    tester.semantics.tap(find.semantics.byLabel('再点一次确认'));
    await tester.pump();
    expect(sent, 2);
    h.dispose();
  });

  testWidgets('disabled when onSend is null', (tester) async {
    await tester.pumpWidget(button(useDefault: false));
    final g = await tester.startGesture(tester.getCenter(find.byType(PhoneHoldButton)));
    await tester.pump();
    await g.up();
    expect(sent, 0);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, lessThan(1));
  });

  testWidgets('size is 64', (tester) async {
    await tester.pumpWidget(button());
    expect(tester.getSize(find.byType(PhoneHoldButton)).height, 64);
  });
}
