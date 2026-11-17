import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_ffi.dart';

void main() {
  test('toHubLine drops one trailing newline', () {
    expect(toHubLine('a\n'), 'a');
    expect(toHubLine('a'), 'a');
    expect(toHubLine('a\n\n'), 'a\n');
    expect(toHubLine(''), '');
  });
}
