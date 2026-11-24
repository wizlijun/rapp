import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_editor.dart';
import 'package:rapp/embed/composer_model.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/voice_fix.dart' show VoiceHeard;

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

/// A native view already gone: its first [fails] reads throw.
class _FailingReadEditor extends FakeEditor {
  _FailingReadEditor(this.fails);
  int fails;
  int reads = 0;

  @override
  Future<String> read() async {
    reads++;
    if (fails > 0) {
      fails--;
      throw StateError('view gone');
    }
    return value;
  }
}

/// A read that fails once [gate] does.
class _GatedFailEditor extends FakeEditor {
  final gate = Completer<void>();
  int reads = 0;

  @override
  Future<String> read() async {
    if (reads++ == 0) {
      await gate.future;
      throw StateError('view gone');
    }
    return value;
  }
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

  group('submitText', () {
    test('sends the text alone and leaves the draft as it was', () {
      m.draft = 'half written';
      final r = m.submitText('  你好  ');
      expect(r, isA<SubmitPieces>());
      expect((r as SubmitPieces).pieces, [
        {'text': '你好'}
      ]);
      expect(m.draft, 'half written');
      expect(m.sending, true);
      expect(m.inFlight!.draftless, true);
    });

    test('empty or blank text sends nothing', () {
      expect(m.submitText('   '), isA<SubmitNothing>());
      expect(m.sending, false);
    });

    test('while a round runs it sends nothing and busy says so', () {
      m.draft = 'keep';
      expect(m.busy, false);
      m.submitText('a');
      expect(m.busy, true);
      expect(m.submitText('b'), isA<SubmitNothing>());
      expect(m.draft, 'keep');
    });

    test('keep appends on a new line without an editor', () async {
      await m.detach(ed); // no editor: the text goes straight into the draft
      m.draft = 'x';
      await m.keep(' y ');
      expect(m.draft, 'x\ny');
      m.draft = '';
      await m.keep('y');
      expect(m.draft, 'y');
    });

    test('keep with an editor attached lands at the end, not at the caret', () async {
      ed.value = 'hello world';
      ed.caret = 5;
      await m.keep(' y ');
      expect(ed.value, 'hello world\ny');
      ed.value = '';
      await m.keep('z');
      expect(ed.value, 'z');
    });

    test('keep with undo and an editor: the original goes in first, then the text in one undoable step', () async {
      ed.value = 'hello';
      await m.keep(' 原话。 ', undo: '嗯原话');
      expect(ed.value, 'hello\n原话。');
      expect(ed.undoTo, 'hello\n嗯原话');
    });

    test('keep with undo and no editor: the panel opening puts the original in first, then the text', () async {
      await m.detach(ed);
      m.draft = 'x';
      await m.keep('原话。', undo: '嗯原话');
      expect(m.draft, 'x\n原话。');
      final e2 = FakeEditor();
      await m.attach(e2);
      expect(e2.value, 'x\n原话。');
      expect(e2.undoTo, 'x\n嗯原话');
      await m.detach(e2);
      final e3 = FakeEditor();
      await m.attach(e3);
      expect(e3.undoTo, isNull); // once only
    });

    test('a change to the draft before the panel opens drops the undo', () async {
      await m.detach(ed);
      await m.keep('原话。', undo: '嗯原话');
      m.draft = '原话。改';
      final e2 = FakeEditor();
      await m.attach(e2);
      expect(e2.value, '原话。改');
      expect(e2.undoTo, isNull);
    });

    test('held blocks stay held after a voice send', () {
      m.apply(const PasteResult(blocks: [BlockChip(1, '图片 #1')]));
      m.submitText('t');
      expect(m.blocks.map((b) => b.n), [1]);
      expect(dropped, isEmpty);
    });

    test('done ends a voice round like any other', () {
      m.submitText('t');
      m.done(1, null);
      expect(m.sending, false);
      expect(allSent, 1);
    });
  });

  test('a late editor detach read does not overwrite a native draft', () async {
    final old = _SlowReadEditor();
    await m.attach(old);
    final detached = m.detach(old);
    m.setDraft('native typing');
    m.setDraft(''); // ABA: equal text does not make the old read current again.
    m.setDraft('native typing');
    old.gate.complete('old stage');
    await detached;
    expect(m.draft, 'native typing');
  });

  test('native handoff waits for the editor composition snapshot', () async {
    final old = _SlowReadEditor();
    await m.attach(old);
    final read = m.readDraft();
    old.gate.complete('刚组好的字');
    expect(await read, '刚组好的字');
    expect(m.draft, '刚组好的字');
  });

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

  test('a panel send with pendingAi tells onAiSent the sent text', () async {
    const ai = VoiceAi(app: 'dictation', original: 'a', result: 'b');
    final got = <(VoiceAi, String)>[];
    m.onAiSent = (a, t) => got.add((a, t));
    m.pendingAi = ai;
    ed.value = 'edited';
    await m.submit();
    expect(got, [(ai, 'edited')]);
  });

  test('a send without pendingAi does not', () async {
    var n = 0;
    m.onAiSent = (a, t) => n++;
    ed.value = 'plain';
    await m.submit();
    m.pendingAi = const VoiceAi(app: 'dictation', original: 'a', result: 'b');
    await m.submit(); // empty: nothing sent
    expect(n, 0);
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

  test('text kept into the editor while it folds reaches the draft (the close copy is stale)', () async {
    m.open = true;
    ed.value = 'A';
    m.collapse(); // the close copy reads 'A'
    await Future<void>.delayed(Duration.zero);
    await m.keep('B'); // a tidy result or a voice fallback lands during the 340 ms fold
    expect(ed.value, 'A\nB');
    await m.detach(ed); // the fold ended
    expect(m.draft, 'A\nB');
  });

  group('a close copy whose read throws (final review)', () {
    test('raises nothing; the detach at the fold\'s end reads again', () async {
      final e = _FailingReadEditor(1);
      await m.attach(e);
      m.open = true;
      e.value = '写了一半';
      m.collapse(); // the close copy throws: no unhandled async error
      await Future<void>.delayed(Duration.zero);
      await m.detach(e);
      expect(e.reads, 2);
      expect(m.draft, '写了一半');
    });

    test('a detach that took the copy before it failed reads again', () async {
      final e = _GatedFailEditor();
      await m.attach(e);
      m.open = true;
      e.value = '写了一半';
      m.collapse();
      final detached = m.detach(e); // the fold ended before the read came back
      e.gate.complete();
      await detached;
      expect(e.reads, 2);
      expect(m.draft, '写了一半');
    });

    test('every read failing leaves the draft as it was, and the detach completes', () async {
      m.draft = '旧的';
      final e = _FailingReadEditor(99);
      await m.attach(e);
      m.open = true;
      e.value = '新的';
      m.collapse();
      await Future<void>.delayed(Duration.zero);
      await m.detach(e);
      expect(m.draft, '旧的');
    });
  });

  test('an insert during the fold reaches the draft too', () async {
    m.open = true;
    ed.value = 'A';
    m.collapse();
    await Future<void>.delayed(Duration.zero);
    m.insert('C');
    await m.detach(ed);
    expect(m.draft, 'AC');
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

  test('a round trip through a detached native composer keeps the blocks', () async {
    m.apply(const PasteResult(text: 'hi', blocks: [BlockChip(1, 'a'), BlockChip(2, 'b')]));
    // Handing over: the other window gets the text without marks, the blocks beside it as chips.
    final handed = await m.readDraft();
    expect(handed, 'hi');
    await m.detach(ed);
    // It types in that window and taps chip 1 away; neither touches the blocks by mark.
    m.setDetachedDraft('hi there');
    expect(m.blocks.map((b) => b.n), [1, 2], reason: 'plain text must not condemn the chips');
    m.removeBlock(1);
    expect(dropped, [1]);
    expect(m.blocks.map((b) => b.n), [2]);
    // Back on the stage: block 2 is still held, so its mark is in the editor's text again.
    final next = FakeEditor();
    await m.attach(next);
    expect(next.labels.values.toSet(), {'b'}, reason: 'the chip comes back with the editor');
    expect(m.draftText, 'hi there');
    expect((await m.submit() as SubmitPieces).pieces, [
      {'text': 'hi there'},
      {'block': 2},
    ]);
  });

  test('inline native handoff preserves block order between text runs', () async {
    m.apply(const PasteResult(text: 'before', blocks: [BlockChip(1, 'a'), BlockChip(2, 'b')]));
    final marks = m.nativeBlocks.map((b) => String.fromCharCode(b.mark!)).toList();
    expect(await m.readDraft(inline: true), 'before${marks[0]}${marks[1]}');
    await m.detach(ed);
    m.setDetachedDraft('前${marks[1]}中${marks[0]}后', inline: true);
    final next = FakeEditor();
    await m.attach(next);
    expect(next.value, '前${marks[1]}中${marks[0]}后');
    expect((await m.submit() as SubmitPieces).pieces, [
      {'text': '前'}, {'block': 2}, {'text': '中'}, {'block': 1}, {'text': '后'},
    ]);
  });

  test('deleted inline native anchors are not resurrected on attach or send', () async {
    m.apply(const PasteResult(text: 'before', blocks: [BlockChip(1, 'a'), BlockChip(2, 'b')]));
    final mark = String.fromCharCode(m.nativeBlocks[1].mark!);
    await m.detach(ed);
    m.setDetachedDraft('before${mark}after', inline: true);
    expect(dropped, isEmpty, reason: 'native undo can still restore the anchor');
    final next = FakeEditor();
    await m.attach(next);
    expect(dropped, [1]);
    expect(next.value, 'before${mark}after');
    expect((await m.submit() as SubmitPieces).pieces, [
      {'text': 'before'}, {'block': 2}, {'text': 'after'},
    ]);
  });

  test('a chip tapped away in a native composer drops that block only, and its mark leaves the text', () async {
    m.apply(const PasteResult(text: 'hi', blocks: [BlockChip(1, 'a'), BlockChip(2, 'b')]));
    expect(m.blocks.map((b) => b.n), [1, 2]);
    final before = ed.value;
    m.removeBlock(1);
    expect(dropped, [1], reason: 'the other window has no undo, so the runner can forget it');
    expect(m.blocks.map((b) => b.n), [2], reason: 'the stale draft must not condemn the other block');
    await pumpEventQueue();
    expect(ed.value.length, before.length - 1, reason: 'one mark unit left the editor');
    expect(m.draftText, 'hi', reason: 'the text itself is untouched');
    // Block 2's mark is still in the text, so a send still carries it.
    expect((await m.submit() as SubmitPieces).pieces, [
      {'text': 'hi'},
      {'block': 2},
    ]);
    expect(dropped, [1], reason: 'block 2 went out with the send; the runner keeps it until done');
  });

  test('a chip tapped away with no editor attached only touches the draft', () async {
    m.apply(const PasteResult(text: 'hi', blocks: [BlockChip(1, 'a')]));
    final mark = ed.value[2];
    await m.detach(ed);
    expect(m.draft.contains(mark), isTrue);
    m.removeBlock(1);
    expect(dropped, [1]);
    expect(m.blocks, isEmpty);
    expect(m.draft, 'hi');
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

  group('↑/↓ through what was sent (R2)', () {
    late List<String> sent;
    setUp(() {
      sent = ['newest', 'middle', 'oldest'];
      m.recall = () => sent;
    });
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('up stashes the text being written; down brings it back as it was', () async {
      ed.value = 'half written\nsecond line'; // typed a moment ago: no idle copy yet
      expect(m.arrow(true), true);
      await settle();
      expect(ed.value, 'newest');
      expect(m.browsing, true);
      expect(m.arrow(false), true);
      await settle();
      expect(ed.value, 'half written\nsecond line');
      expect(m.draft, 'half written\nsecond line');
      expect(m.browsing, false);
      expect(m.arrow(false), false, reason: 'down on the text being written is the caret\'s');
    });

    test('up walks older and stays on the oldest; down walks back', () async {
      final seen = <String>[];
      for (final up in [true, true, true, true, false, false, false]) {
        expect(m.arrow(up), true);
        await settle();
        seen.add(ed.value);
      }
      expect(seen, ['newest', 'middle', 'oldest', 'oldest', 'middle', 'newest', '']);
    });

    test('nothing to bring back: up is not taken', () {
      sent = [];
      ed.value = 'x';
      expect(m.canRecall, false);
      expect(m.arrow(true), false);
      expect(ed.value, 'x');
    });

    test('a record edited on the way keeps its edit until the send', () async {
      ed.value = 'live';
      m.arrow(true);
      m.arrow(true);
      await settle();
      ed.value = 'middle, edited';
      m.arrow(true);
      m.arrow(false);
      await settle();
      expect(ed.value, 'middle, edited');
      m.arrow(false);
      m.arrow(false);
      await settle();
      expect(ed.value, 'live');
      m.arrow(true);
      m.arrow(true);
      await settle();
      expect(ed.value, 'middle, edited', reason: 'back on the text being written, the round goes on');
      final r = await m.submit();
      expect((r as SubmitPieces).pieces, [
        {'text': 'middle, edited'}
      ]);
      expect(ed.value, 'live', reason: 'sent from a record: the text being written comes back');
      m.done(1, null);
      m.arrow(true);
      m.arrow(true);
      await settle();
      expect(ed.value, 'middle', reason: 'a send ends the round: its edits go');
    });

    test('keys pressed quickly: each step reads after the one before, and a send waits for them', () async {
      ed.value = 'live';
      m.arrow(true);
      m.arrow(true);
      final r = await m.submit();
      expect((r as SubmitPieces).pieces, [
        {'text': 'middle'}
      ]);
      expect(ed.value, 'live');
    });

    test('the panel closing and opening while a record is shown keeps the round', () async {
      ed.value = 'live';
      m.arrow(true);
      await settle();
      await m.detach(ed);
      expect(m.draft, 'newest');
      final ed2 = FakeEditor();
      await m.attach(ed2);
      expect(ed2.value, 'newest');
      expect(m.arrow(false), true);
      await settle();
      expect(ed2.value, 'live');
    });

    test('without an editor: through the draft, or a native window\'s text', () async {
      await m.detach(ed);
      m.draft = 'live';
      final shown = <String>[];
      m.arrow(true, show: shown.add);
      await settle();
      expect(m.draft, 'newest');
      m.draft = 'newest!'; // the native window's text came back edited
      m.arrow(false, show: shown.add);
      await settle();
      expect(shown, ['newest', 'live']);
      m.arrow(true, show: shown.add);
      await settle();
      expect(shown.last, 'newest!');
    });

    test('a block in the text being written survives the round and a send from a record', () async {
      m.apply(PasteResult(text: 'see ', blocks: const [BlockChip(1, '图片', kind: 'image')]));
      final live = ed.value;
      expect(m.blocks, hasLength(1));
      m.arrow(true);
      await settle();
      await m.detach(ed); // a read without the mark: still held for the text that comes back
      await m.attach(ed);
      expect(ed.value, 'newest');
      expect(m.blocks, hasLength(1));
      final r = await m.submit();
      expect((r as SubmitPieces).pieces, [
        {'text': 'newest'}
      ]);
      expect(ed.value, live);
      expect(m.blocks, hasLength(1));
      expect(dropped, isEmpty);
    });

    test('an emptied record sent as a Return: the text being written comes back with its block', () async {
      m.apply(PasteResult(text: 'see ', blocks: const [BlockChip(1, '图片', kind: 'image')]));
      final live = ed.value;
      m.arrow(true);
      await settle();
      ed.value = '';
      expect(await m.submit(), isA<SubmitReturn>());
      expect(ed.value, live);
      expect(m.blocks.single.n, 1);
      expect(dropped, isEmpty);
    });

    test('onRecalled says what is shown and what is being written', () async {
      final calls = <String>[];
      m.onRecalled = (shown, live) => calls.add('$shown|$live');
      ed.value = 'live';
      m.arrow(true);
      m.arrow(true);
      m.arrow(false);
      m.arrow(false);
      await settle();
      expect(calls, ['newest|live', 'middle|live', 'newest|live', 'null|']);
    });
  });

  group('voice and AI origin (voice AI tidy §5.4)', () {
    const ai = VoiceAi(app: 'dictation', original: '嗯那个我门明天开会', result: '我们明天开会。');

    test('submitText carries the voice origin', () {
      Outgoing? got;
      m.onSubmitted = (o) => got = o;
      m.submitText('我们明天开会。', voice: const VoiceOrigin(ai: ai));
      expect(got!.voice!.ai, ai);
      expect(got!.draftless, isTrue);
    });

    test('a panel send takes pendingAi once', () async {
      final got = <Outgoing>[];
      m.onSubmitted = got.add;
      m.pendingAi = ai;
      ed.value = '我们明天开会。';
      await m.submit();
      expect(got.single.voice?.ai, ai);
      expect(m.pendingAi, isNull);
      m.done(1, null);
      ed.value = '再说一句';
      await m.submit();
      expect(got.last.voice, isNull);
    });

    test('pendingHeard is sent and cleared like pendingAi', () async {
      const heard = VoiceHeard(heard: '打开拍森', fixed: '打开Python');
      final got = <Outgoing>[];
      final heards = <(VoiceHeard, String)>[];
      var ais = 0;
      m.onSubmitted = got.add;
      m.onHeardSent = (h, t) => heards.add((h, t));
      m.onAiSent = (a, t) => ais++;
      m.pendingHeard = heard;
      ed.value = '打开拍森';
      await m.submit();
      expect(got.single.voice!.heard, heard);
      expect(got.single.voice!.ai, isNull);
      expect(heards, [(heard, '打开拍森')]);
      expect(ais, 0);
      expect(m.pendingHeard, isNull);
      m.done(1, null);
      ed.value = '再说一句';
      await m.submit();
      expect(got.last.voice, isNull);
      expect(heards, hasLength(1));
    });

    test('pendingHeard goes when the draft is emptied, or ↑ recalls another text', () async {
      const heard = VoiceHeard(heard: '打开拍森', fixed: '打开Python');
      await m.detach(ed);
      m.draft = '打开Python';
      m.pendingHeard = heard;
      m.draft = '';
      expect(m.pendingHeard, isNull);
      await m.attach(ed);
      m.recall = () => ['older'];
      ed.value = '打开Python';
      m.pendingHeard = heard;
      expect(m.arrow(true), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(ed.value, 'older');
      expect(m.pendingHeard, isNull);
    });

    test('the AI mark takes over from what was heard', () async {
      final heards = <VoiceHeard>[];
      m.onHeardSent = (h, t) => heards.add(h);
      m.pendingHeard = const VoiceHeard(heard: '打开拍森', fixed: '打开Python');
      m.pendingAi = ai;
      expect(m.pendingHeard, isNull);
      ed.value = '我们明天开会。';
      await m.submit();
      expect(heards, isEmpty);
    });

    test('adoptFrom carries pendingHeard only with the draft it takes', () async {
      const heard = VoiceHeard(heard: '打开拍森', fixed: '打开Python');
      await m.detach(ed);
      m.draft = '打开Python';
      m.pendingHeard = heard;
      final own = ComposerModel();
      addTearDown(own.dispose);
      own.draft = '别的话';
      own.adoptFrom(m);
      expect(own.pendingHeard, isNull);
      final took = ComposerModel();
      addTearDown(took.dispose);
      took.adoptFrom(m);
      expect(took.draft, '打开Python');
      expect(took.pendingHeard, heard);
    });

    test('pendingAi goes when the draft is emptied', () {
      m.draft = '我们明天开会。';
      m.pendingAi = ai;
      m.draft = '';
      expect(m.pendingAi, isNull);
    });

    // Review 2026-11-20 minor: the old composer's mark goes only with the draft it belongs to.
    test('adoptFrom carries pendingAi only with the draft it takes', () async {
      await m.detach(ed);
      m.draft = '我们明天开会。';
      m.pendingAi = ai;
      final own = ComposerModel();
      addTearDown(own.dispose);
      own.draft = '别的话';
      own.adoptFrom(m);
      expect(own.draft, '别的话');
      expect(own.pendingAi, isNull);
      final took = ComposerModel();
      addTearDown(took.dispose);
      took.adoptFrom(m);
      expect(took.draft, '我们明天开会。');
      expect(took.pendingAi, ai);
    });

    test('pendingAi goes when ↑ recalls another text', () async {
      m.recall = () => ['older'];
      ed.value = '我们明天开会。';
      m.pendingAi = ai;
      expect(m.arrow(true), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(ed.value, 'older');
      expect(m.pendingAi, isNull);
    });

    test("adoptFrom carries pendingAi and each row's voice", () async {
      await m.detach(ed);
      m.draft = '我们明天开会。';
      m.pendingAi = ai;
      m.submitText('我们明天开会。', voice: const VoiceOrigin(ai: ai));
      m.done(0, 'boom');
      final fresh = ComposerModel();
      addTearDown(fresh.dispose);
      fresh.adoptFrom(m);
      expect(fresh.pendingAi, ai);
      expect(fresh.failed.single.voice?.ai, ai);
    });
  });
}
