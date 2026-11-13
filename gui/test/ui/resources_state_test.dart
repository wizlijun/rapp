import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/ui/pin_files.dart';
import 'package:rapp/ui/resources_state.dart';

ResourcesState make() => ResourcesState(clock: () => DateTime(2026, 11, 12, 9, 5));

ClipRow row(int id) => ClipRow(id, 't$id', true, ClipKind.text);

TransferProgressEvent ev(Object sid, int id, TransferState s, {int done = 0, int total = 20, String? path}) =>
    TransferProgressEvent(sid, id, true, 'f$id', done, total, s, path, null);

void main() {
  test('entries carry kind, title, source and time', () {
    final s = make();
    s.addClips('111/calc', 1, 'Calculator @ mini', [const ClipRow(1, '文字 · hi', true, ClipKind.text)]);
    expect(s.clips.length, 1);
    final e = s.clips.single;
    expect(e.source, 'Calculator @ mini');
    expect(hhmm(e.at), '09:05');
    expect(e.kind, ClipKind.text);
    expect(e.title, '文字 · hi');
    expect(s.entry(e.seq), same(e));
    expect(s.clipsOf('111/calc').length, 1);
    expect(s.clipsOf('other'), isEmpty);
  });

  test('a resent table adds only unseen clips, newest on top', () {
    final s = make();
    s.addClips('k', 1, 'A', [row(2), row(1)]);
    s.addClips('k', 1, 'A', [row(3), row(2), row(1)]);
    expect(s.clips.map((e) => e.clip), [3, 2, 1]);
    final t = make();
    t.addClips('k1', 1, 'A', [row(1)]);
    t.addClips('k2', 2, 'B', [row(1)]);
    t.addClips('k1', 1, 'A', [row(2), row(1)]);
    expect(t.clips.map((e) => e.source), ['A', 'B', 'A']);
    expect(t.clips.map((e) => e.clip), [2, 1, 1]);
  });

  test('evicted clips do not come back', () {
    final s = make();
    for (var n = 1; n <= 101; n++) {
      s.addClips('k', 1, 'A', [for (var i = n; i >= 1; i--) row(i)]);
    }
    expect(s.clips.length, 100);
    expect(s.clips.any((e) => e.clip == 1), isFalse);
    s.addClips('k', 1, 'A', [for (var i = 101; i >= 1; i--) row(i)]);
    expect(s.clips.length, 100);
    expect(s.clips.any((e) => e.clip == 1), isFalse);
  });

  test('pinned entries do not count and are not evicted', () {
    final s = make();
    s.addClips('k', 1, 'A', [row(1)]);
    final first = s.clips.single.seq;
    s.beginPin(first);
    s.pinned(first, 7);
    s.addClips('k', 1, 'A', [for (var i = 101; i >= 1; i--) row(i)]);
    expect(s.clips.length, 101);
    expect(s.entry(first)!.pinned, isTrue);
    expect(s.entry(first)!.copy, 7);
  });

  test('unpin keeps a live entry and removes an ended one', () {
    final s = make();
    s.addClips('k', 1, 'A', [row(2), row(1)]);
    final a = s.clips[0].seq, b = s.clips[1].seq;
    for (final q in [a, b]) {
      s.beginPin(q);
      s.pinned(q, q + 10);
    }
    expect(s.unpin(a, sessionEnded: false), a + 10);
    expect(s.entry(a), isNotNull);
    expect(s.entry(a)!.pinned, isFalse);
    expect(s.unpin(b, sessionEnded: true), b + 10);
    expect(s.entry(b), isNull);

    final t = make();
    t.addClips('k', 1, 'A', [row(1)]);
    final old = t.clips.single.seq;
    t.beginPin(old);
    t.pinned(old, 5);
    t.addClips('k', 1, 'A', [for (var i = 101; i >= 2; i--) row(i)]);
    expect(t.clips.length, 101);
    t.unpin(old, sessionEnded: false);
    expect(t.clips.length, 100);
    expect(t.entry(old), isNull);
  });

  test('pinFailed leaves the entry unpinned', () {
    final s = make();
    s.addClips('k', 1, 'A', [row(1)]);
    final q = s.clips.single.seq;
    s.beginPin(q);
    expect(s.entry(q)!.pinning, isTrue);
    s.pinFailed(q);
    expect(s.entry(q)!.pinned, isFalse);
    expect(s.entry(q)!.pinning, isFalse);
  });

  test('transfer rows move from running to ended', () {
    final s = make();
    s.transfer('k', 1, 'A', ev(1, 1, TransferState.running));
    expect(s.running.length, 1);
    expect(s.ended, isEmpty);
    s.transfer('k', 1, 'A', ev(1, 1, TransferState.done, done: 20, path: '/x/f1'));
    expect(s.running, isEmpty);
    expect(s.ended.single.path, '/x/f1');
    expect(s.ended.single.endedAt, isNotNull);
    s.transfer('k', 1, 'A', ev(1, 1, TransferState.running));
    expect(s.running, isEmpty);
    expect(s.ended.length, 1);
  });

  test('ended keeps fifty', () {
    final s = make();
    for (var i = 1; i <= 51; i++) {
      s.transfer('k', 1, 'A', ev(1, i, TransferState.done, done: 20));
    }
    expect(s.ended.length, 50);
    expect(s.ended.first.id, 51);
    expect(s.ended.any((r) => r.id == 1), isFalse);
  });

  test('sessionEnded drops unpinned, keeps pinned and cancels transfers', () {
    final s = make();
    s.addClips('k', 1, 'A', [row(2), row(1)]);
    final pinnedSeq = s.clips[1].seq;
    s.beginPin(pinnedSeq);
    s.pinned(pinnedSeq, 3);
    s.transfer('k', 1, 'A', ev(1, 3, TransferState.running));
    final r = s.sessionEnded('k', {1});
    expect(r, [(1, 3)]);
    expect(s.clips.length, 1);
    expect(s.clips.single.seq, pinnedSeq);
    expect(s.clips.single.ended, isTrue);
    expect(s.running, isEmpty);
    expect(s.ended.single.state, TransferState.cancelled);
    s.transfer('k', 1, 'A', ev(1, 3, TransferState.running));
    expect(s.running, isEmpty);
    // _seen cleared: the same clip number from a new session with the same sid is new again
    s.addClips('k', 1, 'A', [row(2)]);
    expect(s.clips.length, 2);
  });

  test('linkDown fails the running rows of that sid only', () {
    final s = make();
    s.transfer('k', 1, 'A', ev(1, 1, TransferState.running));
    s.transfer('k', 2, 'B', ev(2, 1, TransferState.running));
    s.linkDown(1);
    expect(s.running.single.sid, 2);
    expect(s.ended.single.sid, 1);
    expect(s.ended.single.state, TransferState.failed);
    expect(s.ended.single.error, '没传完');
  });

  test('sizeText and hhmm', () {
    expect(sizeText(512), '512 B');
    expect(sizeText(340 * 1024), '340 KB');
    expect(sizeText((2.3 * 1024 * 1024).round()), '2.3 MB');
    expect(sizeText(3 * 1024 * 1024 * 1024), '3.0 GB');
    expect(hhmm(DateTime(2026, 1, 1, 7, 3)), '07:03');
    expect(kindWord(ClipKind.text), '文字');
    expect(kindWord(ClipKind.image), '图片');
    expect(kindWord(ClipKind.files), '文件');
    expect(kindWord(ClipKind.data), '数据');
    expect(kindWord(ClipKind.unsupported), '其他');
  });

  test('restored entries are pinned, ended, oldest, and never evicted', () {
    final s = make();
    s.addClips('k', 1, 'A', [row(1)]);
    s.addRestored(path: '/r/a.md', copy: 7, kind: ClipKind.text, title: 'a', at: DateTime(2026, 11, 1));
    s.addRestored(path: '/r/b.md', copy: 8, kind: ClipKind.image, title: 'b', at: DateTime(2026, 11, 2));
    expect(s.clips.map((e) => e.title), ['t1', 'a', 'b']);
    final e = s.clips[1];
    expect(e.pinned, true);
    expect(e.ended, true);
    expect(e.copy, 7);
    expect(e.path, '/r/a.md');
    expect(e.source, restoredSource);
    expect(e.key, '');
    expect(e.at, DateTime(2026, 11, 1));
    for (var i = 2; i < 2 + maxUnpinned + 5; i++) {
      s.addClips('k', 1, 'A', [row(i)]);
    }
    expect(s.clips.where((e) => e.path != null).length, 2);
    expect(s.clips.where((e) => !e.pinned).length, maxUnpinned);
    expect(s.unpin(e.seq, sessionEnded: e.ended), 7);
    expect(s.entry(e.seq), isNull);
  });
}
