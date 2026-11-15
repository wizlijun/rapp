import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/ui/unlock.dart';
import 'package:rapp/ui/stage.dart';
import 'desktop_test.dart' show DesktopEnv;
import 'helpers.dart';

class MemoryUnlockStore extends UnlockStore {
  MemoryUnlockStore({bool supported = true}) : super(supported: supported);
  UnlockCredential? credential;
  Completer<UnlockCredential?>? pending;
  bool fail = false;
  @override
  Future<UnlockCredential?> read(String device) async {
    if (fail) throw StateError('secret must not be echoed');
    return pending == null ? credential : pending!.future;
  }

  @override
  Future<void> save(
    String device,
    String password, {
    required bool auto,
  }) async {
    if (fail) throw StateError('secret must not be echoed');
    credential = UnlockCredential(password, auto: auto);
  }

  @override
  Future<void> forget(String device) async {
    credential = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rapp/unlock');
  test(
    'Keychain bridge round trips, forgets, and never invokes storage on other platforms',
    () async {
      final calls = <MethodCall>[];
      Map<String, dynamic>? saved;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'read':
                return saved;
              case 'save':
                saved = Map<String, dynamic>.from(call.arguments as Map);
              case 'forget':
                saved = null;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final store = UnlockStore(supported: true);
      await store.save('A', 'pässword', auto: true);
      final read = await store.read('A');
      expect(read!.password, 'pässword');
      expect(read.auto, true);
      await store.forget('A');
      expect(await store.read('A'), isNull);
      final count = calls.length;
      final other = UnlockStore(supported: false);
      expect(await other.read('A'), isNull);
      await other.forget('A');
      await expectLater(
        other.save('A', 'secret', auto: true),
        throwsUnsupportedError,
      );
      expect(calls, hasLength(count));
    },
  );

  void env(void Function(FakeAsync, DesktopEnv, MemoryUnlockStore) body) {
    fakeAsync((a) {
      final store = MemoryUnlockStore()
        ..credential = const UnlockCredential('secret', auto: true);
      final e = DesktopEnv(unlockStore: store);
      try {
        e.open();
        a.flushMicrotasks();
        body(a, e, store);
      } finally {
        e.dispose();
        a.flushMicrotasks();
      }
    });
  }

  test(
    'auto unlock is once per connection, only when first state is locked',
    () {
      env((a, e, store) {
        final sid = e.sid('desktop:');
        e.port.emit(ScreenLockedEvent(sid, true));
        a.flushMicrotasks();
        expect(e.calls('unlock').single, {'sid': sid, 'password': 'secret'});
        e.port.emit(ScreenLockedEvent(sid, true));
        e.port.emit(ScreenLockedEvent(e.sid('desktop:22'), true));
        e.port.emit(ScreenLockedEvent(sid, false));
        e.port.emit(ScreenLockedEvent(sid, true));
        a.flushMicrotasks();
        expect(e.calls('unlock'), hasLength(1));
        e.port.emit(DisconnectedEvent(sid, 'connection closed'));
        e.state.reconnect('111/desktop:');
        a.flushMicrotasks();
        e.port.emit(ScreenLockedEvent(e.sid('desktop:'), true));
        a.flushMicrotasks();
        expect(e.calls('unlock'), hasLength(2));
      });
      env((a, e, store) {
        final sid = e.sid('desktop:');
        e.port.emit(ScreenLockedEvent(sid, false));
        e.port.emit(ScreenLockedEvent(sid, true));
        a.flushMicrotasks();
        expect(e.calls('unlock'), isEmpty);
      });
    },
  );

  test(
    'pending Keychain read never unlocks a later lock or ended connection',
    () {
      env((a, e, store) {
        store.pending = Completer<UnlockCredential?>();
        final sid = e.sid('desktop:');
        e.port.emit(ScreenLockedEvent(sid, true));
        e.port.emit(ScreenLockedEvent(sid, false));
        e.port.emit(ScreenLockedEvent(sid, true));
        store.pending!.complete(store.credential);
        a.flushMicrotasks();
        expect(e.calls('unlock'), isEmpty);
      });
      env((a, e, store) {
        store.pending = Completer<UnlockCredential?>();
        e.port.emit(ScreenLockedEvent(e.sid('desktop:'), true));
        e.state.endCurrent();
        store.pending!.complete(store.credential);
        a.flushMicrotasks();
        expect(e.calls('unlock'), isEmpty);
      });
    },
  );

  test(
    'manual unlock targets main, warns at five seconds, and forgets unchecked password',
    () {
      env((a, e, store) {
        store.credential = null;
        final sid = e.sid('desktop:');
        e.port.emit(ScreenLockedEvent(sid, true));
        a.flushMicrotasks();
        e.state.select('111/desktop:22');
        e.state.unlock('111', 'typed', remember: true, auto: false);
        a.flushMicrotasks();
        expect(e.calls('unlock').single['sid'], sid);
        expect(store.credential!.password, 'typed');
        a.elapse(const Duration(seconds: 4));
        expect(e.state.hint, isNot('密码可能不对'));
        a.elapse(const Duration(seconds: 1));
        expect(e.state.hint, '密码可能不对');
        e.state.unlock('111', 'again', remember: false, auto: false);
        a.flushMicrotasks();
        expect(store.credential, isNull);
        e.port.emit(ScreenLockedEvent(sid, false));
        e.state.hint = '已解锁';
        a.elapse(const Duration(seconds: 5));
        expect(e.state.hint, '已解锁');
        e.state.unlock('111', 'unused', remember: false, auto: false);
        a.flushMicrotasks();
        expect(e.calls('unlock'), hasLength(2));
        expect(e.state.hint, 'A 没有锁屏，没有输入密码');
      });
    },
  );

  test(
    'unknown lock state, long UTF8 passwords, and store errors never leak secrets',
    () {
      env((a, e, store) {
        e.state.unlock('111', 'unknown', remember: false, auto: false);
        a.flushMicrotasks();
        expect(e.calls('unlock'), isEmpty);
        store.fail = true;
        e.port.emit(ScreenLockedEvent(e.sid('desktop:'), true));
        a.flushMicrotasks();
        expect(e.state.hint, isNot(contains('secret')));
        e.state.unlock('111', '密' * 342, remember: false, auto: false);
        a.flushMicrotasks();
        expect(e.calls('unlock'), isEmpty);
      });
    },
  );

  testWidgets(
    'dialog hides password, loads stored choices, and returns exact user choices',
    (tester) async {
      final store = MemoryUnlockStore()
        ..credential = const UnlockCredential('remembered', auto: true);
      UnlockRequest? result;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showUnlockDialog(
                  context,
                  store: store,
                  device: 'A',
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        true,
      );
      expect(find.text('记住密码'), findsOneWidget);
      expect(find.text('连上时自动输入'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'new password');
      await tester.tap(find.text('记住密码'));
      await tester.pump();
      await tester.tap(find.text('输入系统密码').last);
      await tester.pumpAndSettle();
      expect(result!.password, 'new password');
      expect(result!.remember, false);
      expect(result!.auto, false);
    },
  );

  testWidgets('desktop banner opens dialog and sends entered password', (
    tester,
  ) async {
    final store = MemoryUnlockStore(supported: false);
    final e = DesktopEnv(unlockStore: store);
    await tester.runAsync(() => e.state.openOrSwitch('111', 'desktop:', '桌面'));
    e.port.emit(ScreenLockedEvent(e.sid('desktop:'), true));
    await tester.pumpWidget(wrap(Stage(state: e.state)));
    await tester.tap(find.text('输入系统密码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'typed secret');
    await tester.tap(find.widgetWithText(FilledButton, '输入系统密码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(e.calls('unlock').single['password'], 'typed secret');
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });

  testWidgets('forget deletes stored password and cancel sends no request', (
    tester,
  ) async {
    final store = MemoryUnlockStore()
      ..credential = const UnlockCredential('saved', auto: true);
    UnlockRequest? result;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showUnlockDialog(
                context,
                store: store,
                device: 'A',
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('忘记密码'));
    await tester.pumpAndSettle();
    expect(store.credential, isNull);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('other platforms offer only manual input', (tester) async {
    final store = MemoryUnlockStore(supported: false);
    await tester.pumpWidget(wrap(UnlockDialog(store: store, device: 'A')));
    await tester.pump();
    expect(find.text('记住密码'), findsNothing);
    expect(find.text('连上时自动输入'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });
}
