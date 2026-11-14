import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/history/record_id.dart';

void main() {
  test('ids sort by time and never repeat within one millisecond', () {
    final now = DateTime.utc(2026, 11, 14, 12);
    final ids = [for (var i = 0; i < 1000; i++) newRecordId(now)];
    expect(ids.toSet().length, 1000);
    expect(ids.every((s) => s.length == 26), isTrue);
    for (var i = 1; i < ids.length; i++) {
      expect(ids[i].compareTo(ids[i - 1]), greaterThan(0));
    }
    expect(newRecordId(now.add(const Duration(milliseconds: 1))).compareTo(ids.last), greaterThan(0));
  });

  test('isoWithOffset carries the zone', () {
    final t = DateTime(2026, 11, 14, 21, 37, 5);
    final s = isoWithOffset(t);
    expect(s, matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$')));
    final m = RegExp(r'([+-])(\d\d):(\d\d)$').firstMatch(s)!;
    final mins = (int.parse(m[2]!) * 60 + int.parse(m[3]!)) * (m[1] == '-' ? -1 : 1);
    expect(mins, t.timeZoneOffset.inMinutes);
    expect(s.startsWith('2026-11-14T21:37:05'), isTrue);
  });
}
