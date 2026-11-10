import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/cm_page.dart';

void main() {
  test('quits 5 s after the last session ends', () {
    fakeAsync((async) {
      var quits = 0;
      final q = CmAutoQuit(onQuit: () => quits++);
      q.update(2);
      async.elapse(const Duration(seconds: 10));
      expect(quits, 0);
      q.update(0);
      async.elapse(const Duration(milliseconds: 4900));
      expect(quits, 0);
      async.elapse(const Duration(milliseconds: 200));
      expect(quits, 1);
      q.dispose();
    });
  });

  test('a new session within 5 s cancels the quit', () {
    fakeAsync((async) {
      var quits = 0;
      final q = CmAutoQuit(onQuit: () => quits++);
      q.update(1);
      q.update(0);
      async.elapse(const Duration(seconds: 3));
      q.update(1);
      async.elapse(const Duration(seconds: 10));
      expect(quits, 0);
      q.update(0);
      async.elapse(const Duration(seconds: 3));
      q.update(0); // repeated zero must not restart the countdown
      async.elapse(const Duration(seconds: 2, milliseconds: 100));
      expect(quits, 1);
      q.dispose();
    });
  });

  test('starting with zero sessions also quits after 5 s', () {
    fakeAsync((async) {
      var quits = 0;
      final q = CmAutoQuit(onQuit: () => quits++);
      q.update(0);
      async.elapse(const Duration(seconds: 5, milliseconds: 1));
      expect(quits, 1);
      q.dispose();
    });
  });

  test('no status at all (service unreachable) never quits by itself', () {
    fakeAsync((async) {
      var quits = 0;
      final q = CmAutoQuit(onQuit: () => quits++);
      async.elapse(const Duration(minutes: 1));
      expect(quits, 0);
      q.dispose();
    });
  });

  test('dispose cancels a pending quit', () {
    fakeAsync((async) {
      var quits = 0;
      final q = CmAutoQuit(onQuit: () => quits++);
      q.update(0);
      q.dispose();
      async.elapse(const Duration(seconds: 10));
      expect(quits, 0);
    });
  });
}
