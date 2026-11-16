import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_editor.dart';
import 'package:rapp/embed/composer_model.dart';
import 'package:rapp/embed/session_port.dart';

import '../fakes.dart';

/// A take that waits until [gate] completes (an input method still composing).
class _SlowTakeEditor extends FakeEditor {
  Completer<void>? gate;

  @override
  Future<String> take() async {
    final g = gate = Completer<void>();
    await g.future;
    return super.take();
  }
}

class _CountingEditor extends FakeEditor {
  int reads = 0;

  @override
  Future<String> read() {
    reads++;
    return super.read();
  }
}

class _SlowReadEditor extends FakeEditor {
  final gate = Completer<String>();
  @override
  Future<String> read() => gate.future;
}

void main() {
  late ComposerModel m;
  late FakeEditor ed;
  late List<int> dropped;
  late DateTime now;
  late int allSent;

  setUp(() {
    dropped = [];
    allSent = 0;
    now = DateTime(2026, 1, 1);
    m = ComposerModel(onDrop: dropped.add, onAllSent: () => allSent++, clock: () => now);
    ed = FakeEditor();
    m.attach(ed);
  });

  tearDown(() => m.dispose());

  test('reopening waits for the previous native draft read before initializing the editor', () async {
    final old = _SlowReadEditor();
    await m.attach(old);
    final detached = m.detach(old);
    final next = FakeEditor();
    final attached = m.attach(next);
    old.gate.complete('刚完成的组字');
    await detached;
    await attached;
    expect(m.draft, '刚完成的组字');
    expect(next.value, '刚完成的组字');
  });

  test('submit takes the text with its blocks where they stand; the editor is empty', () async {
    m.apply(const PasteResult(blocks: [BlockChip(1, '图片 #1')]));
    ed.value += 'hi';
    final s = await m.submit() as SubmitPieces;
    expect(s.pieces, [
      {'block': 1},
      {'text': 'hi'},
    ]);
    expect(ed.value, '');
    expect(m.blocks, isEmpty);
    expect(m.inFlight!.text, 'hi');
    expect(m.sending, isTrue);
  });

  test('a block goes in at the caret, between the text around it (the user\'s order)', () async {
    ed.value = 'ab';
    ed.caret = 1;
    m.apply(const PasteResult(blocks: [BlockChip(1, '图片 #1')]));
    expect(ed.shown, 'a[图片 #1]b');
    ed.caret = null;
    m.apply(const PasteResult(text: 'c', blocks: [BlockChip(2, 'x.pdf')]));
    expect(ed.shown, 'a[图片 #1]bc[x.pdf]');
    final s = await m.submit() as SubmitPieces;
    expect(s.pieces, [
      {'text': 'a'},
      {'block': 1},
      {'text': 'bc'},
      {'block': 2},
    ]);
    expect(m.inFlight!.text, 'abc');
    expect([for (final b in m.inFlight!.blocks) b.n], [1, 2]);
  });

  test('blocks keep insert order', () async {
    m.apply(const PasteResult(blocks: [BlockChip(3, 'c')]));
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a')]));
    final s = await m.submit() as SubmitPieces;
    expect(s.pieces, [
      {'block': 3},
      {'block': 1},
    ]);
  });

  test('submit while sending takes nothing', () async {
    ed.value = 'a';
    await m.submit();
    ed.value = 'b';
    expect(await m.submit(), isA<SubmitNothing>());
    expect(ed.value, 'b');
  });

  test('an empty submit is a Return, except within 1 s of a send (W15)', () async {
    ed.value = 'a';
    await m.submit();
    m.done(1, null);
    now = now.add(const Duration(milliseconds: 900));
    expect(await m.submit(), isA<SubmitNothing>());
    now = now.add(const Duration(milliseconds: 200));
    expect(await m.submit(), isA<SubmitReturn>());
    expect(m.status, isNull); // W11: no 「已给远端发回车」
    expect(m.sending, isFalse);
  });

  test('done with everything sent drops the item and its blocks', () async {
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a')]));
    ed.value += 'hi';
    await m.submit();
    m.done(2, null);
    expect(dropped, [1]);
    expect(m.inFlight, isNull);
    expect(m.failed, isEmpty);
    expect(m.sending, isFalse);
    expect(allSent, 1);
  });

  test('a partial send keeps the rest as a failed item; retry sends the rest', () async {
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a'), BlockChip(2, 'b')]));
    ed.value += 'x';
    await m.submit();
    m.done(1, 'A 上贴不进去');
    expect(m.failed.single.failure, 'A 上贴不进去');
    expect(dropped, [1]);
    expect(allSent, 0);
    final o = m.failed.single;
    expect(m.retry(o), [
      {'block': 2},
      {'text': 'x'},
    ]);
    expect(m.sending, isTrue);
    expect(m.inFlight, same(o));
    expect(m.failed, isEmpty);
    m.done(2, null);
    expect(dropped, [1, 2]);
    expect(allSent, 1);
    expect(m.failed, isEmpty);
  });

  test('a link drop keeps the text as a failed item', () async {
    ed.value = '长文';
    await m.submit();
    m.done(0, null);
    expect(m.failed.single.failure, '没有发出去');
    expect(m.failed.single.text, '长文');
    expect(allSent, 0);
  });

  test('an empty failure (cancelled, or an upload that failed) is a failed item saying 没有发出去', () async {
    ed.value = 'a';
    await m.submit();
    m.done(0, '');
    expect(m.failed.single.failure, '没有发出去');
  });

  test('setSending(false) waits for done while an item is in flight', () async {
    ed.value = 'a';
    await m.submit();
    m.setSending(false);
    expect(m.sending, isTrue);
  });

  test('putBack: what did not go into the editor at the caret, in its order', () async {
    ed.value = 'p';
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a'), BlockChip(2, 'b')]));
    ed.value += 'x';
    m.apply(const PasteResult(blocks: [BlockChip(4, 'd')]));
    await m.submit();
    m.done(2, 'no'); // 'p' and block 1 went
    ed.value = 'yz';
    m.apply(const PasteResult(blocks: [BlockChip(3, 'c')]));
    ed.caret = 1;
    m.putBack(m.failed.single);
    expect(ed.shown, 'y[b]x[d]z[c]');
    expect([for (final b in m.blocks) b.n], [3, 2, 4]);
    expect(m.failed, isEmpty);
    expect(dropped, [1]);
    final s = await m.submit() as SubmitPieces;
    expect(s.pieces, [
      {'text': 'y'},
      {'block': 2},
      {'text': 'x'},
      {'block': 4},
      {'text': 'z'},
      {'block': 3},
    ]);
  });

  test('retry is null while sending', () async {
    ed.value = 'a';
    await m.submit();
    m.done(0, null);
    ed.value = 'b';
    await m.submit();
    expect(m.retry(m.failed.single), isNull);
    expect(m.failed, hasLength(1));
  });

  test('retry while a take is pending is refused and the failed row stays (I1)', () async {
    ed.value = 'x';
    await m.submit();
    m.done(0, null);
    final slow = _SlowTakeEditor();
    m.attach(slow);
    slow.value = 'y';
    final f = m.submit();
    expect(m.taking, isTrue);
    expect(m.retry(m.failed.single), isNull);
    expect(m.failed.single.text, 'x');
    expect(m.inFlight, isNull);
    slow.gate!.complete();
    final s = await f as SubmitPieces;
    expect(s.pieces, [
      {'text': 'y'},
    ]);
    expect(m.taking, isFalse);
    expect(m.inFlight!.text, 'y');
    expect(m.failed.single.text, 'x');
  });

  test('a take that completes after another round started sends nothing and keeps the text (I1)', () async {
    final slow = _SlowTakeEditor();
    m.attach(slow);
    slow.value = 'y';
    final f = m.submit();
    m.setSending(true); // a round the runner started meanwhile
    slow.gate!.complete();
    expect(await f, isA<SubmitNothing>());
    expect(slow.value, 'y');
    expect(m.inFlight, isNull);
    expect(m.taking, isFalse);
  });

  test('submit stops the pending idle copy', () {
    fakeAsync((fa) {
      final counting = _CountingEditor();
      m.attach(counting);
      counting.value = 'a';
      m.editorChanged();
      m.submit();
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 2));
      fa.flushMicrotasks();
      expect(counting.reads, 0);
    });
  });

  test('adoptFrom: the draft and the text of failed and in-flight rows come over as failed (I3)', () async {
    ed.value = 'x';
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
    ed.value += 'w';
    await m.submit();
    m.done(0, 'boom'); // failed: 'x', block 1, 'w'
    m.apply(const PasteResult(blocks: [BlockChip(2, 'b.png')]));
    await m.submit();
    m.done(0, 'no'); // failed: a block only
    ed.value = 'y';
    await m.submit(); // in flight
    m.apply(const PasteResult(blocks: [BlockChip(3, 'c.png')]));
    ed.value += 'abc'; // typed after the last idle copy
    final fresh = ComposerModel();
    addTearDown(fresh.dispose);
    var notified = 0;
    fresh.addListener(() => notified++);
    final olds = [...m.failed, m.inFlight!];
    final made = fresh.adoptFrom(m);
    expect(made.keys, [olds[0], olds[2]], reason: 'the rows with text, in order');
    expect(made.values, fresh.failed);
    await Future<void>.delayed(Duration.zero); // the old editor's read
    expect(fresh.draft, 'abc');
    expect([for (final o in fresh.failed) o.text], ['xw', 'y']);
    expect([for (final o in fresh.failed) o.failure], ['boom', '没有发出去']);
    expect(fresh.failed.every((o) => o.blocks.isEmpty), isTrue);
    expect(fresh.inFlight, isNull);
    expect(fresh.sending, isFalse);
    expect(fresh.blocks, isEmpty);
    expect(notified, greaterThan(0));
    expect(fresh.retry(fresh.failed.first), [
      {'text': 'xw'},
    ]);
  });

  test('adoptFrom without an editor takes the draft', () async {
    await m.detach(ed);
    m.draft = 'd';
    final fresh = ComposerModel();
    addTearDown(fresh.dispose);
    fresh.adoptFrom(m);
    expect(fresh.draft, 'd');
    expect(fresh.failed, isEmpty);
  });

  test('collapse closes and keeps the text', () {
    m.open = true;
    ed.value = 'keep';
    m.collapse();
    expect(m.open, isFalse);
    expect(ed.value, 'keep');
  });

  test('detach reads the draft; attach puts it back', () async {
    ed.value = '草稿';
    await m.detach(ed);
    expect(m.draft, '草稿');
    final ed2 = FakeEditor();
    m.attach(ed2);
    expect(ed2.value, '草稿');
  });

  test('detach clears editorFocused: a disposed editor never reports the blur (m3)', () async {
    m.editorFocused = true;
    await m.detach(ed);
    expect(m.editorFocused, isFalse);
  });

  test('detach of an editor that is not attached does nothing', () async {
    final other = FakeEditor()..value = 'zz';
    await m.detach(other);
    expect(m.draft, '');
    m.insert('q');
    expect(ed.inserted, ['q']);
  });

  test('insert without an editor appends to the draft', () async {

    await m.detach(ed);
    m.draft = 'a';
    m.insert('b');
    expect(m.draft, 'ab');
  });

  test('a change is copied into the draft 1 s after the last one', () {
    fakeAsync((fa) {
      ed.value = 'x';
      m.editorChanged();
      fa.elapse(const Duration(milliseconds: 900));
      expect(m.draft, '');
      ed.value = 'xy';
      m.editorChanged();
      fa.elapse(const Duration(seconds: 1));
      fa.flushMicrotasks();
      expect(m.draft, 'xy');
    });
  });

  test('releaseFocus bumps the tick', () {
    final t = m.releaseTick;
    m.releaseFocus();
    expect(m.releaseTick, t + 1);
  });

  test('pasted text goes in at the caret', () {
    m.apply(const PasteResult(text: 'b'));
    expect(ed.inserted, ['b']);
  });

  test('status clears after its time; copy reports nothing copied after 2 s', () {
    fakeAsync((a) {
      m.copyPressed();
      expect(m.status, '已复制');
      a.elapse(const Duration(seconds: 2));
      expect(m.status, '远端没有复制到东西');
      a.elapse(const Duration(seconds: 2));
      expect(m.status, isNull);
    });
  });

  test('a clip after copy keeps 已复制, then clears', () {
    fakeAsync((a) {
      m.copyPressed();
      a.elapse(const Duration(milliseconds: 500));
      m.clipArrived();
      a.elapse(const Duration(milliseconds: 1600));
      expect(m.status, '已复制');
      a.elapse(const Duration(milliseconds: 500));
      expect(m.status, isNull);
    });
  });

  test('a block deleted from the text (Backspace) is dropped in the runner at send, not before', () async {
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a'), BlockChip(2, 'b')]));
    final one = ed.value[0];
    ed.value = '${ed.value.substring(1)}x';
    expect(dropped, isEmpty, reason: 'an undo can bring it back');
    expect(m.blocks.map((b) => b.n), [1, 2]);
    final s = await m.submit() as SubmitPieces;
    expect(s.pieces, [
      {'block': 2},
      {'text': 'x'},
    ]);
    expect(dropped, [1]);
    expect(m.blocks, isEmpty);
    // The mark is plain text again: no block of that mark is held.
    m.done(2, null);
    ed.value = '${one}y';
    expect((await m.submit() as SubmitPieces).pieces, [
      {'text': '${one}y'},
    ]);
  });

  test('a block deleted from the text is dropped when the editor goes; one kept comes back with it', () async {
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a'), BlockChip(2, 'b')]));
    ed.value = '${ed.value.substring(1)}x';
    await m.detach(ed);
    expect(dropped, [1]);
    expect(m.draftText, 'x');
    final ed2 = FakeEditor();
    m.attach(ed2);
    expect(ed2.shown, '[b]x');
  });

  test('an empty send (only deleted blocks) drops them and is a Return', () async {
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a')]));
    ed.value = '';
    expect(await m.submit(), isA<SubmitReturn>());
    expect(dropped, [1]);
    expect(m.blocks, isEmpty);
  });

  test('a held block\'s mark in pasted text is left out; a second copy of a chip goes once', () async {
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a')]));
    final mark = ed.value;
    m.apply(PasteResult(text: 'q${mark}r'));
    expect(ed.shown, '[a]qr');
    ed.value += mark; // a copy the Flutter field made by hand
    expect((await m.submit() as SubmitPieces).pieces, [
      {'block': 1},
      {'text': 'qr'},
    ]);
  });

  test('the draft a record sees has no block marks', () {
    fakeAsync((fa) {
      final seen = <String>[];
      m.onDraftChanged = seen.add;
      ed.value = 'a';
      m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
      ed.value += 'b';
      m.editorChanged();
      fa.elapse(const Duration(seconds: 2));
      fa.flushMicrotasks();
      expect(seen, ['ab']);
      expect(m.draft, hasLength(3));
      expect(m.draftText, 'ab');
    });
  });

  test('a mark the text already has as a glyph is not given to a block', () async {
    final first = String.fromCharCode(blockMarks[0]), second = String.fromCharCode(blockMarks[1]);
    m.setDraft(first);
    m.apply(PasteResult(text: second, blocks: const [BlockChip(1, 'a')]));
    expect(ed.shown, '$first$second[a]');
    expect((await m.submit() as SubmitPieces).pieces, [
      {'text': '$first$second'},
      {'block': 1},
    ]);
  });

  test('more blocks than marks: the extra one is dropped and said', () {
    for (var i = 0; i < blockMarks.length; i++) {
      m.apply(PasteResult(blocks: [BlockChip(i, 'b$i')]));
    }
    expect(dropped, isEmpty);
    m.apply(const PasteResult(blocks: [BlockChip(9999, '太多')]));
    expect(dropped, [9999]);
    expect(m.status, contains('太多'));
    expect(m.blocks, hasLength(blockMarks.length));
  });

  test('onAllSent only after every piece went', () async {
    ed.value = 'hi';
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
    await m.submit();
    m.done(1, 'A 上贴不进去');
    expect(allSent, 0);
    m.retry(m.failed.single);
    m.done(0, '');
    expect(allSent, 0);
    m.retry(m.failed.single);
    m.done(1, null);
    expect(allSent, 1);
  });

  test('a round where all went but something was said keeps that, and is no failed row', () async {
    final seen = <String?>[];
    m.onFinished = (o, {required all}) => seen.add(o.failure);
    ed.value = 'hi';
    await m.submit();
    m.done(1, '回车没按上');
    expect(m.failed, isEmpty);
    expect(seen, ['回车没按上']);
    expect(allSent, 0);
    ed.value = 'ok';
    await m.submit();
    m.done(1, null);
    expect(seen, ['回车没按上', null]);
    expect(allSent, 1);
  });

  test('blocks only: one piece, one Return', () async {
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
    await m.submit();
    m.done(1, null);
    expect(allSent, 1);
  });

  test('submit reports the piece before the draft clears', () async {
    final log = <String>[];
    m.onDraftChanged = (t) => log.add('draft:$t');
    m.onSubmitted = (o) => log.add('submitted:${o.text}:${m.draft}:${o.at == now}');
    m.setDraft('hello');
    log.clear();
    expect(await m.submit(), isA<SubmitPieces>());
    expect(log, ['submitted:hello:hello:true', 'draft:']);
  });

  test('done reports the round once with what went', () async {
    final rounds = <String>[];
    m.onFinished = (o, {required all}) => rounds.add('${o.sent}:$all');
    ed.value = 'hi';
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
    await m.submit();
    m.done(1, 'x');
    expect(rounds, ['1:false']);
  });

  test('retry reports again with the same piece', () async {
    final seen = <Outgoing>[];
    m.onSubmitted = seen.add;
    ed.value = 'hi';
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
    await m.submit();
    m.done(1, 'x');
    now = now.add(const Duration(seconds: 5));
    m.retry(m.failed.single);
    expect(seen.length, 2);
    expect(identical(seen[0], seen[1]), isTrue);
    expect(seen[1].at, now);
  });

  test('a late take that goes back reports nothing', () async {
    var submitted = 0;
    m.onSubmitted = (_) => submitted++;
    final slow = _SlowTakeEditor();
    m.attach(slow);
    slow.value = 'y';
    final f = m.submit();
    m.setSending(true);
    slow.gate!.complete();
    expect(await f, isA<SubmitNothing>());
    expect(submitted, 0);
  });

  test('onDraftChanged fires on idle copy, detach and setDraft, not for the same text', () {
    fakeAsync((fa) {
      final seen = <String>[];
      m.onDraftChanged = seen.add;
      ed.value = 'a';
      m.editorChanged();
      fa.elapse(const Duration(seconds: 2));
      fa.flushMicrotasks();
      expect(seen, ['a']);
      m.editorChanged();
      fa.elapse(const Duration(seconds: 2));
      fa.flushMicrotasks();
      expect(seen, ['a']);
      m.setDraft('b');
      m.setDraft('b');
      expect(seen, ['a', 'b']);
      ed.value = 'c';
      m.detach(ed);
      fa.flushMicrotasks();
      expect(seen, ['a', 'b', 'c']);
    });
  });
}
