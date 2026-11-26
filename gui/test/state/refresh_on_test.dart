import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/state/refresh_on.dart';
import 'package:rapp/state/state_sync.dart';

import '../fakes.dart';

class _Src extends ChangeNotifier {
  bool running = false;
  List<int> maps = const [];
  void ping() => notifyListeners();
}

class _Sync extends FakeStateSync {
  _Sync(super.localDir);
  int refreshed = 0;
  @override
  Future<void> refresh() async => refreshed++;
}

void main() {
  late Directory dir;
  late _Sync sync;
  late _Src src;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('refresh_on');
    sync = _Sync(dir.path)..status = StateStatus.none;
    src = _Src();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('false to true while none refreshes once; staying true does not', () {
    refreshStateOn(src, () => src.running, sync);
    src.ping();
    expect(sync.refreshed, 0);
    src.running = true;
    src.ping();
    expect(sync.refreshed, 1);
    src.ping();
    expect(sync.refreshed, 1);
    src.running = false;
    src.ping();
    expect(sync.refreshed, 1);
  });

  test('a transition while connected does not refresh', () {
    sync.status = StateStatus.connected;
    refreshStateOn(src, () => src.running, sync);
    src.running = true;
    src.ping();
    expect(sync.refreshed, 0);
  });

  test('a new list refreshes, the same list does not', () {
    refreshStateOn(src, () => src.maps, sync);
    src.ping();
    expect(sync.refreshed, 0);
    src.maps = [1];
    src.ping();
    src.ping();
    expect(sync.refreshed, 1);
  });
}
