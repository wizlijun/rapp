import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

/// A monitor whose terminal list is set by hand and whose terminal calls are recorded.
class _Mon extends ServiceMonitor {
  _Mon() : super(readToken: () async => null);
  final opens = <Map<String, String?>>[];
  final fronts = <String>[];
  Future<String> Function()? onOpen;
  Object? frontError;

  @override
  Future<String> termOpen({String? shell, required String app, String? from}) {
    opens.add({'shell': shell, 'app': app, 'from': from});
    return onOpen?.call() ?? Future.value('term:pty:n');
  }

  @override
  Future<void> termFront(String term) async {
    fronts.add(term);
    final e = frontError;
    if (e != null) throw e;
  }
}

TermRow _row(String id, {String? host, bool dead = false, bool unread = false, TermPs? ps, int attached = 0}) =>
    TermRow(id, id.substring(9), 'zsh', host, 1, attached, 1, dead, unread, ps: ps);

const _consent = 'macOS 弹出了授权框「“rApp”想要控制“终端”」：点「允许」（可能连着两个），点完再试一次';

void main() {
  late Directory tmp;
  late _Mon mon;
  late MainState s;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('local_terms_state_test');
    mon = _Mon()
      ..localTerms = const TermList('local', hosts: [
        TermHost(null, launchers: ['Terminal', 'iTerm']),
      ]);
    s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), monitor: mon);
  });

  tearDown(() {
    s.dispose();
    mon.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('the local column opens for a running rapp terminal', () {
    expect(s.localColumnOpen(inbound: false), isFalse);
    expect(s.localColumnOpen(inbound: false, terms: true), isTrue);
    s.openLocalColumn(false);
    expect(s.localColumnOpen(inbound: true, terms: true), isFalse);
  });

  test('newLocalTerm opens in the Terminal app with from last and opens no in-app view', () async {
    final before = s.current;
    await s.newLocalTerm();
    expect(mon.opens, [
      {'shell': null, 'app': 'Terminal', 'from': 'last'},
    ]);
    expect(s.current, before);
    expect(s.newLocalTermBusy, isFalse);
  });

  test('newLocalTerm uses the terminal app picked for this machine', () async {
    s.prefs.termApp['local'] = 'iTerm';
    await s.newLocalTerm();
    expect(mon.opens.single['app'], 'iTerm');
  });

  test('newLocalTerm with no terminal app says so and asks nothing', () async {
    mon.localTerms = const TermList('local');
    await s.newLocalTerm();
    expect(mon.opens, isEmpty);
    expect(s.hint, '这台设备没有可用的终端窗口');
  });

  test('a second 新建 while the first waits opens nothing more', () async {
    final gate = Completer<String>();
    mon.onOpen = () => gate.future;
    final first = s.newLocalTerm();
    await Future<void>.delayed(Duration.zero);
    expect(s.newLocalTermBusy, isTrue);
    await s.newLocalTerm();
    expect(mon.opens, hasLength(1));
    gate.complete('term:pty:n');
    await first;
    expect(s.newLocalTermBusy, isFalse);
  });

  test('a failed 新建 says the service words on the hint', () async {
    mon.onOpen = () => Future.error(ServiceException('terminal sessions are off'));
    await s.newLocalTerm();
    expect(s.hint, 'terminal sessions are off');
    expect(s.newLocalTermBusy, isFalse);
  });

  test('frontLocalTerm that finds no window says so', () async {
    mon.frontError = ServiceException(termFrontNotFound);
    await s.frontLocalTerm('term:pty:a');
    expect(mon.fronts, ['term:pty:a']);
    expect(s.hint, '没找到这个终端的窗口');
  });

  test('macOS asking shows the local consent words', () async {
    mon.frontError = ServiceException(termFrontConsent);
    await s.frontLocalTerm('term:pty:a');
    expect(s.hint, _consent);
    mon.onOpen = () => Future.error(ServiceException('macOS is asking whether rApp may control Terminal'));
    await s.newLocalTerm();
    expect(s.hint, _consent);
    expect(MainState.consentError(ServiceException(termFrontConsent)), isTrue);
    expect(MainState.consentError(ServiceException('macOS is asking whether rApp may control Terminal')), isTrue);
    expect(MainState.consentError(ServiceException('not-found')), isFalse);
  });

  test('macOS refused rApp control of Terminal: says where to turn it on', () async {
    mon.frontError = ServiceException(termFrontDenied);
    await s.frontLocalTerm('term:pty:a');
    expect(s.hint, '没有控制「终端」的权限：到「系统设置 › 隐私与安全性 › 自动化」里，打开 rApp 下面的「终端」');
  });

  test('Terminal not answering on this Mac is said in Chinese, about this Mac', () async {
    mon.onOpen = () => Future.error(
        ServiceException('Terminal did not answer: on that Mac, allow rApp to control Terminal and System Events'));
    await s.newLocalTerm();
    expect(s.hint, '「终端」没有回应：看看是否弹出了授权框「“rApp”想要控制“终端”」，点「允许」后再新建');
  });

  test('localTermLamp ignores unread', () {
    expect(MainState.localTermLamp(_row('term:pty:a', unread: true)), Lamp.active);
    expect(MainState.localTermLamp(_row('term:pty:a', ps: const TermPs('blocked'))), Lamp.waiting);
    expect(MainState.localTermLamp(_row('term:pty:a', ps: const TermPs('working'))), Lamp.active);
    expect(MainState.localTermLamp(_row('term:pty:a', ps: const TermPs('error'))), Lamp.idle);
    expect(MainState.localTermLamp(_row('term:pty:a', ps: const TermPs('done'))), Lamp.idle);
    expect(MainState.localTermLamp(_row('term:pty:a', dead: true, ps: const TermPs('working'))), Lamp.disconnected);
  });

  test('localTermRows drops rows from other hosts', () {
    expect(MainState.localTermRows(null), isEmpty);
    final l = TermList('local', terms: [_row('term:pty:a'), _row('term:pty@srv:b', host: 'srv'), _row('term:pty:c')]);
    expect(MainState.localTermRows(l).map((r) => r.id), ['term:pty:a', 'term:pty:c']);
  });
}
