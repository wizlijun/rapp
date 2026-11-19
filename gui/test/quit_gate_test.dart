import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/quit_gate.dart';

void main() {
  test('a second confirmation while one is up answers false and never shows', () async {
    final gate = OneAtATime();
    final first = Completer<bool>();
    var shown = 0;
    final a = gate.ask(() {
      shown++;
      return first.future;
    });
    expect(await gate.ask(() async {
      shown++;
      return true;
    }), isFalse);
    expect(shown, 1);
    first.complete(true);
    expect(await a, isTrue);
    // Once the first is answered, the next one shows again.
    expect(await gate.ask(() async => true), isTrue);
  });

  test('a confirmation that throws frees the gate', () async {
    final gate = OneAtATime();
    await expectLater(gate.ask(() async => throw StateError('x')), throwsStateError);
    expect(await gate.ask(() async => true), isTrue);
  });
}
