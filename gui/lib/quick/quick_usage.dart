// How often each 快捷区 item was used: ref (`p:<id>` / `k:<id>`) -> local date `yyyy-mm-dd` -> count (spec §5).
// Pure functions; only the last 30 days are kept (today plus the 29 days before).

typedef Usage = Map<String, Map<String, int>>;

const usageDays = 30;

/// `yyyy-mm-dd` of a local time.
String usageDay(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';

String _oldest(DateTime now) => usageDay(DateTime(now.year, now.month, now.day - (usageDays - 1)));

/// A new table with one more use of [ref] today; days older than 30 are dropped.
Usage recordUsage(Usage u, String ref, DateTime now) {
  final out = pruneUsage(u, now);
  final days = out.putIfAbsent(ref, () => <String, int>{});
  final d = usageDay(now);
  days[d] = (days[d] ?? 0) + 1;
  return out;
}

/// A new table without days before the 30-day window; refs left with no days are dropped.
Usage pruneUsage(Usage u, DateTime now) {
  final oldest = _oldest(now);
  final out = <String, Map<String, int>>{};
  u.forEach((ref, days) {
    final kept = {
      for (final e in days.entries)
        if (e.key.compareTo(oldest) >= 0) e.key: e.value,
    };
    if (kept.isNotEmpty) out[ref] = kept;
  });
  return out;
}

final _dayRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

bool _validDay(String s) {
  final m = _dayRe.firstMatch(s);
  if (m == null) return false;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final t = DateTime(y, mo, d);
  return t.year == y && t.month == mo && t.day == d;
}

/// Malformed entries (non-map, non-int counts, bad dates) are dropped, never thrown.
Usage usageFromJson(Object? j) {
  final out = <String, Map<String, int>>{};
  if (j is! Map) return out;
  j.forEach((ref, days) {
    if (ref is! String || days is! Map) return;
    final kept = <String, int>{};
    days.forEach((d, n) {
      if (d is String && n is int && n > 0 && _validDay(d)) kept[d] = n;
    });
    if (kept.isNotEmpty) out[ref] = kept;
  });
  return out;
}

/// Total uses per ref over the last 30 days, summed across [all] (one table per device).
Map<String, int> usageTotals(Iterable<Usage> all, DateTime now) {
  final oldest = _oldest(now);
  final out = <String, int>{};
  for (final u in all) {
    u.forEach((ref, days) {
      days.forEach((d, n) {
        if (d.compareTo(oldest) >= 0) out[ref] = (out[ref] ?? 0) + n;
      });
    });
  }
  return out;
}
