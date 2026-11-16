import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/composer_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/linux_candidates.dart';
import 'package:rapp/ui/tokens.dart';

void main() {
  const channel = MethodChannel('rapp/linux_candidates');
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Optional real-font run: no machine-specific paths in the test suite.
    final path = Platform.environment['RAPP_TEST_CJK_FONT'];
    if (path != null) {
      final loader = FontLoader('CandidateRegressionCJK');
      loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  late FocusNode focus;
  late TextEditingController controller;
  setUp(() {
    calls.clear();
    focus = FocusNode();
    controller = TextEditingController(text: 'draft');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    focus.dispose();
    controller.dispose();
  });
  Map<Object?, Object?> state() =>
      (calls.lastWhere((c) => c.method == 'state').arguments as Map).cast<Object?, Object?>();
  Future<void> mount(
    WidgetTester tester, {
    double width = 340,
    double height = 180,
    RappTheme? theme,
    double scale = 1,
    TextStyle? style,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme == null ? null : themeDataFor(theme),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Center(
              child: SizedBox(
                width: width * scale,
                child: RepaintBoundary(
                  key: const Key('candidate-preview'),
                  child: LinuxCandidatesSurface(
                    focus: focus,
                    controller: controller,
                    style: style ?? const TextStyle(fontSize: 15, height: 22 / 15, color: Colors.black),
                    maxHeight: height,
                    child: TextField(controller: controller, focusNode: focus),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.pump();
  }

  Future<void> emit(
    WidgetTester tester, {
    String serial = '18446744073709551615',
    int? epoch,
    List<Map<String, Object>>? rows,
  }) async {
    final owner = state();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall('candidates', {
          'editor': owner['editor'],
          'epoch': epoch ?? owner['epoch'],
          'token': 'lease',
          'serial': serial,
          'cursor': 7,
          'previous': false,
          'next': true,
          'rows':
              rows ??
              [
                {'index': 7, 'label': '1', 'text': '候选词'},
                {'index': 19, 'label': '2', 'text': '第二个'},
              ],
        }),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  for (final theme in RappTheme.values) {
    for (final scale in [1.0, 1.2222, 1.75]) {
      for (final width in [220.0, 340.0]) {
        testWidgets('candidate glyphs remain visible ${theme.name} $scale $width', (tester) async {
          final t = tokensFor(theme);
          await mount(
            tester,
            theme: theme,
            scale: scale,
            width: width,
            style: TextStyle(
              fontSize: 15,
              height: 22 / 15,
              color: t.text,
              fontFamily: Platform.environment.containsKey('RAPP_TEST_CJK_FONT') ? 'CandidateRegressionCJK' : t.font,
              fontFamilyFallback: t.fontFallback,
            ),
          );
          await emit(
            tester,
            rows: [
              {'index': 7, 'label': '1.', 'text': '你好'},
              {'index': 19, 'label': '2.', 'text': '输入法'},
            ],
          );
          final paragraphs = find.descendant(of: find.byType(LinuxCandidatesSurface), matching: find.byType(RichText));
          var checked = 0;
          for (final element in paragraphs.evaluate()) {
            final p = element.renderObject! as RenderParagraph;
            if (!['你好', '输入法'].any(p.text.toPlainText().contains)) continue;
            expect(p.didExceedMaxLines, false, reason: '${p.text.toPlainText()} was ellipsized');
            // Check each candidate glyph has a laid-out box, not just a TextSpan.
            final full = p.text.toPlainText();
            final start = full.indexOf(' ') + 1;
            for (var i = start; i < full.length; i++) {
              expect(p.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1)), isNotEmpty);
            }
            checked++;
          }
          expect(checked, greaterThan(0));
          expect(tester.takeException(), isNull);
          final imageDir = Platform.environment['RAPP_CANDIDATE_IMAGE_DIR'];
          if (imageDir != null && scale == 1.2222 && width == 340) {
            await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('candidate-preview')));
              final image = await boundary.toImage(pixelRatio: 2);
              final data = await image.toByteData(format: ui.ImageByteFormat.png);
              await Directory(imageDir).create(recursive: true);
              await File('$imageDir/${theme.name}.png').writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
          await unmount(tester);
        });
      }
    }
  }

  testWidgets('paints before acknowledging and preserves unsigned serial/real index', (tester) async {
    await mount(tester);
    expect(state()['active'], true);
    controller.value = const TextEditingValue(
      text: 'draftni',
      selection: TextSelection.collapsed(offset: 7),
      composing: TextRange(start: 5, end: 7),
    );
    await emit(tester);
    expect(calls.where((c) => c.method == 'rendered'), isNotEmpty);
    expect(find.textContaining('候选词'), findsOneWidget);
    for (final label in ['候选词', '第二个']) {
      final rich = find.descendant(of: find.textContaining(label), matching: find.byType(RichText));
      final paragraph = tester.renderObject<RenderParagraph>(rich);
      expect(
        paragraph.didExceedMaxLines,
        false,
        reason: '$label must actually be visible, not merely present in TextSpan',
      );
    }
    await tester.tap(find.textContaining('候选词'));
    final call = calls.lastWhere((c) => c.method == 'select');
    expect((call.arguments as Map)['index'], 7);
    expect((call.arguments as Map)['serial'], '18446744073709551615');
    expect(controller.text, 'draftni');
    expect(controller.value.composing, const TextRange(start: 5, end: 7));
    await tester.tap(find.textContaining('候选词'));
    expect(calls.where((c) => c.method == 'select').length, 1);
    await unmount(tester);
    expect(calls.last.method, 'dispose');
  });
  testWidgets('releases on focus loss and ignores old editor epoch', (tester) async {
    await mount(tester);
    final before = state()['epoch'] as int;
    await emit(tester);
    focus.unfocus();
    await tester.pump();
    expect(state()['active'], false);
    expect(find.textContaining('候选词'), findsNothing);
    focus.requestFocus();
    await tester.pump();
    await tester.pump();
    await emit(tester, epoch: before);
    expect(find.textContaining('候选词'), findsNothing);
    await emit(tester);
    expect(find.textContaining('候选词'), findsOneWidget);
    await unmount(tester);
  });
  testWidgets('capacity fallback and local paging keep normal text field', (tester) async {
    await mount(tester, width: 220);
    await emit(
      tester,
      rows: [
        for (var i = 0; i < 12; i++) {'index': i * 3 + 7, 'label': '${i + 1}', 'text': '候选词$i'},
      ],
    );
    expect(find.textContaining('候选词0'), findsOneWidget);
    await tester.tap(find.text('›'));
    await tester.pump();
    expect(find.textContaining('候选词0'), findsNothing);
    expect(calls.where((c) => c.method == 'page'), isEmpty);
    await mount(tester, width: 80, height: 60);
    expect(state()['active'], false);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
  testWidgets('heartbeats do not send editor text and stop after disposal', (tester) async {
    await mount(tester);
    calls.clear();
    await tester.pump(const Duration(milliseconds: 900));
    expect(calls.where((c) => c.method == 'state'), isNotEmpty);
    for (final call in calls) {
      expect((call.arguments as Map).containsKey('text'), false);
    }
    await unmount(tester);
    calls.clear();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, isEmpty);
  });
  testWidgets('keeps one transparent row until empty or focus leaves, using editor font', (tester) async {
    await mount(tester);
    final before = tester.getSize(find.byType(LinuxCandidatesSurface)).height;
    await emit(tester);
    final after = tester.getSize(find.byType(LinuxCandidatesSurface)).height;
    expect(after - before, closeTo(35, .01));
    final candidate = tester.widget<Text>(find.textContaining('候选词'));
    final span = candidate.textSpan! as TextSpan;
    final word = span.children!.last as TextSpan;
    expect(word.style!.fontSize, 15);
    expect(word.style!.decoration, TextDecoration.underline);
    await emit(tester, serial: '18446744073709551615', rows: []);
    expect(tester.getSize(find.byType(LinuxCandidatesSurface)).height, after);
    controller.clear();
    await tester.pump();
    expect(tester.getSize(find.byType(LinuxCandidatesSurface)).height, before);
    await unmount(tester);
  });
  testWidgets('keeps the engine cursor visible after reflow and releases on pause', (tester) async {
    await mount(tester, width: 600);
    await emit(
      tester,
      rows: [
        {'index': 1, 'label': '1', 'text': '第一页的长候选'},
        {'index': 7, 'label': '2', 'text': '第二页的长候选'},
      ],
    );
    expect(find.textContaining('第一页的长候选'), findsOneWidget);
    await mount(tester, width: 220);
    expect(find.textContaining('第二页的长候选'), findsOneWidget);
    expect(find.textContaining('第一页的长候选'), findsNothing);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(state()['active'], false);
    expect(find.textContaining('第二页的长候选'), findsNothing);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await unmount(tester);
  });
  testWidgets('Linux FlutterEditor handoff releases candidates and retains pending IME read', (tester) async {
    final editor = FlutterEditor();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 340,
            child: Builder(
              builder: (context) => editor.view(
                context,
                style: const EditorStyle(
                  text: TextStyle(fontSize: 15, height: 22 / 15),
                  color: Colors.black,
                  hintColor: Colors.grey,
                  cursor: Colors.black,
                ),
                hint: '',
                maxHeight: 180,
              ),
            ),
          ),
        ),
      ),
    );
    editor.focus();
    await tester.pump();
    await tester.pump();
    final text = tester.widget<TextField>(find.byType(TextField)).controller!;
    text.value = const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await emit(tester);
    editor.insert(' pasted');
    editor.setHandoff(true);
    final pending = editor.read();
    await tester.pump();
    expect(state()['active'], false);
    expect(find.textContaining('候选词'), findsNothing);
    expect(await pending, 'ni pasted');
    await unmount(tester);
    editor.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));
  test('rejects corrupted indices and out-of-range unsigned serials', () {
    final valid = <Object?, Object?>{
      'token': 't',
      'serial': '18446744073709551615',
      'cursor': 3,
      'rows': [
        {'index': 3, 'label': '1', 'text': '字'},
      ],
    };
    expect(LinuxCandidateSnapshot.parse(valid), isNotNull);
    expect(LinuxCandidateSnapshot.parse({...valid, 'serial': '18446744073709551616'}), isNull);
    expect(
      LinuxCandidateSnapshot.parse({
        ...valid,
        'rows': [
          {'index': -1, 'label': '1', 'text': '字'},
        ],
      }),
      isNull,
    );
  });
}
