import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp_rime/rapp_rime.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rapp/rime');
  late List<MethodCall> calls;
  late RappRime rime;
  var plugin = true;

  void configure({bool enabled = true, bool builtin = true, void Function(bool)? onBuiltin}) => rime.configure(
    enabled: enabled,
    builtin: builtin,
    dictionary: RimeDictionary.bundled,
    onBuiltin: onBuiltin ?? (_) {},
  );

  Future<void> push(String method, Object? args) => binding.defaultBinaryMessenger.handlePlatformMessage(
    'rapp/rime',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls = [];
    plugin = true;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (!plugin) throw MissingPluginException();
      calls.add(call);
      return null;
    });
    rime = RappRime(channel);
  });
  tearDown(() {
    rime.dispose();
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('configure sends once, and again only on change', () async {
    configure();
    configure();
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['configure']);
    expect(calls.single.arguments, {'enabled': true, 'dictionary': 'bundled'});
    rime.configure(enabled: true, builtin: true, dictionary: RimeDictionary.user, onBuiltin: (_) {});
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['configure', 'configure']);
  });

  test('configure does not touch the channel off iOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    configure();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    expect(rime.enabled, true);
  });

  test('setActive sends active {on}', () async {
    final a = Object();
    configure();
    rime.attach(a, (_) {});
    calls.clear();
    await rime.setActive(a, true);
    expect(calls.single.method, 'active');
    expect(calls.single.arguments, {'on': true});
  });

  test('setActive on a disabled switch sends on: false', () async {
    final a = Object();
    configure(enabled: false);
    rime.attach(a, (_) {});
    calls.clear();
    await rime.setActive(a, true);
    expect(calls.single.arguments, {'on': false});
  });

  test('enabled flipping re-sends active for the owner', () async {
    final a = Object();
    configure(enabled: false);
    rime.attach(a, (_) {});
    await rime.setActive(a, true);
    calls.clear();
    configure();
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['configure', 'active']);
    expect(calls.last.arguments, {'on': true});
  });

  test('a non-owner setActive does nothing', () async {
    final a = Object(), b = Object();
    configure();
    rime.attach(a, (_) {});
    rime.attach(b, (_) {});
    calls.clear();
    await rime.setActive(a, true);
    expect(calls, isEmpty);
  });

  test('toggleBuiltin clears, deactivates, flips and calls back', () async {
    final a = Object();
    bool? seen;
    configure(onBuiltin: (b) => seen = b);
    rime.attach(a, (_) {});
    await rime.setActive(a, true);
    calls.clear();
    var notified = 0;
    rime.addListener(() => notified++);
    rime.toggleBuiltin();
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['clear', 'active']);
    expect(calls.last.arguments, {'on': false});
    expect(rime.builtin, false);
    expect(seen, false);
    expect(notified, greaterThan(0));
  });

  test('configure turning 「内」 off for an active owner commits the composition as typed, then deactivates', () async {
    // Another session took the stage (its app profile says 「系」): its letters are not lost.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'flush') await push('update', {'commit': 'ni'});
      return null;
    });
    final a = Object();
    final got = <String>[];
    bool? seen;
    configure(onBuiltin: (b) => seen = b);
    rime.attach(a, (u) => got.add(u.commit));
    await rime.setActive(a, true);
    calls.clear();
    configure(builtin: false, onBuiltin: (b) => seen = b);
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['flush', 'active']);
    expect(calls.last.arguments, {'on': false});
    expect(got, ['ni']);
    expect(rime.builtin, false);
    expect(seen, isNull, reason: 'configure is the app telling, not the user choosing');
    calls.clear();
    configure();
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['active']);
    expect(calls.last.arguments, {'on': true});
  });

  test('configure turning 「内」 off with no active owner, or with the switch, sends no flush', () async {
    final a = Object();
    configure();
    configure(builtin: false);
    configure();
    rime.attach(a, (_) {});
    await rime.setActive(a, true);
    calls.clear();
    configure(enabled: false, builtin: false); // the switch: cleared, not committed (native stops the engine)
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['configure', 'active']);
  });

  test('update reaches only the current owner, synchronously', () async {
    final a = Object(), b = Object();
    final gotA = <RimeUpdate>[], gotB = <RimeUpdate>[];
    rime.attach(a, gotA.add);
    rime.attach(b, gotB.add);
    await Future<void>.delayed(Duration.zero); // the handover flush answered
    final done = push('update', {'commit': 'z', 'ascii': true});
    expect(gotB.length, 1); // delivered before any await
    await done;
    expect(gotA, isEmpty);
    expect(gotB.single.commit, 'z');
    expect(rime.ascii, true);
    rime.detach(b);
    await push('update', {'commit': 'q'});
    expect(gotB.length, 1);
  });

  test('attach hands over: the old owner gets its flush\'s commit, then the new owner the rest', () async {
    // Native: a flush pushes its update before it replies.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'flush') await push('update', {'commit': 'ni'});
      return null;
    });
    final a = Object(), b = Object(), c = Object();
    final gotA = <String>[], gotB = <String>[], gotC = <String>[];
    rime.attach(a, (u) => gotA.add(u.commit));
    rime.attach(a, (u) => gotA.add(u.commit)); // the same owner again: no handover
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), isNot(contains('flush')));
    rime.attach(b, (u) => gotB.add(u.commit));
    expect(calls.map((c) => c.method), ['flush']);
    rime.attach(c, (u) => gotC.add(u.commit)); // mid-handover: no second flush, the latest takes over
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['flush']);
    expect(gotA, ['ni']);
    await push('update', {'commit': 'hao'});
    expect(gotB, isEmpty);
    expect(gotC, ['hao']);
  });

  test('a handover with no plugin still hands over', () async {
    plugin = false;
    final a = Object(), b = Object();
    final gotA = <String>[], gotB = <String>[];
    rime.attach(a, (u) => gotA.add(u.commit));
    rime.attach(b, (u) => gotB.add(u.commit));
    await Future<void>.delayed(Duration.zero);
    await push('update', {'commit': 'x'});
    expect(gotA, isEmpty);
    expect(gotB, ['x']);
  });

  test('the new owner detaching mid-handover: nothing gets the later updates', () async {
    final a = Object(), b = Object();
    final gotA = <String>[], gotB = <String>[];
    rime.attach(a, (u) => gotA.add(u.commit));
    rime.attach(b, (u) => gotB.add(u.commit));
    rime.detach(b);
    await Future<void>.delayed(Duration.zero);
    await push('update', {'commit': 'x'});
    expect(gotA, isEmpty);
    expect(gotB, isEmpty);
  });

  test('status messages are parsed and notify', () async {
    var n = 0;
    rime.addListener(() => n++);
    await push('status', {'state': 'error', 'message': 'no default.yaml', 'keyboard': true});
    expect(rime.status.state, RimeState.error);
    expect(rime.status.message, 'no default.yaml');
    expect(n, 1);
  });

  test('flush returns false without a plugin and true with one', () async {
    plugin = false;
    expect(await rime.flush(), false);
    plugin = true;
    expect(await rime.flush(), true);
  });

  testWidgets('a click with Shift or Control held tells the engine, only while active', (tester) async {
    final owner = Object();
    configure();
    rime.attach(owner, (_) {});
    Future<void> click() async {
      tester.binding.handlePointerEvent(const PointerDownEvent(kind: PointerDeviceKind.mouse, position: Offset(5, 5)));
      tester.binding.handlePointerEvent(const PointerUpEvent(kind: PointerDeviceKind.mouse, position: Offset(5, 5)));
      await tester.pump();
    }

    int interrupts() => calls.where((c) => c.method == 'interrupt').length;
    await rime.setActive(owner, true);
    await click();
    expect(interrupts(), 0, reason: 'no modifier held');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click();
    expect(interrupts(), 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await click();
    expect(interrupts(), 2);
    await rime.setActive(owner, false);
    await click();
    expect(interrupts(), 2, reason: 'not active: the engine never saw the modifier');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    debugDefaultTargetPlatformOverride = null;
  });

  test('userFolder falls back on failure', () async {
    plugin = false;
    final f = await rime.userFolder();
    expect(f.path, '');
    expect(f.ready, false);
  });
}
