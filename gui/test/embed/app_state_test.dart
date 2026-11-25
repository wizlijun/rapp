import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_state.dart';

void main() {
  test('parse', () {
    final a = AppState.parse('{"state":"blocked","kind":"permission","by":["ask"],"sure":true,"health":"ok",'
        '"pack":"claude-desktop","rev":1,"variants":[],"counts":{"rowDot":1},"inferred":true}')!;
    expect(a.ps!.state, 'blocked');
    expect(a.ps!.kind, 'permission');
    expect(a.sure, isTrue);
    expect(a.by, ['ask']);
    expect(a.counts, {'rowDot': 1});
    expect(a.pack, 'claude-desktop');
    expect(a.rev, 1);
    expect(a.stale, isFalse);
    expect(AppState.parse('{"state":"sleeping"}')!.state, isNull);
    expect(AppState.parse('{"state":"sleeping"}')!.ps, isNull);
    expect(AppState.parse('nope'), isNull);
    expect(AppState.parse('[]'), isNull);
    expect(AppState.parse('{"health":"unfit"}')!.stale, isTrue);
    expect(AppState.parse('{"health":"switched"}')!.stale, isTrue);
    expect(AppState.parse('{"health":"invalid","error":"x"}')!.stale, isTrue);
    expect(AppState.parse('{"health":"weird"}')!.health, 'ok');
    expect(AppState.parse('{}')!.health, 'ok');
  });

  test('wrong-typed fields and oversized reports never throw', () {
    final a = AppState.parse('{"state":3,"by":"x","counts":{"a":"b","c":2},"variants":[1,"v"],"sure":"yes","rev":"1"}')!;
    expect(a.state, isNull);
    expect(a.by, isEmpty);
    expect(a.counts, {'c': 2});
    expect(a.variants, ['v']);
    expect(a.sure, isFalse);
    expect(a.rev, isNull);
    expect(AppState.parse('{"x":"${'a' * 5000}"}'), isNull);
  });
}
