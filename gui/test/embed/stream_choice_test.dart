import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/stream_choice.dart';

void main() {
  test('effectiveFps', () {
    const c = StreamChoice('color16', 'adaptive', 30);
    expect(effectiveFps(c, onStage: true, detached: false), 30);
    expect(effectiveFps(c, onStage: false, detached: false), 1);
    expect(effectiveFps(c, onStage: false, detached: true), 30);
  });
}
