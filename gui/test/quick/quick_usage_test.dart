import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/quick/quick_usage.dart';

void main() {
  final now = DateTime(2026, 11, 27, 10);
  test('usage keeps 30 days', () {
    var u = recordUsage({}, 'p:a', now);
    u = recordUsage(u, 'p:a', now);
    expect(u, {'p:a': {'2026-11-27': 2}});
    final old = {'p:a': {'2026-10-27': 5, '2026-10-29': 1}};
    expect(pruneUsage(old, now), {'p:a': {'2026-10-29': 1}});
    expect(
        usageTotals([old, {'p:a': {'2026-11-27': 2}, 'k:x': {'2026-11-26': 1}}], now),
        {'p:a': 3, 'k:x': 1});
  });
  test('recordUsage drops old days', () {
    final u = recordUsage({'p:a': {'2026-10-01': 4}}, 'p:b', now);
    expect(u, {'p:b': {'2026-11-27': 1}});
  });
  test('usageFromJson drops bad entries', () {
    expect(usageFromJson(null), isEmpty);
    expect(usageFromJson('x'), isEmpty);
    expect(
        usageFromJson({
          'p:a': {'2026-11-27': 2, 'bad': 1, '2026-11-26': 'x', '2026-11-25': 1.5},
          'p:b': 'nope',
          3: {'2026-11-27': 1},
          'p:c': {'2026-13-40': 1},
        }),
        {'p:a': {'2026-11-27': 2}});
  });
}
