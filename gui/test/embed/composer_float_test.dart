import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/composer_float.dart';

void main() {
  const stage = Size(800, 600), panel = Size(720, 70);

  test('default: bottom centre, 8 up', () {
    expect(composerTopLeft(defaultComposerAt, stage, panel), const Offset(40, 522));
  });

  test('clamped to 8 from every edge', () {
    expect(composerTopLeft(const InputPoint(1, 0, fromBottom: true), stage, panel), const Offset(72, 522));
    expect(composerTopLeft(const InputPoint(0.5, 0), stage, panel), const Offset(40, 8));
    expect(composerTopLeft(const InputPoint(0, 300), stage, const Size(400, 70)), const Offset(8, 230));
  });

  test('resize clamps without rewriting', () {
    const at = InputPoint(0.9, 8, fromBottom: true);
    // centre 666 → left 306, clamped to 740 − 8 − 720 = 12; bottom 292 → top 222
    expect(composerTopLeft(at, const Size(740, 300), panel), const Offset(12, 222));
    // the same point on the big stage: centre 720 → left 520, clamped to 800 − 8 − 400 = 392
    expect(composerTopLeft(at, stage, const Size(400, 70)), const Offset(392, 522));
  });

  test('a panel taller than the stage keeps its top on stage', () {
    expect(composerTopLeft(defaultComposerAt, const Size(800, 60), panel).dy, 8);
  });
}
