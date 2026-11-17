// BackgroundWatch: the iPad app going to the background and coming back (iPad spec §9), the screen kept awake
// while a session is live (§9.5) and the memory warning.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ios_channel.dart';
import 'package:rapp/ui/background.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

class _State extends MainState {
  _State(Directory tmp) : super(hub: null, data: DataDir(tmp.path), prefs: UiPrefs());

  final calls = <String>[];
  bool live = false;
  Future<void> Function()? begun, ended;

  @override
  bool get stageLive => live;

  @override
  Future<void> enterBackground({Future<void> Function()? begin, Future<void> Function()? end}) async {
    calls.add('background');
    begun = begin;
    ended = end;
  }

  @override
  Future<void> enterForeground({Duration stagger = const Duration(milliseconds: 300)}) async =>
      calls.add('foreground');

  @override
  void memoryWarning() => calls.add('memory');

  @override
  void netChanged() => calls.add('net');
}

class _Ios extends IosChannel {
  final sent = <String>[];
  final events$ = StreamController<String>.broadcast();

  @override
  Future<void> keepAwake(bool on) async => sent.add('keepAwake $on');
  @override
  Future<void> sessionActive(bool on) async => sent.add('sessionActive $on');
  @override
  Future<void> beginBackground() async => sent.add('begin');
  @override
  Future<void> endBackground() async => sent.add('end');
  @override
  Stream<String> get events => events$.stream;
}

void main() {
  late Directory tmp;
  late _State s;
  late _Ios ios;
  late BackgroundWatch w;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rapp_bg');
    s = _State(tmp);
    ios = _Ios();
  });
  tearDown(() {
    w.dispose();
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('inactive then resumed is not the background', (tester) async {
    w = BackgroundWatch(state: s, ios: ios);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(s.calls, isEmpty);
  });

  testWidgets('hidden is the background once; shown again is the foreground', (tester) async {
    w = BackgroundWatch(state: s, ios: ios);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(s.calls, ['background']);
    await s.begun!();
    await s.ended!();
    expect(ios.sent, containsAllInOrder(['begin', 'end']), reason: 'the background time of IosPlugin');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(s.calls, ['background', 'foreground']);
  });

  test('the screen stays awake while a session is live, and only the changes are sent', () {
    w = BackgroundWatch(state: s, ios: ios, listen: ({required onHide, required onShow}) => null);
    expect(ios.sent, ['keepAwake false', 'sessionActive false']);
    ios.sent.clear();
    s.notifyListeners();
    expect(ios.sent, isEmpty);
    s.live = true;
    s.notifyListeners();
    expect(ios.sent, ['keepAwake true', 'sessionActive true']);
    ios.sent.clear();
    s.prefs.keepAwake = false;
    s.notifyListeners();
    expect(ios.sent, ['keepAwake false'], reason: '常亮 off in 本机; the edge gestures stay held');
    ios.sent.clear();
    s.live = false;
    s.notifyListeners();
    expect(ios.sent, ['sessionActive false']);
  });

  test('a memory warning and a network change go to the state', () async {
    w = BackgroundWatch(state: s, ios: ios, listen: ({required onHide, required onShow}) => null);
    ios.events$.add('pathChanged');
    ios.events$.add('memoryWarning');
    ios.events$.add('somethingElse');
    await Future<void>.delayed(Duration.zero);
    expect(s.calls, ['net', 'memory']);
  });
}
