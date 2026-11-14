import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/session_model.dart';

void main() {
  test('routeWord marks only a forced relay', () {
    expect(routeWord('relay', forced: true), '中继（强制）');
    expect(routeWord('relay'), '中继');
    expect(routeWord('lan', forced: true), '局域网');
    expect(routeWord('direct'), '直连');
    expect(routeWord(null), '');
    expect(routeWord(null, forced: true), '');
    expect(routeWord('weird'), '');
  });
}
