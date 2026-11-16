import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/stream_choice.dart';

void main() {
  test('effectiveFps', () {
    const c = StreamChoice('color16', 'adaptive', 30);
    expect(effectiveFps(c, onStage: true, detached: false), 30);
    expect(effectiveFps(c, onStage: false, detached: false), 1);
    expect(effectiveFps(c, onStage: false, detached: true), 30);
  });

  test('presetSmart matches startChoice but is not equal to it', () {
    expect(presetSmart.mode, startChoice.mode);
    expect(presetSmart.density, startChoice.density);
    expect(presetSmart.fps, startChoice.fps);
    expect(presetSmart.smart, isTrue);
    expect(presetSmart == startChoice, isFalse);
    expect(presetSmart.hashCode == startChoice.hashCode, isFalse);
    expect(presetSmart.toString(), isNot(startChoice.toString()));
  });

  test('copyWith leaves smart mode', () {
    expect(presetSmart.copyWith(fps: 15).smart, isFalse);
    expect(presetSmart.copyWith(fps: 15), startChoice);
  });
}
