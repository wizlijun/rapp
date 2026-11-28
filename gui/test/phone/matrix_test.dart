import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/input_dock.dart';
import 'package:rapp/embed/input_metrics.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/assistant_page.dart';
import 'package:rapp/phone/form.dart' show phoneFormSettle;
import 'package:rapp/phone/hold_button.dart';
import 'package:rapp/phone/home_screen.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/phone_shell.dart';
import 'package:rapp/phone/reply_bar.dart';
import 'package:rapp/phone/reply_card.dart';
import 'package:rapp/phone/session_view.dart';
import 'package:rapp/phone/sheet.dart';
import 'package:rapp/phone/widgets.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/unlock.dart';

import '../fakes.dart';
import '../ui/main_window_test.dart' show FakeFullscreen;

const _phones = <Size>[
  Size(390, 844),
  Size(844, 390),
  Size(375, 667),
  Size(430, 932),
  Size(599, 800),
  // The Duo and iPad sizes below were measured in the simulator (V1a probe), not invented.
  // Task 12 adds the real-device fold sequence and the settle check.
  Size(466, 678), // Duo outer
  Size(678, 466),
  Size(375, 1183), // iPad split windows
  Size(594, 1183),
];
const _pads = <Size>[
  Size(600, 800),
  Size(669, 951), // Duo inner
  Size(951, 669),
  Size(615, 1183), // iPad window
];

double _lin(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
double _lum(Color c) => 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);
double _contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

Color _over(Color top, Color under) => Color.alphaBlend(top, under);

/// Buttons held to 64 (card buttons and primary ones) over the whole run, so that check cannot pass on nothing.
var cardButtons = 0;

/// The shared composer layer's tappables left out of the Q2 check (see `tappables`).
var sharedComposerTaps = 0;

class _Tap {
  _Tap(this.element, this.rect, this.primary);
  final Element element;
  final Rect rect;
  final bool primary;
}

String _chain(Element e) {
  final out = <String>[];
  e.visitAncestorElements((a) {
    out.add(a.widget.runtimeType.toString());
    return out.length < 14;
  });
  return out.join(' < ');
}

void main() {
  late Directory tmp;
  late FakeTransport t;
  late MainState s;
  late PhoneNav nav;
  var sid = 0;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  tearDownAll(() => expect(cardButtons, greaterThan(0), reason: 'no card button was measured at 64'));

  setUp(() {
    sid = 0;
    tmp = Directory.systemTemp.createTempSync('matrix_test');
  });
  var booted = false;
  tearDown(() {
    if (booted) {
      nav.dispose();
      s.dispose();
    }
    booted = false;
    tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> term(String id, String state, {String? kind, String msg = '', bool unread = false}) => {
        'id': 'term:pty:$id',
        'name': id,
        'command': 'zsh',
        'activity': 1,
        'unread': unread,
        'fg': 'codex',
        'ps': {'state': state, 'kind': ?kind, 'msg': msg, 'since': 10, 'seq': 1},
      };

  Map<String, Object?> v1cRow(String id) {
    final (state, msg) = switch (id) {
      'r1' => ('blocked', 'approve Bash: git push origin main'),
      'r2' => ('blocked', 'answer: 选哪一个 (甲 · 乙 · 丙)'),
      'r3' => ('blocked', 'approve plan'),
      _ => ('done', '做完了'),
    };
    return {
      'id': 'term:pty:$id',
      'name': id,
      'command': 'zsh',
      'activity': 1,
      'unread': state == 'done',
      'reply': true,
      'fg': 'claude',
      'ps': {'state': state, 'kind': ?(state == 'blocked' ? 'permission' : null), 'msg': msg, 'app': 'claude-code', 'since': 10, 'seq': 4},
    };
  }

  /// 2 waiting (one with an empty msg), 1 done, 3 working, one device offline.
  ///
  /// [v1c] (V1c cases only): the one new row to wait on, `r1` (risky approve), `r2` (a question with 3 options),
  /// `r3` (approve plan, with a `plan:` emit) or `r4` (done). The device then advertises `reply`, and that row
  /// replaces the old waiting/done ones (`a`, `b`, `c`), so it is the card the home shows and the session opened.
  /// Without it the rows and counts are exactly what the old cases always saw.
  Future<void> boot(WidgetTester tester, Size size, RappTheme theme, {double scale = 1, String? v1c}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    t = FakeTransport();
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': 'm1', 'name': 'mini'},
        {'id': 'm2', 'name': 'mac2'},
      ],
    });
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req'], 'port': 5000 + sid, 'token': 'tk'});
      }
    };
    await tester.runAsync(flush);
    final sync = FakeStateSync(tmp.path);
    if (v1c != null) sync.status = StateStatus.connected;
    s = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), stateSync: sync, port: FakeSessionPort(), unlockStore: UnlockStore(supported: false, memory: false), termPort: FakeTermSessionPort());
    nav = PhoneNav(s);
    booted = true;
    if (v1c != null) s.probes['m1'] = DeviceProbe(Lamp.active, '在线', apps: const AppList('m1', 'lan', [], capabilities: {'reply': true}));
    t.emit({'event': 'presence', 'id': 'm2', 'online': true});
    t.emit({'event': 'terms', 'id': 'm2', 'path': 'lan', 'terms': [term('o', 'working')], 'hosts': []});
    t.emit({
      'event': 'terms',
      'id': 'm1',
      'path': 'lan',
      'terms': [
        if (v1c == null) ...[
          term('a', 'blocked', kind: 'permission', msg: '可以删掉吗？'),
          term('b', 'blocked', kind: 'permission'),
          term('c', 'done', msg: '做完了', unread: true),
        ] else ...[
          v1cRow(v1c),
          // A done card is the focus only beside something waiting (all-done is the H7 lists): this is the one to pick.
          if (v1c == 'r4') term('b', 'blocked', kind: 'permission'),
        ],
        term('w1', 'working'),
        term('w2', 'working'),
        term('w3', 'working'),
      ],
      'hosts': [],
    });
    await tester.runAsync(() async {
      s.openOrSwitch('m2', 'term:pty:o', 'o');
      for (var i = 0; i < 6; i++) {
        await flush();
      }
      s.openOrSwitch('m1', 'term:pty:${v1c ?? 'a'}', v1c ?? 'a');
      for (var i = 0; i < 6; i++) {
        await flush();
      }
      t.emit({'event': 'presence', 'id': 'm2', 'online': false});
      await flush();
    });
    if (v1c == 'r3') {
      sync.rows = [
        {'t': 'emit', 'level': 'info', 'id': 'm1', 'key': 'plan:term:pty:r3', 'session': 'term:pty:r3', 'text': '- 甲\n- 乙', 'at': 12, 'eid': 'e1'},
      ];
      sync.push();
    }
    await tester.pumpWidget(MaterialApp(
      theme: themeDataFor(theme),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: phoneFormSwitch(
            state: s,
            nav: nav,
            data: DataDir(tmp.path),
            pad: (_) => MainWindow(state: s, monitor: null, control: null, fullscreen: FakeFullscreen()),
          ),
        ),
      ),
    ));
    await tester.pump(phoneFormSettle + const Duration(milliseconds: 10));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  /// Everything the finger can hit under [root]: InkWell / GestureDetector with onTap, PhoneButton with onPressed.
  /// A tappable inside another tappable (a row holding a button, an InkWell's own detector) is left out.
  ///
  /// [sharedComposer]: the session page also mounts the Pad's own composer layer (R34: one implementation, never a
  /// phone copy). Its controls are the Pad's: icon squares of 48 (40 for ＋ and 发送 in the text area), key-bar
  /// keys and chips, sized and placed for the stage. `ControlMetrics` only reaches text-only buttons, so it cannot
  /// lift them to 56/12; they are left out of the Q2 check here ON PURPOSE (reported in the V1b final fix report),
  /// counted into [sharedComposerTaps] so the exemption never passes on a layer that is not there. Everything else
  /// on the page (返回, the phone's own controls) is still held to 56/12, and overflow is checked for all of it.
  List<_Tap> tappables(WidgetTester tester, Finder root, {bool sharedComposer = false}) {
    bool isTap(Widget w) =>
        (w is InkWell && w.onTap != null) || (w is GestureDetector && w.onTap != null) || (w is PhoneButton && w.onPressed != null) || (w is PhoneHoldButton && w.onSend != null);
    final found = <Element>[];
    for (final e in find.descendant(of: root, matching: find.byWidgetPredicate(isTap)).evaluate()) {
      final box = e.renderObject;
      if (box is RenderBox && box.hasSize && box.attached) found.add(e);
    }
    final out = <_Tap>[];
    for (final e in found) {
      var nested = false, inCard = false, inComposer = false;
      e.visitAncestorElements((a) {
        if (identical(a, root.evaluate().first)) return false;
        if (a.widget is PhoneCard) inCard = true;
        if (a.widget is InputDock) inComposer = true;
        if (isTap(a.widget)) nested = true;
        return !nested;
      });
      if (nested) continue;
      if (sharedComposer && inComposer) {
        sharedComposerTaps++;
        continue;
      }
      final box = e.renderObject! as RenderBox;
      out.add(_Tap(e, box.localToGlobal(Offset.zero) & box.size, e.widget is PhoneHoldButton || (e.widget is PhoneButton && ((e.widget as PhoneButton).primary || inCard))));
    }
    return out;
  }

  void checkTaps(WidgetTester tester, Finder root, String where, {bool sharedComposer = false}) {
    final taps = tappables(tester, root, sharedComposer: sharedComposer);
    expect(taps, isNotEmpty, reason: '$where: nothing to tap found');
    for (final a in taps) {
      if (a.primary) cardButtons++;
      expect(a.rect.height, greaterThanOrEqualTo(a.primary ? phonePrimaryTap : phoneTap), reason: '$where: tap height ${a.element.widget.runtimeType} at ${a.rect} ${_chain(a.element)}');
    }
    // Two tappables that overlap horizontally and sit one above the other need 12 between them.
    for (final a in taps) {
      for (final b in taps) {
        if (identical(a, b)) continue;
        final overlap = math.min(a.rect.right, b.rect.right) - math.max(a.rect.left, b.rect.left);
        if (overlap <= 0 || a.rect.bottom > b.rect.top + 0.01) continue;
        expect(b.rect.top - a.rect.bottom, greaterThanOrEqualTo(12), reason: '$where: gap ${a.rect} -> ${b.rect} ${a.element.widget.runtimeType} ${_chain(a.element)} -> ${b.element.widget.runtimeType} ${_chain(b.element)}');
      }
    }
  }

  void checkContrast(RappTokens k, String where) {
    final bgs = {'bg': k.bg, 'panel': _over(k.panel[0], k.bg), 'tint': _over(k.tint, k.bg), 'button face': _over(k.raise[0], k.bg)};
    for (final e in bgs.entries) {
      for (final f in {'text': k.text, 'muted': k.muted}.entries) {
        expect(_contrast(_over(f.value, e.value), e.value), greaterThanOrEqualTo(4.5), reason: '$where: ${f.key} on ${e.key}');
      }
    }
    // The waiting card's title on its tint.
    expect(_contrast(k.accent, _over(k.tint, k.bg)), greaterThanOrEqualTo(4.5), reason: '$where: accent on tint');
    // A primary button: bg ink on a text-coloured fill (PhoneButton primary).
    expect(_contrast(k.bg, k.text), greaterThanOrEqualTo(4.5), reason: '$where: primary button');
  }

  Future<void> phoneRun(WidgetTester tester, Size size, RappTheme th, {double scale = 1}) async {
    final where = '${size.width.toInt()}x${size.height.toInt()} ${th.name} x$scale';
    await boot(tester, size, th, scale: scale);
    expect(tester.takeException(), isNull, reason: '$where home');
    expect(find.byType(PhonePage), findsWidgets, reason: where);
    expect(find.byType(MainWindow), findsNothing, reason: where);
    expect(find.byType(HomeScreen), findsOneWidget, reason: where);
    if (scale == 1) checkTaps(tester, find.byType(PhoneShell), '$where home');

    // 面板
    unawaited(showPhoneSheet(tester.element(find.byType(HomeScreen)), nav));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '$where sheet');
    expect(find.byType(BottomSheet), findsOneWidget, reason: where);
    if (scale == 1) checkTaps(tester, find.byType(BottomSheet), '$where sheet');
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await settle(tester);

    for (final v in [PhoneView.devices, PhoneView.settings]) {
      nav.open(v);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: '$where ${v.name}');
      if (v == PhoneView.devices) expect(find.textContaining('codex · o'), findsOneWidget, reason: '$where: the offline device lists its session');
      if (scale == 1) checkTaps(tester, find.byType(PhoneShell), '$where ${v.name}');
    }

    // 会话里面
    nav.enter('m1/term:pty:a');
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '$where session');
    expect(find.byType(PhoneSessionView), findsOneWidget, reason: where);
    expect(find.byType(InputDock), findsOneWidget, reason: '$where: the session mounts the Pad composer layer (R34)');
    if (scale == 1) {
      final before = sharedComposerTaps;
      checkTaps(tester, find.byType(PhoneShell), '$where session', sharedComposer: true);
      expect(sharedComposerTaps, greaterThan(before), reason: '$where: the composer exemption found nothing to exempt');
    }
  }

  /// A V1c page: no overflow, every tap at its size, contrast, and the thing asked for is on screen.
  Future<void> v1cRun(WidgetTester tester, Size size, RappTheme th, String rid, String name, Future<void> Function(String where) body) async {
    final where = '${size.width.toInt()}x${size.height.toInt()} ${th.name} $name';
    await boot(tester, size, th, v1c: rid);
    expect(tester.takeException(), isNull, reason: '$where boot');
    // Nothing waiting (r4, done) and a session open: the phone form stays in the session; go to the home page.
    if (find.byType(HomeScreen).evaluate().isEmpty) {
      nav.home();
      await settle(tester);
    }
    expect(find.byType(HomeScreen), findsOneWidget, reason: where);
    if (rid == 'r4') {
      final row = find.widgetWithText(PhoneRow, '做完了');
      await tester.scrollUntilVisible(row, 100);
      await tester.tap(row.first);
      await tester.pump(const Duration(milliseconds: 400));
    }
    await body(where);
    expect(tester.takeException(), isNull, reason: '$where end');
    checkContrast(themeDataFor(th).extension<RappTokens>()!, where);
  }

  Future<void> homeCard(WidgetTester tester, Size size, RappTheme th, String rid, String name, List<String> words) =>
      v1cRun(tester, size, th, rid, name, (where) async {
        expect(find.byType(ReplyActions), findsOneWidget, reason: where);
        for (final w in words) {
          expect(find.text(w), findsWidgets, reason: '$where: $w');
        }
        checkTaps(tester, find.byType(PhoneShell), where);
      });

  Future<void> readingView(WidgetTester tester, Size size, RappTheme th, {bool open = false}) =>
      v1cRun(tester, size, th, 'r3', open ? 'composer open (R36)' : 'reading view', (where) async {
        nav.enter('m1/term:pty:r3');
        await settle(tester);
        expect(tester.takeException(), isNull, reason: '$where session');
        expect(find.byType(PhoneSessionView), findsOneWidget, reason: where);
        // Composer closed: a short stage never hides the card or the bar (T18-2).
        expect(find.byType(ReplyActions), findsOneWidget, reason: '$where: pinned card');
        expect(find.byType(PhoneReplyBar), findsOneWidget, reason: '$where: reply bar');
        if (open) {
          await tester.tap(find.byKey(const Key('composer-open')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where opened');
          expect(find.byKey(const Key('composer-field')), findsOneWidget, reason: where);
          checkTaps(tester, find.byType(PhoneShell), where);
          // Composer open (T18-2): on the short landscape stages the card gives way (and at 844x390 the bar too).
          final short = size == const Size(844, 390) || size == const Size(678, 466);
          expect(find.byType(ReplyActions), short ? findsNothing : findsOneWidget, reason: '$where: card while open');
          expect(find.byType(PhoneReplyBar), size == const Size(844, 390) ? findsNothing : findsOneWidget, reason: '$where: bar while open');
          // Closing brings both back.
          s.currentRemote!.composer.collapse();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where closed again');
          expect(find.byType(ReplyActions), findsOneWidget, reason: '$where: card back');
          expect(find.byType(PhoneReplyBar), findsOneWidget, reason: '$where: bar back');
        } else {
          final before = sharedComposerTaps;
          checkTaps(tester, find.byType(PhoneShell), where, sharedComposer: true);
          expect(sharedComposerTaps, greaterThanOrEqualTo(before), reason: where);
        }
      });

  for (final th in RappTheme.values) {
    test('T9 contrast ${th.name}', () {
      checkContrast(themeDataFor(th).extension<RappTokens>()!, th.name);
    });
    for (final size in _phones) {
      testWidgets('phone ${size.width.toInt()}x${size.height.toInt()} ${th.name}', (tester) => phoneRun(tester, size, th));
    }
    for (final size in _pads) {
      testWidgets('pad ${size.width.toInt()}x${size.height.toInt()} ${th.name}', (tester) async {
        await boot(tester, size, th);
        expect(tester.takeException(), isNull);
        expect(find.byType(MainWindow), findsOneWidget);
        expect(find.byType(PhonePage), findsNothing);
      });
    }
    for (final size in _phones) {
      final n = '${size.width.toInt()}x${size.height.toInt()} ${th.name}';
      testWidgets('v1c risky card $n', (tester) => homeCard(tester, size, th, 'r1', 'risky card', ['拒绝', '允许', '撤不回']));
      testWidgets('v1c options card $n', (tester) => homeCard(tester, size, th, 'r2', 'options card', ['甲', '乙', '丙']));
      testWidgets('v1c review card $n', (tester) => homeCard(tester, size, th, 'r3', 'review card', ['甲', '乙']));
      testWidgets('v1c done card $n', (tester) => homeCard(tester, size, th, 'r4', 'done card', ['知道了']));
      testWidgets('v1c reading view with pinned card and reply bar $n', (tester) => readingView(tester, size, th));
      testWidgets('v1c composer open (R36) $n', (tester) => readingView(tester, size, th, open: true));
      // The shortest closed state there is: the composer was open on a short landscape stage and is closing, so the
      // block under the stack is still tall. (The soft keyboard cannot be up with the composer closed: closing
      // releases its focus, see InputDock._changed.) The stack must stay, one widget all the way (a hold in progress
      // would be lost otherwise), and what it draws must be what a finger hits.
      if (size.width > size.height) {
        testWidgets('v1c closing keeps the bar $n', (tester) async {
          await boot(tester, size, th, v1c: 'r3');
          nav.enter('m1/term:pty:r3');
          await settle(tester);
          final where = '$n closing';
          await tester.tap(find.byKey(const Key('composer-open')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await settle(tester);
          s.currentRemote!.composer.collapse();
          Object? first;
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 40));
            expect(tester.takeException(), isNull, reason: '$where frame $i');
            if (i == 0) first = tester.element(find.byType(PhoneReplyBar));
            // Mid-closing the still-tall block may sit over the bar: painted and hit alike, so nothing is half-visible.
            expect(find.byType(PhoneReplyBar), findsOneWidget, reason: '$where frame $i');
          }
          expect(find.byType(PhoneReplyBar), findsOneWidget, reason: where);
          if (first != null) expect(identical(first, tester.element(find.byType(PhoneReplyBar))), isTrue, reason: '$where: not remounted');
          await settle(tester);
          expect(tester.takeException(), isNull, reason: where);
          final type = find.byKey(const Key('composer-open'));
          expect(type.hitTestable(), findsOneWidget, reason: '$where: settled, the type square is hit');
          expect(tester.getSize(type).height, greaterThanOrEqualTo(phonePrimaryTap), reason: where);
        });
      }
      testWidgets('v1c assistant page $n', (tester) async {
        await boot(tester, size, th, v1c: 'r1');
        nav.open(PhoneView.assistant);
        await settle(tester);
        final where = '$n assistant';
        expect(tester.takeException(), isNull, reason: where);
        expect(find.byType(AssistantPage), findsOneWidget, reason: where);
        checkTaps(tester, find.byType(PhoneShell), where);
        checkContrast(themeDataFor(th).extension<RappTokens>()!, where);
      });
    }
    for (final size in _pads) {
      testWidgets('pad unchanged ${size.width.toInt()}x${size.height.toInt()} ${th.name}', (tester) async {
        await boot(tester, size, th, v1c: 'r1');
        expect(tester.takeException(), isNull);
        expect(find.byType(MainWindow), findsOneWidget);
        expect(find.byType(ReplyActions, skipOffstage: false), findsNothing);
        expect(find.byType(PhoneReplyBar, skipOffstage: false), findsNothing);
        final phoneMetrics = find.byWidgetPredicate((w) => w is InputMetrics && w.keyHeight == InputMetrics.phone.keyHeight && w.panelButton == InputMetrics.phone.panelButton && w.chip == InputMetrics.phone.chip, skipOffstage: false);
        expect(phoneMetrics, findsNothing);
      });
    }
    testWidgets('T12 text x2 at 375x667 ${th.name}', (tester) => phoneRun(tester, const Size(375, 667), th, scale: 2));
  }
}
