import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/state/state_link.dart';
import 'package:rapp/state/state_sync.dart';

class RowsLink extends StateLink {
  RowsLink(super.base);
  final seenCalls = <Map<String, Object?>>[];
  final watchCtl = StreamController<Map<String, Object?>>();
  @override
  Future<bool> health() async => true;
  @override
  Future<Map<String, Object?>> state() async => {
        'devices': [
          {
            'fp': 'FA',
            'id': '111111111',
            'sessions': [
              {'session': 's1', 'state': 'waiting', 'seq': 1, 'since': 1, 'at': 1},
              {'session': 's2', 'state': 'working', 'seq': 2, 'since': 2, 'at': 2},
            ],
          },
          {
            'fp': 'FB',
            'id': '222222222',
            'sessions': [
              {'session': 's3', 'state': 'done', 'seq': 3, 'since': 3, 'at': 3},
              {'session': 's4', 'state': 'error', 'seq': 4, 'since': 4, 'at': 4},
            ],
          },
          {
            'fp': 'FC',
            'sessions': [
              {'session': 's5'},
            ],
          },
        ],
        'needs': [],
      };
  @override
  Future<Map<String, Object?>> queue({String? before, int limit = 50}) async => {'events': [], 'more': false};
  @override
  Future<void> seen({String? fp, String? session, String? eid, bool handled = false}) async {
    seenCalls.add({'fp': fp, 'session': session, 'eid': eid, 'handled': handled});
  }

  @override
  Stream<Map<String, Object?>> watch() => watchCtl.stream;
}

void main() {
  late Directory dir;
  late List<RowsLink> links;
  final realPrint = debugPrint;
  setUp(() {
    debugPrint = (String? m, {int? wrapWidth}) {};
    dir = Directory.systemTemp.createTempSync('state_sync_rows');
    links = [];
  });
  tearDown(() {
    debugPrint = realPrint;
    dir.deleteSync(recursive: true);
  });

  StateSync make() => StateSync(
        localDir: dir.path,
        find: () async => 'http://h:1',
        link: (u) => RowsLink(u)..also(links.add),
      );

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('sessionRows gives every session with its device id, skipping devices without id', () async {
    final sync = make()..start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    final rows = sync.sessionRows.toList();
    expect(rows.map((r) => (r.$1, r.$2['session'])), [
      ('111111111', 's1'),
      ('111111111', 's2'),
      ('222222222', 's3'),
      ('222222222', 's4'),
    ]);
    expect(rows.first.$2['state'], 'waiting');
    sync.dispose();
  });

  test('markHandled sends seen with handled, and does nothing when not connected', () async {
    final sync = make();
    await sync.markHandled('fp:e1:3');
    final s2 = make()..start();
    await settle();
    links.single.watchCtl.add({'what': 'hello'});
    await settle();
    await s2.markHandled('fp:e1:3');
    expect(links.single.seenCalls, [
      {'fp': null, 'session': null, 'eid': 'fp:e1:3', 'handled': true},
    ]);
    s2.pause();
    await settle();
    await s2.markHandled('fp:e1:4');
    expect(links.single.seenCalls.length, 1);
    s2.dispose();
    sync.dispose();
  });
}

extension<T> on T {
  void also(void Function(T) f) => f(this);
}
