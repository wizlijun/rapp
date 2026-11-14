// Record ids: 26 chars, time-sortable (ULID alphabet), strictly increasing within this process.
import 'dart:math';

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final _rng = Random.secure();
int _lastMs = -1;
List<int> _lastRand = List.filled(16, 0);

/// A new 26-char id: 10 chars of milliseconds, 16 chars of randomness. Ids taken in
/// the same millisecond (or after the clock stepped back) still increase.
String newRecordId([DateTime? now]) {
  var ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  if (ms > _lastMs) {
    _lastMs = ms;
    // Top digit stays small so a same-millisecond run cannot overflow in practice.
    _lastRand = List.generate(16, (i) => _rng.nextInt(i == 0 ? 16 : 32));
  } else {
    ms = _lastMs;
    var i = 15;
    while (i >= 0 && _lastRand[i] == 31) {
      _lastRand[i] = 0;
      i--;
    }
    if (i >= 0) _lastRand[i]++;
  }
  final t = List.filled(10, '');
  var n = ms;
  for (var k = 9; k >= 0; k--, n ~/= 32) {
    t[k] = _alphabet[n % 32];
  }
  return t.join() + _lastRand.map((d) => _alphabet[d]).join();
}

/// `2026-11-14T21:37:05+09:00`: local time, second precision, with the zone offset.
String isoWithOffset(DateTime t) {
  final l = t.toLocal();
  String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  final off = l.timeZoneOffset;
  final a = off.abs();
  return '${p(l.year, 4)}-${p(l.month)}-${p(l.day)}T${p(l.hour)}:${p(l.minute)}:${p(l.second)}'
      '${off.isNegative ? '-' : '+'}${p(a.inHours)}:${p(a.inMinutes % 60)}';
}
