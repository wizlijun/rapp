import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/term_id.dart';

void main() {
  test('cleanTermName mirrors clean_name', () {
    expect(cleanTermName(' a '), 'a');
    expect(cleanTermName(''), isNull);
    expect(cleanTermName('   '), isNull);
    expect(cleanTermName('x' * 64), 'x' * 64);
    expect(cleanTermName('x' * 65), isNull);
    expect(cleanTermName('a\nb'), isNull);
    expect(cleanTermName('a\u0007'), isNull);
    expect(cleanTermName('a\u007fb'), isNull);
    // Counted in characters (code points), as Rust chars().count().
    expect(cleanTermName('😀' * 64), '😀' * 64);
    expect(cleanTermName('😀' * 65), isNull);
    expect(cleanTermName('终端'), '终端');
  });
}
