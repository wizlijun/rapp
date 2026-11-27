import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/form.dart' show phoneFormSettle;
import 'package:rapp/phone/home_screen.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/phone_shell.dart';
import 'package:rapp/phone/session_view.dart';
import 'package:rapp/phone/sheet.dart';
import 'package:rapp/phone/widgets.dart';
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
  // Measured in the simulator (V1a probe), not invented. Task 12 adds the real-device fold sequence and the settle check.
  // Duo 外屏、内屏：Task 12 补
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

  /// 2 waiting (one with an empty msg), 1 done, 3 working, one device offline.
  Future<void> boot(WidgetTester tester, Size size, RappTheme theme, {double scale = 1}) async {
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
    s = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), stateSync: FakeStateSync(tmp.path), port: FakeSessionPort(), unlockStore: UnlockStore(supported: false, memory: false), termPort: FakeTermSessionPort());
    nav = PhoneNav(s);
    booted = true;
    t.emit({'event': 'presence', 'id': 'm2', 'online': true});
    t.emit({
      'event': 'terms',
      'id': 'm1',
      'path': 'lan',
      'terms': [
        term('a', 'blocked', kind: 'permission', msg: '可以删掉吗？'),
        term('b', 'blocked', kind: 'permission'),
        term('c', 'done', msg: '做完了', unread: true),
        term('w1', 'working'),
        term('w2', 'working'),
        term('w3', 'working'),
      ],
      'hosts': [],
    });
    await tester.runAsync(() async {
      s.openOrSwitch('m1', 'term:pty:a', 'a');
      for (var i = 0; i < 6; i++) {
        await flush();
      }
      t.emit({'event': 'presence', 'id': 'm2', 'online': false});
      await flush();
    });
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
  List<_Tap> tappables(WidgetTester tester, Finder root) {
    bool isTap(Widget w) =>
        (w is InkWell && w.onTap != null) || (w is GestureDetector && w.onTap != null) || (w is PhoneButton && w.onPressed != null);
    final found = <Element>[];
    for (final e in find.descendant(of: root, matching: find.byWidgetPredicate(isTap)).evaluate()) {
      final box = e.renderObject;
      if (box is RenderBox && box.hasSize && box.attached) found.add(e);
    }
    final out = <_Tap>[];
    for (final e in found) {
      var nested = false;
      e.visitAncestorElements((a) {
        if (identical(a, root.evaluate().first)) return false;
        if (isTap(a.widget)) nested = true;
        return !nested;
      });
      if (nested) continue;
      final box = e.renderObject! as RenderBox;
      out.add(_Tap(e, box.localToGlobal(Offset.zero) & box.size, e.widget is PhoneButton && (e.widget as PhoneButton).primary));
    }
    return out;
  }

  void checkTaps(WidgetTester tester, Finder root, String where) {
    final taps = tappables(tester, root);
    expect(taps, isNotEmpty, reason: '$where: nothing to tap found');
    for (final a in taps) {
      expect(a.rect.height, greaterThanOrEqualTo(a.primary ? phonePrimaryTap : phoneTap), reason: '$where: tap height ${a.element.widget.runtimeType} at ${a.rect} ${_chain(a.element)}');
    }
    // Two tappables that overlap horizontally and sit one above the other need 12 between them.
    for (final a in taps) {
      for (final b in taps) {
        if (identical(a, b)) continue;
        final overlap = math.min(a.rect.right, b.rect.right) - math.max(a.rect.left, b.rect.left);
        if (overlap <= 0 || a.rect.bottom > b.rect.top + 0.01) continue;
        expect(b.rect.top - a.rect.bottom, greaterThanOrEqualTo(12), reason: '$where: gap ${a.rect} -> ${b.rect}');
      }
    }
  }

  void checkContrast(RappTokens k, String where) {
    final bgs = {'bg': k.bg, 'panel': _over(k.panel[0], k.bg), 'tint': _over(k.tint, k.bg)};
    for (final e in bgs.entries) {
      for (final f in {'text': k.text, 'muted': k.muted}.entries) {
        expect(_contrast(_over(f.value, e.value), e.value), greaterThanOrEqualTo(4.5), reason: '$where: ${f.key} on ${e.key}');
      }
    }
    // The primary button: bg ink on a text-coloured fill.
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
      if (scale == 1) checkTaps(tester, find.byType(PhoneShell), '$where ${v.name}');
    }

    // 会话里面
    nav.enter(s.entries.first.key);
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '$where session');
    expect(find.byType(PhoneSessionView), findsOneWidget, reason: where);
    if (scale == 1) checkTaps(tester, find.byType(PhoneShell), '$where session');
  }

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
    testWidgets('T12 text x2 at 375x667 ${th.name}', (tester) => phoneRun(tester, const Size(375, 667), th, scale: 2));
  }
}
