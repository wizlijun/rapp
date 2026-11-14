import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_model.dart';
import 'package:rapp/embed/session_port.dart';

void main() {
  late ComposerModel m;
  late List<int> dropped;

  setUp(() {
    dropped = [];
    m = ComposerModel(onDrop: dropped.add);
  });

  tearDown(() => m.dispose());

  test('pieces are blocks in insert order, then text', () {
    m.apply(const PasteResult(blocks: [BlockChip(3, '[图片 #3 1×1]')]));
    m.apply(const PasteResult(blocks: [BlockChip(1, '[文件 a 1 B]')]));
    m.text = 'x';
    expect(m.pieces(), [
      {'block': 3},
      {'block': 1},
      {'text': 'x'},
    ]);
    m.text = '';
    expect(m.pieces(), [
      {'block': 3},
      {'block': 1},
    ]);
  });

  test('an empty send is a Return', () {
    expect(m.send(), SendOutcome.empty);
    expect(m.status, '已给远端发回车');
    expect(m.sending, isFalse);
  });

  test('a send is ignored while one is running', () {
    m.text = 'a';
    expect(m.send(), SendOutcome.sent);
    expect(m.sending, isTrue);
    expect(m.send(), SendOutcome.ignored);
  });

  test('done clears what was sent if unchanged, else notes', () {
    m.apply(const PasteResult(blocks: [BlockChip(1, '[贴入文字 #1 +1 行]')]));
    m.text = 'hi';
    expect(m.send(), SendOutcome.sent);
    m.done(2, null);
    expect(m.blocks, isEmpty);
    expect(m.text, '');
    expect(dropped, [1]);
    expect(m.sending, isFalse);
    expect(m.status, isNull);

    // Only the block went before the failure: the text stays.
    m.apply(const PasteResult(blocks: [BlockChip(2, '[图片 #2 1×1]')]));
    m.text = 'again';
    m.send();
    m.done(1, 'A 上的目标窗口不在最前');
    expect(m.blocks, isEmpty);
    expect(m.text, 'again');
    expect(dropped, [1, 2]);
    expect(m.status, 'A 上的目标窗口不在最前');

    // Changed while sending: nothing is cleared.
    m.send();
    m.text = 'changed';
    m.done(1, null);
    expect(m.text, 'changed');
    expect(m.status, '（发送中改过内容，未清除）');
  });

  test('done keeps the cursor and composing range, shifted past what went', () {
    m.text = 'hi';
    m.send();
    m.controller.value = const TextEditingValue(
        text: 'hi there', selection: TextSelection.collapsed(offset: 5), composing: TextRange(start: 3, end: 8));
    m.done(1, null);
    expect(m.text, ' there');
    expect(m.controller.selection, const TextSelection.collapsed(offset: 3));
    expect(m.controller.value.composing, const TextRange(start: 1, end: 6));

    // Inside what went: clamped to its end.
    m.send();
    m.controller.value = const TextEditingValue(
        text: ' there!', selection: TextSelection(baseOffset: 2, extentOffset: 7));
    m.done(1, null);
    expect(m.text, '!');
    expect(m.controller.selection, const TextSelection(baseOffset: 0, extentOffset: 1));
    expect(m.controller.value.composing, TextRange.empty);
  });

  test('a cancelled send (empty failure) shows nothing', () {
    m.text = 'a';
    m.send();
    m.done(0, '');
    expect(m.status, isNull);
    expect(m.text, 'a');
  });

  test('status clears after 3 s', () {
    fakeAsync((a) {
      m.send();
      expect(m.status, '已给远端发回车');
      a.elapse(const Duration(milliseconds: 2900));
      expect(m.status, '已给远端发回车');
      a.elapse(const Duration(milliseconds: 200));
      expect(m.status, isNull);
    });
  });

  test('esc clears text, then collapses', () {
    m.open = true;
    m.text = 'abc';
    m.esc();
    expect(m.text, '');
    expect(m.open, isTrue);
    m.esc();
    expect(m.open, isFalse);
  });

  test('copy reports nothing copied after 2 s', () {
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

  test('pasted text goes in at the cursor', () {
    m.controller.value = const TextEditingValue(text: 'ac', selection: TextSelection.collapsed(offset: 1));
    m.apply(const PasteResult(text: 'b'));
    expect(m.text, 'abc');
    expect(m.controller.selection, const TextSelection.collapsed(offset: 2));
  });

  test('a removed block is dropped in the runner', () {
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a'), BlockChip(2, 'b')]));
    m.removeBlock(1);
    expect(m.blocks.map((b) => b.n), [2]);
    expect(dropped, [1]);
  });

  test('onAllSent only after every piece went', () {
    var n = 0;
    final m = ComposerModel(onAllSent: () => n++);
    m.text = 'hi';
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
    m.send();
    m.done(1, 'A 上贴不进去');
    expect(n, 0);
    m.send();
    m.done(0, ''); // cancelled before anything went
    expect(n, 0);
    m.send();
    m.done(0, null);
    expect(n, 0);
    m.send(); // the block already went in round one: only the text is left
    m.done(1, null);
    expect(n, 1);
    m.done(0, null);
    expect(n, 1);
  });

  test('blocks only: one piece, one Return', () {
    var n = 0;
    final m = ComposerModel(onAllSent: () => n++);
    m.apply(const PasteResult(blocks: [BlockChip(1, 'a.png')]));
    m.send();
    m.done(1, null);
    expect(n, 1);
  });
}
