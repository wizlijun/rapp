import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  Map<String, dynamic> row(String name) => {'id': 'term:pty:$name', 'name': name, 'command': 'zsh', 'activity': 1};

  Future<void> listed(List<String> names) async {
    t.emit({
      'event': 'terms',
      'id': '111',
      'path': 'lan',
      'terms': [for (final n in names) row(n)],
      'hosts': [
        {'host': null, 'launchers': ['Terminal']},
      ],
    });
    await pump();
  }

  Future<void> show(String name) async {
    await s.openOrSwitch('111', 'term:pty:$name', name);
    await pump();
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('new_term_from_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await pump();
    t.onSend = (m) {
      final req = m['req'];
      switch (m['cmd']) {
        case 'open':
          t.emit({'event': 'opened', 'req': req, 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan'});
        case 'open_term':
          t.emit({'event': 'term_created', 'req': req, 'id': '111', 'term': 'term:pty:n'});
        case 'terms':
          t.emit({
            'event': 'terms',
            'req': req,
            'id': '111',
            'terms': [row('n')],
            'hosts': [
              {'host': null, 'launchers': ['Terminal']},
            ],
          });
      }
    };
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('new_term_uses_current_stage_term', () async {
    await listed(['a', 'b']);
    await show('a');
    await show('b');
    expect(s.newTermSource('111'), 'term:pty:b');
    // 新建 itself sends it.
    await s.openText('111', from: s.newTermSource('111'));
    expect(t.sent.firstWhere((m) => m['cmd'] == 'open_term')['from'], 'term:pty:b');
  });

  test('new_term_uses_last_viewed_when_stage_elsewhere', () async {
    await listed(['a', 'b']);
    await show('a');
    s.overview = true;
    s.currentKey = null;
    s.notifyListeners();
    expect(s.newTermSource('111'), 'term:pty:a');
    s.currentKey = '222/other:app';
    s.notifyListeners();
    expect(s.newTermSource('111'), 'term:pty:a');
  });

  test('new_term_last_viewed_gone_sends_last', () async {
    await listed(['a', 'b']);
    await show('a');
    await listed(['b']);
    expect(s.newTermSource('111'), 'last');
    expect(s.newTermSource('222'), 'last');
  });
}
