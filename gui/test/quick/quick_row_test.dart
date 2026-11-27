import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/quick/quick_row.dart';

void main() {
  test('no stars: by count, ties by menu order, phrases before keys', () {
    expect(
        quickRowOrder(phraseRefs: ['p:a', 'p:b'], keyRefs: ['k:x', 'k:y'], stars: [], totals: {'k:y': 3, 'p:b': 1}),
        ['k:y', 'p:b', 'p:a', 'k:x']);
  });
  test('stars: only the starred, in star order; dangling stars ignored', () {
    expect(
        quickRowOrder(phraseRefs: ['p:a', 'p:b'], keyRefs: ['k:x'], stars: ['k:x', 'p:gone', 'p:a'], totals: {'p:b': 9}),
        ['k:x', 'p:a']);
    expect(quickRowOrder(phraseRefs: ['p:a'], keyRefs: [], stars: ['p:gone'], totals: {}), ['p:a']);
  });
}
