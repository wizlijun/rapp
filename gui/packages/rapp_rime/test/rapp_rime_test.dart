import 'package:flutter/foundation.dart';
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

  test('update reaches only the current owner, synchronously', () async {
    final a = Object(), b = Object();
    final gotA = <RimeUpdate>[], gotB = <RimeUpdate>[];
    rime.attach(a, gotA.add);
    rime.attach(b, gotB.add);
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

  test('userFolder falls back on failure', () async {
    plugin = false;
    final f = await rime.userFolder();
    expect(f.path, '');
    expect(f.ready, false);
  });
}
