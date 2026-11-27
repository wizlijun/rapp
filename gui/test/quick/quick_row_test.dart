import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/quick/quick_row.dart';

void main() {
  test('no stars: by count, ties in list order, commands and phrases alike', () {
    expect(quickRowOrder(refs: ['p:new', 'p:a', 'p:b', 'p:search'], stars: [], totals: {'p:search': 3, 'p:b': 1}),
        ['p:search', 'p:b', 'p:new', 'p:a']);
  });
  test('stars: only the starred, in star order; dangling stars ignored', () {
    expect(quickRowOrder(refs: ['p:a', 'p:b', 'p:x'], stars: ['p:x', 'p:gone', 'p:a'], totals: {'p:b': 9}),
        ['p:x', 'p:a']);
    expect(quickRowOrder(refs: ['p:a'], stars: ['p:gone'], totals: {}), ['p:a']);
  });
}
