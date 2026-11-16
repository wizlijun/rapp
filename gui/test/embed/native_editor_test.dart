import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_editor.dart';
import 'package:rapp/embed/native_editor.dart';

void main() {
  const style = EditorStyle(
    text: TextStyle(fontFamily: 'Inter', fontFamilyFallback: ['PingFang SC'], fontSize: 15, height: 22 / 15),
    color: Color(0xff7dff9e),
    hintColor: Color(0xff3fbf68),
    cursor: Color(0xff7dff9e),
  );

  testWidgets('native text commands are FIFO, styles match, and dispose follows the final read', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    final setDone = Completer<void>();
    late MethodChannel channel;
    late Map<Object?, Object?> creation;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      if (call.method == 'create') {
        final args = call.arguments as Map;
        creation = const StandardMessageCodec().decodeMessage(ByteData.sublistView(args['params'])) as Map;
        channel = MethodChannel('rapp/composer/editor-${creation['editorId']}');
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'set') await setDone.future;
          if (call.method == 'read') return '草稿';
          return null;
        });
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(const MethodCall('ready')),
          (_) {},
        );
      }
      return null;
    });
    int toggles = 0;
    final editor = NativeEditor(onToggleFocus: () => toggles++);
    final focus = <bool>[];
    editor.handlers = EditorHandlers(
      onChanged: () {},
      onEnter: () {},
      onEscape: () {},
      onPaste: () {},
      onFocus: focus.add,
      onArrow: (_) => false,
    );
    editor.chips({0xFDD0: '[图片 #1]'});
    editor.setText('草稿﷐');
    editor.focus();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 500,
          child: Builder(
            builder: (c) => editor.view(c, style: style, hint: '写给 Terminal', maxHeight: 160),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(creation['font'], 'Inter');
    expect(creation['fallback'], ['PingFang SC']);
    expect(creation['color'], style.color.toARGB32());
    expect(creation['size'], 15);
    expect(creation['lineHeight'], 22);
    final reading = editor.read();
    await tester.pump();
    expect(calls.where((c) => c.method == 'read'), isEmpty);
    setDone.complete();
    await tester.pump();
    expect(await reading, '草稿');
    expect(calls.where((c) => {'chips', 'set', 'read'}.contains(c.method)).map((c) => c.method),
        ['chips', 'set', 'read'],
        reason: 'the labels come before the text that has their marks');
    expect(calls.firstWhere((c) => c.method == 'chips').arguments, {0xFDD0: '[图片 #1]'});
    Future<void> event(String method, Object? arg) async {
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, arg)),
        (_) {},
      );
    }

    await event('focus', true);
    await editor.readyForInput;
    await event('toggleFocus', null);
    expect(focus, [true]);
    expect(toggles, 1);
    final finalRead = editor.read();
    await tester.pumpWidget(const SizedBox());
    expect(await finalRead, '草稿');
    editor.dispose();
    await tester.pump();
    expect(calls.last.method, 'dispose');
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets('closing while AppKitView is being created still reads and disposes the native draft', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final creationDone = Completer<void>();
    late MethodChannel channel;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      if (call.method == 'create') {
        final args = call.arguments as Map;
        final params = const StandardMessageCodec().decodeMessage(ByteData.sublistView(args['params'])) as Map;
        channel = MethodChannel('rapp/composer/editor-${params['editorId']}');
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return call.method == 'read' ? '尚未打开的草稿' : null;
        });
        await creationDone.future;
      }
      return null;
    });
    final editor = NativeEditor(onToggleFocus: () {});
    editor.setText('尚未打开的草稿');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => editor.view(c, style: style, hint: '', maxHeight: 160),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    final draft = editor.read();
    // The native channel can announce readiness even though Flutter skips its created callback.
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('ready')),
      (_) {},
    );
    creationDone.complete();
    await tester.pump();
    expect(await draft, '尚未打开的草稿');
    editor.dispose();
    await tester.pump();
    expect(calls, containsAllInOrder(['set', 'read', 'dispose']));
    expect(calls, isNot(contains('focus')));
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });
}
