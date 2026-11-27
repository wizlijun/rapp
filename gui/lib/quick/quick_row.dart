// The order of the 快捷区 first row (spec §5, §9). Pure; whether an item is usable in this session is filtered by the caller.

/// With at least one star pointing at an existing item: the starred ones in star order (dangling stars and repeats ignored).
/// Otherwise every item by use count descending, ties in [refs] order (the 常用语 doc's, commands and phrases alike).
List<String> quickRowOrder({
  required List<String> refs,
  required List<String> stars,
  required Map<String, int> totals,
}) {
  final all = refs;
  final exist = all.toSet();
  final starred = {
    for (final s in stars)
      if (exist.contains(s)) s,
  }.toList();
  if (starred.isNotEmpty) return starred;
  final idx = {for (var i = 0; i < all.length; i++) all[i]: i};
  final sorted = {...all}.toList()
    ..sort((a, b) {
      final c = (totals[b] ?? 0).compareTo(totals[a] ?? 0);
      return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
    });
  return sorted;
}
