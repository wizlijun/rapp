import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/secure_text_field.dart';

void main() {
  late List<String> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SecureInput.channel,
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SecureInput.channel, null);
  });

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: Column(children: [child])));

  testWidgets('focus begins, blur ends, refocus begins again', (tester) async {
    final other = FocusNode();
    addTearDown(other.dispose);
    await tester.pumpWidget(app(Column(children: [
      const SecureTextField(key: Key('pw')),
      Focus(focusNode: other, child: const SizedBox()),
    ])));
    expect(calls, isEmpty);
    await tester.tap(find.byKey(const Key('pw')));
    await tester.pump();
    expect(calls, ['begin']);
    other.requestFocus();
    await tester.pump();
    expect(calls, ['begin', 'end']);
    await tester.tap(find.byKey(const Key('pw')));
    await tester.pump();
    expect(calls, ['begin', 'end', 'begin']);
  });

  testWidgets('a field removed while focused ends', (tester) async {
    await tester.pumpWidget(app(const SecureTextField(autofocus: true)));
    await tester.pump();
    expect(calls, ['begin']);
    await tester.pumpWidget(app(const SizedBox()));
    expect(calls, ['begin', 'end']);
  });

  testWidgets('a field removed without focus sends nothing', (tester) async {
    await tester.pumpWidget(app(const SecureTextField()));
    await tester.pumpWidget(app(const SizedBox()));
    expect(calls, isEmpty);
  });

  testWidgets('moving focus between two password fields stays paired', (tester) async {
    await tester.pumpWidget(app(const Column(children: [
      SecureTextField(key: Key('a'), autofocus: true),
      SecureTextField(key: Key('b')),
    ])));
    await tester.pump();
    await tester.tap(find.byKey(const Key('b')));
    await tester.pump();
    await tester.pumpWidget(app(const SizedBox()));
    expect(calls.where((c) => c == 'begin').length, 2);
    expect(calls.where((c) => c == 'end').length, 2);
    expect(calls.last, 'end');
  });

  testWidgets('a disabled field gives up focus and ends', (tester) async {
    await tester.pumpWidget(app(const SecureTextField(autofocus: true)));
    await tester.pump();
    await tester.pumpWidget(app(const SecureTextField(autofocus: true, enabled: false)));
    await tester.pump();
    expect(calls, ['begin', 'end']);
  });

  testWidgets('a caller focus node is listened to and left undisposed', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(app(SecureTextField(focusNode: node)));
    node.requestFocus();
    await tester.pump();
    expect(calls, ['begin']);
    node.unfocus();
    await tester.pump();
    expect(calls, ['begin', 'end']);
    await tester.pumpWidget(app(const SizedBox()));
    expect(calls, ['begin', 'end']);
  });

  testWidgets('the field is obscured with no suggestions', (tester) async {
    await tester.pumpWidget(app(const SecureTextField()));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
  });

  testWidgets('no native side (Linux) is a quiet no-op', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SecureInput.channel, null);
    await tester.pumpWidget(app(const SecureTextField(autofocus: true)));
    await tester.pump();
    await tester.pumpWidget(app(const SizedBox()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
