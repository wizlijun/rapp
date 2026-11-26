import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/load_model.dart';

const gb = 1000000000;

/// The service's example snapshot (`rules.rs` `snapshot_shape`), as the first line of a watch: with `history`.
Map<String, dynamic> example() => {
      'at': 1764100000, 'headroom': 30, 'tightest': 'disk', 'term': true,
      'items': {
        'cpu': {'pct': 42.0, 'cores': 8, 'load1': 3.5},
        'mem': {'total': 16 * gb, 'avail': 8 * gb, 'swap_used': gb, 'pressure': 'normal'},
        'heat': {'level': 'normal'},
      },
      'disks': [
        {
          'mount': '/', 'total': 100 * gb, 'avail': 6 * gb, 'inode_free_pct': 31.0, 'level': 'warn',
          'paths': [
            {'kind': 'home', 'path': '/Users/x'},
            {'kind': 'term', 'path': '/Users/x/git/rapp', 'term': 't1'},
          ],
        },
        {
          'mount': '/Volumes/nas', 'unreadable': true,
          'paths': [
            {'kind': 'data', 'path': '/Volumes/nas/d'},
          ],
        },
      ],
      'warnings': [
        {'item': 'disk:/', 'level': 'warn', 'text': '磁盘只剩 6.0 GB（/，剩 6%，含 ~/git/rapp）'},
      ],
      'history': [
        {'at': 1764099995, 'cpu': 40.0, 'mem': 0.5, 'heat': 0, 'disk': 0.06},
        {'at': 1764100000, 'cpu': 42.0, 'mem': 0.5, 'heat': 0, 'disk': 0.06},
      ],
    };

/// A device's load as `rapp load pick` sees it (Task 6 `dev`).
DeviceLoad dev(int headroom, double? cpu, {bool term = true, List<Map<String, dynamic>> warns = const []}) =>
    DeviceLoad.fromJson({
      'at': 1, 'headroom': headroom, 'tightest': 'mem', 'term': term,
      'items': {
        'cpu': ?(cpu == null ? null : {'pct': cpu, 'cores': 8}),
        'mem': {'total': 16 * gb, 'avail': 8 * gb},
        'heat': {'level': 'normal'},
      },
      'disks': [
        {'mount': '/', 'total': 100 * gb, 'avail': 30 * gb},
      ],
      'warnings': warns,
    });

void main() {
  test('fromJson reads the example snapshot', () {
    final l = DeviceLoad.fromJson(example());
    expect((l.at, l.headroom, l.tightest, l.term), (1764100000, 30, 'disk', true));
    expect(l.items['cpu'], {'pct': 42.0, 'cores': 8, 'load1': 3.5});
    expect(l.disks.map((d) => d['mount']), ['/', '/Volumes/nas']);
    expect(l.disks[1]['unreadable'], isTrue);
    final w = l.warnings.single;
    expect((w.item, w.level, w.text, w.etaMin), ('disk:/', LoadLevel.warn, '磁盘只剩 6.0 GB（/，剩 6%，含 ~/git/rapp）', null));
    expect(l.history.map((p) => p.at), [1764099995, 1764100000]);
    final p = l.history.last;
    expect((p.cpu, p.gpu, p.mem, p.disk, p.heat), (42.0, null, 0.5, 0.06, 0));
  });

  test('fromJson takes whatever is missing as absent, and a stream line without history as its one point', () {
    final l = DeviceLoad.fromJson({'at': 5, 'term': false, 'point': {'at': 5, 'cpu': 1}});
    expect((l.headroom, l.tightest), (null, null));
    expect(l.items, isEmpty);
    expect(l.disks, isEmpty);
    expect(l.warnings, isEmpty);
    expect(l.history.single.cpu, 1.0);
    expect(l.level, LoadLevel.normal);
  });

  test('next takes the new snapshot, appends its point and keeps 720', () {
    var l = DeviceLoad.fromJson(example());
    final line = {...example()..remove('history'), 'at': 1764100005, 'headroom': 29, 'point': {'at': 1764100005, 'cpu': 50.0}};
    l = l.next(line);
    expect((l.at, l.headroom), (1764100005, 29));
    expect(l.history.length, 3);
    expect(l.history.last.cpu, 50.0);
    for (var i = 0; i < 800; i++) {
      l = l.next({...line, 'at': 1764100010 + i, 'point': {'at': 1764100010 + i}});
    }
    expect(l.history.length, 720);
    expect(l.history.last.at, 1764100809);
    expect(l.history.first.at, 1764100809 - 719);
  });

  test('level is the highest warning level', () {
    DeviceLoad with_(List<String> levels) => DeviceLoad.fromJson({
          ...example(),
          'warnings': [for (final v in levels) {'item': 'cpu', 'level': v, 'text': 'x'}],
        });
    expect(with_([]).level, LoadLevel.normal);
    expect(with_(['warn']).level, LoadLevel.warn);
    expect(with_(['warn', 'danger', 'warn']).level, LoadLevel.danger);
  });

  test('tightestWord names the tightest item and its value', () {
    expect(tightestWord(DeviceLoad.fromJson(example())), '磁盘 剩 6%');
    expect(tightestWord(DeviceLoad.fromJson({...example(), 'tightest': 'cpu'})), 'CPU 42%');
    expect(tightestWord(DeviceLoad.fromJson({
      ...example(),
      'tightest': 'mem',
      'items': {'mem': {'total': 16 * gb, 'avail': 4 * gb}},
    })), '内存 剩 25%');
    expect(tightestWord(DeviceLoad.fromJson({
      ...example(),
      'tightest': 'heat',
      'items': {'heat': {'level': 'hot'}},
    })), '热度 偏热');
    final none = Map.of(example())..remove('tightest')..remove('headroom');
    expect(tightestWord(DeviceLoad.fromJson(none)), '—');
  });

  group('pickDevice (Task 6 pick)', () {
    test('skips danger and term:false', () {
      final loads = {
        'a': dev(90, 10, warns: [{'item': 'disk:/', 'level': 'danger', 'text': '磁盘快满了'}]),
        'b': dev(85, 10, term: false),
        'd': dev(40, 10, warns: [{'item': 'cpu', 'level': 'warn', 'text': 'x'}]),
      };
      expect(pickDevice(loads, {'a', 'b', 'c', 'd'}), 'd');
    });

    test('a tie goes to the lower cpu, then the earlier; a missing cpu counts as full', () {
      expect(pickDevice({'a': dev(60, 50), 'b': dev(60, 20), 'c': dev(60, 20)}, {'a', 'b', 'c'}), 'b');
      expect(pickDevice({'n': dev(60, null), 'b': dev(60, 99)}, {'n', 'b'}), 'b');
    });

    test('offline devices do not count; none fits is null', () {
      expect(pickDevice({'a': dev(90, 10), 'b': dev(50, 10)}, {'b'}), 'b');
      expect(pickDevice({'a': dev(90, 10)}, {}), isNull);
      expect(pickDevice({}, {'a'}), isNull);
      expect(pickDevice({'a': dev(50, 1, term: false)}, {'a'}), isNull);
    });
  });
}
