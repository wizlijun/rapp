# 写作面板 S1：新布局（仍用 Flutter 输入框）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把舞台底部横贯的输入条换成 720 宽、一行起步、往上长的写作面板，控件收进「＋」，画面打开时上移一行，并在编辑区和面板之间立起 `ComposerEditor` 接口（S1 只有 `FlutterEditor` 一种实现）。

**Architecture:** 几乎只动 GUI（Dart）；唯一的原生改动是 macOS 按键分流让 ⌃↩ 留在 rapp（Task 6）。文字只有一个主人：编辑区（`ComposerEditor`）。`ComposerModel` 不再持有 `TextEditingController`，只在四个时刻向编辑区要一份全文存进 `draft`：发送（整段取走）、切会话、停笔 1 秒、收起。Enter、Esc、空 Enter、1 秒内的空 Enter 这些规则都在 `ComposerModel.submit` 和 `ComposerPanel` 里，编辑区只上报"发生了什么"。画面上移用 `Transform.translate` 包住舞台内容，舞台尺寸不变，所以 A 不会收到改尺寸。

**Tech Stack:** Flutter / Dart（`gui/`），`flutter_test`。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-composer-writing-panel-design.md`（下称「规格」）。本计划只做规格 §7 的 **S1**；S0 探查、S2 macOS 原生编辑区、S3 Linux 探查另写计划。W17（↑ 取上一条）属于《输入记录》H2，不在这里做。

## Global Constraints

- Flutter 不在 PATH 上：用 `~/development/flutter/bin/flutter`，在 `gui/` 下跑。跑完测试后 `git checkout gui/pubspec.lock` 还原。
- 全部验证：`cd gui && ~/development/flutter/bin/flutter analyze` 没有问题，`~/development/flutter/bin/flutter test` 全过。
- 面向用户的文字一律中文，照规格原样：
  - 灰字：`写给 <app 名>`（W12）
  - 「＋」浮层：`附件…`（右侧小字 `也可以直接粘贴`）、`在远端复制`（右侧小字：macOS `⌘C`，其他 `Ctrl+C`）、分组标题 `按键 · 直接发给远端`、`收起`
  - 发送中的一条：`发送中`；没发出去的一条：失败原因，按钮 `重试`、`放回输入框`
- W1 宽 720；舞台比 736 窄时取舞台宽减 16。
- W2 一行高 48；字号 15，行高 22；字体、颜色跟主题；编辑区里**不加** MATRIX 的文字光晕（`shadows: const []`）。
- W3 面板的框最高到舞台高度的一半，之后在框内滚动。
- W4 打开时画面上移 64；增高时不再动；收起时移回；动画 ≤ 0.15 秒，`MediaQuery.disableAnimationsOf(context)` 为真时不用动画。
- W5 Enter 发送；Shift+Enter 换行；组字时 Enter、Esc 归输入法；空着按 Enter 给远端发回车。
- W6 Esc 只收起，不清空。
- W7 发送后框留着、缩回一行、焦点留在编辑区。
- W8 快捷键所有平台都是 `Ctrl+Enter`（macOS 上是 ⌃↩），Return 和小键盘 Enter 都算。
- W9 按键顺序：Esc、Tab、⌘、⌥、删除、←、↓、↑、→、回车；⌘ ⌥ 粘住；点按键不关浮层。
- W11 去掉「已发送…」「已给远端发回车」这类每次都出现的提示。
- W13 「＋」和发送固定在框的右下角，点按区域 48 高。
- W15 发送后 1 秒内的空 Enter 不算数。
- W16 增高没有动画。
- W14 不变的：草稿跟着会话走；app 配置里的开关和 `noComposer`；发送后补回车；标记输入框位置；发送前切英文并点标记的位置；粘贴规则和块的上限（都在 runner 里，不动）。
- 不动：`session_port.dart` 的 composer 调用（`composerSend`、`composerPaste`、`composerAttach`、`composerDropBlock`、`cancelTransfer`、`key`）和 runner 一侧。

## Review Focus

1. **打字中切会话**：A 会话的草稿留在 A，不串到 B；切回 A 时文字还在。→ Task 3 的测试 `drafts stay with their session across a switch`。
2. **发送进行中又按 Enter**：编辑区里的新文字不能被取走，也不发。→ Task 1 的 `submit while sending takes nothing`。
3. **发送途中断线**（`linkDown` → `done(0, null)`）：这段文字不能丢，变成一条可「放回输入框」的失败项。→ Task 1 的 `a link drop keeps the text as a failed item`。
4. **面板收起时来了剪贴板的「插入」**：进草稿，面板打开后就在编辑区里。→ Task 3 保留并改写 `a clip insert opens the composer with it`。
5. **输入法组字时 Dart 往编辑区里写**（插入、放回）：等组字结束再写，不出现重复字母。→ Task 2 的 `insert while composing waits for the commit`。

---

## File Structure

| 文件 | 做什么 |
|---|---|
| Create `gui/lib/embed/composer_editor.dart` | `ComposerEditor` 接口、`EditorHandlers`、`EditorStyle` |
| Create `gui/lib/embed/flutter_editor.dart` | `FlutterEditor`：现在的 `TextField`，加组字保护和按键上报 |
| Modify `gui/lib/embed/composer_model.dart` | 去掉 controller；`draft`、`attach/detach`、`submit`、发件项 `Outgoing`、`collapse`、W15 |
| Delete `gui/lib/embed/composer_bar.dart`，Create `gui/lib/embed/composer_panel.dart` | `ComposerPanel`、`composerLayer`、`panelWidth`、提示行、发件项 |
| Create `gui/lib/embed/composer_plus.dart` | 「＋」按钮和它的浮层 |
| Modify `gui/lib/embed/remote_session.dart:48-55` | `_allSent` 去掉提示 |
| Modify `gui/lib/ui/stage.dart:139-160` | 画面上移 |
| Modify `Sources/RappSession/KeyRouting.swift`、`gui/lib/ui/main_window.dart:139-160`、`gui/lib/ui/main_state.dart`、`gui/lib/embed/picture.dart`、`gui/lib/embed/linux_session_port.dart:109-135` | W8 快捷键 Ctrl+Enter |
| Tests | `test/embed/composer_model_test.dart`（改写）、`test/embed/flutter_editor_test.dart`（新）、`test/embed/composer_panel_test.dart`（由 `composer_bar_test.dart` 改名改写）、`test/ui/stage_test.dart`、`test/ui/main_window_test.dart`、`test/ui/main_state_test.dart`、`test/embed/remote_session_test.dart`、`test/embed/linux_session_port_test.dart` |

---

### Task 1: `ComposerEditor` 接口和 `ComposerModel` 的新规则

**Files:**
- Create: `gui/lib/embed/composer_editor.dart`
- Modify: `gui/lib/embed/composer_model.dart`
- Modify: `gui/lib/embed/remote_session.dart:48-55`
- Test: `gui/test/embed/composer_model_test.dart`（改写），`gui/test/embed/remote_session_test.dart`、`gui/test/ui/main_state_test.dart:719-733`（改调用）

**Interfaces:**
- Produces（`composer_editor.dart`）：

```dart
/// What the editor reports; it never carries the text (规格 §5).
class EditorHandlers {
  const EditorHandlers({required this.onChanged, required this.onEnter, required this.onEscape,
      required this.onPaste, required this.onFocus});
  final VoidCallback onChanged;   // the text changed (no text attached)
  final VoidCallback onEnter;     // plain Enter, not while composing
  final VoidCallback onEscape;    // Esc, not while composing
  final VoidCallback onPaste;     // ⌘V (macOS) — the runner decides what it becomes
  final void Function(bool on) onFocus;
}

class EditorStyle {
  const EditorStyle({required this.text, required this.color, required this.hintColor, required this.cursor});
  final TextStyle text;   // size 15, height 22/15, theme font, shadows: []
  final Color color, hintColor, cursor;
}

abstract class ComposerEditor {
  /// Set by the panel before the first [view].
  EditorHandlers? handlers;
  /// The editing area; grows from one line (48) up to [maxHeight], then scrolls.
  Widget view(BuildContext context, {required EditorStyle style, required String hint, required double maxHeight});
  void focus();
  void unfocus();
  /// Replaces all text, caret at the end. While composing: applied after the commit.
  void setText(String text);
  /// At the caret (replacing a selection). While composing: applied after the commit.
  void insert(String text);
  /// A copy of the whole text.
  Future<String> read();
  /// The whole text; the editor is empty afterwards.
  Future<String> take();
  void dispose();
}
```

- Produces（`composer_model.dart`，`ComposerModel` 的新公开面；`controller`、`text`、`send()`、`esc()`、`insertText()` 都去掉）：

```dart
sealed class Submit {}
class SubmitNothing extends Submit {}                          // sending, or an empty Enter within 1 s (W15)
class SubmitReturn extends Submit {}                           // empty: a Return for A
class SubmitPieces extends Submit { final List<Map<String, Object>> pieces; }

class Outgoing {
  final List<BlockChip> blocks; final String text;
  int sent;          // pieces that went (blocks first, then text)
  String? failure;   // null while in flight
  List<Map<String, Object>> remaining();  // pieces() minus the first [sent]
}

ComposerModel({this.onDrop, this.onAllSent, DateTime Function()? clock});
String draft;                          // the text while no editor is attached; the last copy otherwise
void attach(ComposerEditor e);         // e.setText(draft)
Future<void> detach(ComposerEditor e); // draft = await e.read(); no-op if e is not the attached one
void setDraft(String s);               // into the editor if attached, else draft
void editorChanged();                  // restarts a 1 s timer; then draft = await editor.read()
bool editorFocused;                    // set by the panel from onFocus
Future<Submit> submit();
Outgoing? get inFlight;
List<Outgoing> get failed;
List<Map<String, Object>>? retry(Outgoing o);  // null while sending; else o becomes in flight
void putBack(Outgoing o);
void collapse();                       // open = false (W6: text kept)
void insert(String s);                 // editor.insert, or appended to draft
void releaseFocus();                   // bumps releaseTick; the panel unfocuses the editor (W8)
int releaseTick;
// kept: open, blocks, sending, status, focusTick, wantFocus(), setSending(), done(), copyPressed(),
//       clipArrived(), apply(), removeBlock(), note(), dispose()
```

- [ ] **Step 1: 改写 `composer_model_test.dart`，写失败的测试**

用一个测试里的 `FakeEditor implements ComposerEditor`（字段 `String value`，`take()` 返回并清空，`read()` 返回 `value`）和可调的 `clock`。保留旧文件里块顺序、复制、`apply`、`removeBlock`、`onAllSent` 的测试，按新接口改写；删掉 `esc clears text, then collapses`、`done keeps the cursor and composing range…`、`done clears what was sent if unchanged, else notes`。新增：

```dart
test('submit takes the text: blocks first, then text; the editor is empty', () async {
  m.apply(const PasteResult(blocks: [BlockChip(1, '图片 #1')]));
  ed.value = 'hi';
  final s = await m.submit() as SubmitPieces;
  expect(s.pieces, [{'block': 1}, {'text': 'hi'}]);
  expect(ed.value, '');
  expect(m.blocks, isEmpty);
  expect(m.inFlight!.text, 'hi');
  expect(m.sending, isTrue);
});
test('submit while sending takes nothing', () async {
  ed.value = 'a'; await m.submit();
  ed.value = 'b';
  expect(await m.submit(), isA<SubmitNothing>());
  expect(ed.value, 'b');
});
test('an empty submit is a Return, except within 1 s of a send (W15)', () async {
  ed.value = 'a'; await m.submit(); m.done(1, null);
  now = now.add(const Duration(milliseconds: 900));
  expect(await m.submit(), isA<SubmitNothing>());
  now = now.add(const Duration(milliseconds: 200));
  expect(await m.submit(), isA<SubmitReturn>());
  expect(m.status, isNull); // W11: no 「已给远端发回车」
});
test('done with everything sent drops the item and its blocks', ...);   // onDrop(1) called, inFlight null, failed empty
test('a partial send keeps the rest as a failed item; retry sends the rest', () async {
  // blocks 1, 2 + text 'x'; done(1, 'A 上贴不进去') → failed.single.failure == 'A 上贴不进去',
  // onDrop called for 1 only; retry(failed.single) == [{'block': 2}, {'text': 'x'}]; sending true
});
test('a link drop keeps the text as a failed item', () async {
  ed.value = '长文'; await m.submit(); m.done(0, null);
  expect(m.failed.single.failure, '没有发出去');
  expect(m.failed.single.text, '长文');
});
test('a cancelled send (empty failure) is a failed item saying 已取消', ...);
test('putBack: text into the editor at the caret, unsent blocks back in front', () async {
  // failed item with block 2 and text 'x'; m.blocks has block 3; putBack → ed.inserted == ['x'],
  // [for (b in m.blocks) b.n] == [2, 3], failed empty
});
test('retry is null while sending', ...);
test('collapse closes and keeps the text', () { ... expect(m.open, isFalse); expect(ed.value, 'keep'); });
test('detach reads the draft; attach puts it back', () async {
  ed.value = '草稿'; await m.detach(ed); expect(m.draft, '草稿');
  final ed2 = FakeEditor(); m.attach(ed2); expect(ed2.value, '草稿');
});
test('insert without an editor appends to the draft', () { m.draft = 'a'; ...detached...; m.insert('b'); expect(m.draft, 'ab'); });
test('a change is copied into the draft 1 s after the last one', () {
  fakeAsync((fa) { m.attach(ed); ed.value = 'x'; m.editorChanged(); fa.elapse(const Duration(milliseconds: 900));
    expect(m.draft, ''); ed.value = 'xy'; m.editorChanged(); fa.elapse(const Duration(seconds: 1)); fa.flushMicrotasks();
    expect(m.draft, 'xy'); });
});
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/composer_model_test.dart`
Expected: 编译失败（`ComposerEditor`、`submit` 未定义）

- [ ] **Step 3: 实现 `composer_editor.dart` 和新的 `ComposerModel`**

失败原因的文字：`done(n, failure)` 中 `failure` 非空非 `''` 原样用；`''` 用 `已取消`；`null` 而且还有没发的部分用 `没有发出去`。`setSending(false)` 在有 `inFlight` 时照旧不生效（等 `done`）。块在 `done` 里按实际发出的数量逐个 `onDrop`；`putBack` 和没发出的块在用户 `removeBlock` 或会话结束前一直留在 runner 里。`dispose` 取消 1 秒的定时器。

`remote_session.dart` 的 `_allSent`：只保留 `if (profile.afterSend == AfterSend.pressReturn) onReturn?.call();`，两句 `composer.note(...)` 删掉（W11）。

- [ ] **Step 4: 改掉别处对旧接口的调用**

`test/embed/remote_session_test.dart:243-262`、`test/ui/main_state_test.dart:719-733`：`rs.composer.text = 'ls'; rs.composer.send();` 改成挂一个 `FakeEditor`（放进 `test/fakes.dart` 共用）后 `ed.value = 'ls'; await rs.composer.submit();`，原来断言的行为不变（afterSend 的回车只在整轮发完后按一次）。

- [ ] **Step 5: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/composer_model_test.dart test/embed/remote_session_test.dart test/ui/main_state_test.dart`
Expected: PASS（`composer_bar.dart` 和它的测试此时编译不过是预期的，Task 3 替换掉它们；这一步只跑这三个文件）

- [ ] **Step 6: Commit**

```bash
git add gui/lib/embed/composer_editor.dart gui/lib/embed/composer_model.dart gui/lib/embed/remote_session.dart gui/test/embed/composer_model_test.dart gui/test/embed/remote_session_test.dart gui/test/ui/main_state_test.dart gui/test/fakes.dart
git commit -m "feat(gui): composer model takes the text from an editor; failed sends stay as items"
```

---

### Task 2: `FlutterEditor`

**Files:**
- Create: `gui/lib/embed/flutter_editor.dart`
- Test: `gui/test/embed/flutter_editor_test.dart`

**Interfaces:**
- Consumes: `ComposerEditor`、`EditorHandlers`、`EditorStyle`（Task 1）
- Produces: `class FlutterEditor implements ComposerEditor`，`FlutterEditor()`；`view` 返回一个带 `Key('composer-field')` 的 `TextField`

- [ ] **Step 1: 写失败的测试**

挂在 `wrap(SizedBox(width: 700, child: Builder(builder: (c) => ed.view(c, style: ..., hint: '写给 Safari', maxHeight: 200))))` 上，`handlers` 记录调用次数：

```dart
testWidgets('Enter reports, Shift+Enter is a newline, both stay with the IME while composing', ...);
  // composing 'ni' (TextRange 0..2) + Enter → onEnter 0 次；Esc → onEscape 0 次
  // plain 'a' + Shift+Enter → read() == 'a\n'，onEnter 0 次；Enter → onEnter 1 次
testWidgets('Esc reports and never reaches a CallbackShortcuts Esc above', ...); // onEscape 1, outer 0
testWidgets('⌘V reports a paste and inserts nothing itself', ...);               // macOS only: skip: !Platform.isMacOS
testWidgets('a tap while composing cannot move the caret', ...);                  // 旧 composer_bar_test 143 行那条搬过来
testWidgets('insert while composing waits for the commit', (tester) async {
  // composing 'ni'; ed.insert('X') → text 仍是 'ni'；提交组字为 '你'（composing 变空）→ read() == '你X'
});
testWidgets('one line is 48 high; many lines stop at maxHeight and scroll', (tester) async {
  // 空：getSize(find.byKey(Key('composer-field'))).height == 48
  // setText(40 行) → 高度 == 200
});
testWidgets('the hint shows while empty; no text glow under MATRIX', ...);
  // find.text('写给 Safari')；TextField 的 style.shadows 为空
testWidgets('focus and changes are reported', ...);                               // focus() → onFocus(true)；打字 → onChanged
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/flutter_editor_test.dart`
Expected: FAIL（`FlutterEditor` 未定义）

- [ ] **Step 3: 实现 `FlutterEditor`**

自己持有 `TextEditingController` 和 `FocusNode`。按键处理照搬 `composer_bar.dart:93-118` 的 `_onKey`，但只调 `handlers`，不做发送、不清空。`TextField`：`minLines: 1`、`maxLines: null`、`keyboardType: TextInputType.multiline`、`InputDecoration.collapsed(hintText: hint)`，竖直内边距让一行正好 48（22 + 13 + 13），外面套 `ConstrainedBox(maxHeight: maxHeight)`。组字期间的 `setText`/`insert` 存进一个待办，controller 的 composing 变空时依次执行。`read`/`take` 用 `SynchronousFuture`。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/flutter_editor_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add gui/lib/embed/flutter_editor.dart gui/test/embed/flutter_editor_test.dart
git commit -m "feat(gui): FlutterEditor behind the ComposerEditor interface"
```

---

### Task 3: `ComposerPanel` 和 `composerLayer`

**Files:**
- Delete: `gui/lib/embed/composer_bar.dart`、`gui/test/embed/composer_bar_test.dart`
- Create: `gui/lib/embed/composer_panel.dart`、`gui/test/embed/composer_panel_test.dart`
- Modify: `gui/lib/ui/stage.dart:4`（import）、`gui/test/ui/main_window_test.dart:534-541`

**Interfaces:**
- Consumes: Task 1 的 `ComposerModel`（`attach`、`detach`、`submit`、`inFlight`、`failed`、`retry`、`putBack`、`collapse`、`editorChanged`、`editorFocused`、`focusTick`、`releaseTick`）；Task 2 的 `FlutterEditor`
- Produces:
  - `double panelWidth(double stageWidth)` — W1
  - `class ComposerPanel extends StatefulWidget`，`ComposerPanel({super.key, required MainState state, required RemoteSession session, required SessionPort port, required double maxHeight, ComposerEditor Function()? editor})`；`editor` 默认 `FlutterEditor.new`（S2 在这里换成 macOS 的实现）；顶层 `Key('composer-panel')`；发送按钮 `Key('composer-send')`
  - `List<Widget> composerLayer({required MainState state, required RemoteSession session, required SessionPort port})` — 签名不变
  - 「＋」的位置留一个 `Key('composer-plus')` 的 48×48 占位按钮，Task 4 换成真的

- [ ] **Step 1: 写失败的测试**

`composer_panel_test.dart` 从旧 `composer_bar_test.dart` 拿 `setUp`、`openEmbedded`、`showPicture`、`mainLike` 这些辅助。测试（`ComposerBar` 全改成 `ComposerPanel`，`find.byType(TextField)` 照用）：

```dart
test('panelWidth is 720, or the stage less 16 below 736', () {
  expect(panelWidth(1200), 720); expect(panelWidth(736), 720); expect(panelWidth(700), 684);
});
testWidgets('open: one line, 720 wide, centred, 8 above the stage bottom', ...);
  // Stage 1000×700：getSize(Key('composer-panel')) == Size(720, 48 + 边框)；中心 x == 500；底边 == 692
testWidgets('long text grows upward to half the stage, bottom and width fixed', ...);
  // setDraft(40 行) → 面板高度 ≤ 350；底边、宽度不变
testWidgets('Enter sends and the box stays, one line, caret inside (W7)', ...);
  // 打 'a' + Enter → composer_send pieces [{'text':'a'}]；编辑区空；高度回到一行；编辑区仍有焦点；出现「发送中」
testWidgets('a send switches A to English first; an empty Enter presses Return', ...); // 旧测试改写，去掉「已给远端发回车」断言，改为 find.text('已给远端发回车') findsNothing
testWidgets('an empty Enter right after a send does nothing (W15)', ...);
testWidgets('Esc collapses and keeps the text (W6); the window Esc never sees it', ...);
  // 打 'keep' + Esc → 面板消失，escs == 0；再点「输入」→ 编辑区是 'keep'
testWidgets('a failed send offers retry and put back', ...);
  // done(0,'A 上贴不进去') → find.text('A 上贴不进去')；点「放回输入框」→ 编辑区回到原文；
  // 另一次失败后点「重试」→ 第二次 composer_send 是剩下的 pieces
testWidgets('drafts stay with their session across a switch', ...);
  // 会话 1 打 'one'，切到会话 2（Stage 换 currentRemote）打 'two'，切回 → 'one'；会话 2 的 draft == 'two'
testWidgets('tapping a block removes it; blocks sit above the text inside the box', ...);
testWidgets('the hint is 写给 <app>', ...);                     // find.text('写给 Safari')
testWidgets('send and plus stay at the bottom right when tall (W13)', ...); // 多行时两个按钮的底边 == 框底边 - 内边距
// 旧测试保留并改名：opening takes the caret from the picture；a clip insert focuses the field, even over
// a focused picture；a clip insert opens the composer with it；no 「输入」 button and no panel while
// composerAllowed is false；the upload strip stays while composerAllowed is false；Esc and Enter while
// composing stay with the input method；opening the composer does not resize A（「收起」改成按 Esc）
```

`main_window_test.dart` 加一条 `testWidgets('in fullscreen the panel is there; Esc in it collapses the panel and stays fullscreen', ...)`：`fs` 设成全屏，打开面板，编辑区里按 Esc → 面板消失，`fs` 没收到 `setFullScreen(false)`；再按 Esc（焦点已不在编辑区）→ 退出全屏。分离窗口里没有面板（规格 §2，用户 2026-11-14 定）。

`main_window_test.dart:534-541`：`composer.text = 'draft text'` 改成 `composer.draft = 'draft text'`，断言读编辑区（`tester.widget<TextField>(...).controller!.text`）。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/composer_panel_test.dart`
Expected: FAIL（`ComposerPanel` 未定义）

- [ ] **Step 3: 实现 `composer_panel.dart`，删掉 `composer_bar.dart`**

- `initState`：建编辑区、设 `handlers`、`model.attach`、下一帧取焦点（照旧 `_takeCaret`）。`dispose`：`model.detach(ed).whenComplete(ed.dispose)`（Review Focus 1：先读草稿再放掉）。
- `handlers`：`onChanged → model.editorChanged()`；`onEnter → _submit()`；`onEscape → model.collapse()`；`onPaste → model.apply(await port.composerPaste(sid))`；`onFocus(on) → model.editorFocused = on; if (on) state.blurPicture()`。
- `_submit()`：`switch (await model.submit())`，`SubmitPieces` → `session.prepareInput(); port.composerSend(sid, pieces)`；`SubmitReturn` → `session.pressReturn()`。发送按钮同样调 `_submit()`，`model.sending` 时禁用。
- `focusTick` 变 → `ed.focus()`；`releaseTick` 变 → `ed.unfocus()`。
- 布局，从上到下：发件项（`inFlight` 一行「发送中」+ 文字第一行；每个 `failed` 一行：原因 + `重试` + `放回输入框`），提示行（Task 4 填内容，这里先留 `SizedBox.shrink()` 的位置），框。框：`t.panelBox()`，`Row(crossAxisAlignment: end)`：`Expanded(Column(块 Wrap（仍用 `DashedOutline`，点一下 `removeBlock`），编辑区 view))`、「＋」占位、发送（`RappButton.primary`，48×48，图标 `Icons.arrow_upward`，`Semantics(label: '发送')`）。编辑区 `maxHeight` = `widget.maxHeight` 减去块那一排和内边距后的余量，至少 48。
- `EditorStyle`：`TextStyle(fontSize: 15, height: 22 / 15, fontFamily: t.font, color: t.text, shadows: const [])`。
- `composerLayer`：面板那一层改成 `Positioned.fill(child: LayoutBuilder(c → Align(bottomCenter, Padding(bottom: 8, SizedBox(width: panelWidth(c.maxWidth), child: ComposerPanel(key: ValueKey(session.sid), ..., maxHeight: c.maxHeight / 2))))))`；右下角「输入」按钮和上传条那一层不变。
- 「收起」按钮从框里去掉（Task 4 放进「＋」）；`RemoteImeChip` 先删掉，Task 4 的提示行接替它。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/ test/ui/main_window_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A gui/lib/embed/composer_panel.dart gui/lib/embed/composer_bar.dart gui/lib/ui/stage.dart gui/test/embed/composer_panel_test.dart gui/test/embed/composer_bar_test.dart gui/test/ui/main_window_test.dart
git commit -m "feat(gui): writing panel replaces the composer bar"
```

---

### Task 4: 「＋」浮层和提示行

**Files:**
- Create: `gui/lib/embed/composer_plus.dart`
- Modify: `gui/lib/embed/composer_panel.dart`（换掉「＋」占位，填提示行）
- Test: `gui/test/embed/composer_panel_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `ComposerPanel`；`port.composerAttach`、`port.key`、`port.cancelTransfer`；`session.inputSource`、`session.selectInput`；`model.copyPressed`、`model.collapse`
- Produces: `class ComposerPlus extends StatefulWidget`，`ComposerPlus({required RemoteSession session, required SessionPort port, required VoidCallback onAttach})`；按钮 `Key('composer-plus')`，浮层 `Key('composer-plus-menu')`；`const composerKeys`（顺序改成 W9 的顺序，常量名不变）

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('plus opens a menu above it: 附件…, 在远端复制, the keys, 收起', ...);
  // 点 composer-plus → composer-plus-menu 出现，它的底边在 composer-plus 的顶边之上，右边对齐；
  // find.text('附件…')、find.text('也可以直接粘贴')、find.text('在远端复制')、find.text('按键 · 直接发给远端')、find.text('收起')
testWidgets('keys go to A in W9 order; ⌘ sticks for one key; the menu stays open', ...);
  // 依次点 ⌘、Tab → key {keyCode 48, modifiers commandBit}；再点 Tab → modifiers 0；菜单仍在
testWidgets('在远端复制 sends ⌘C and the hint line says 已复制', ...); // key {keyCode 8, modifiers commandBit}
testWidgets('附件… asks the runner and the menu closes', ...);
testWidgets('收起 closes the panel and keeps the text', ...);
testWidgets('a tap outside closes the menu without reaching A', ...); // 点画面：菜单关闭，没有 mouse 调用
testWidgets('the sticky keys and the menu never carry over to another session', ...); // 旧测试 250 行改写
testWidgets('hint line: A on an input method, accent, a tap switches to English', ...);
  // InputSourceEvent(1,'im','拼音',false) → 提示行出现「远端在用输入法 拼音，发送前会切到英文 · 点按现在就切」；
  // 点它 → select_input {'sid':1,'id':''}；InputSourceEvent ascii → 这一句消失
testWidgets('hint line: an upload shows its progress with 取消', ...);   // 旧测试 308 行改写
testWidgets('hint line is gone when nothing is going on', ...);          // 没有 status、transfer、输入法时找不到 Key('composer-hint')
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/composer_panel_test.dart`
Expected: FAIL（新测试找不到菜单和提示行）

- [ ] **Step 3: 实现**

- 浮层：`OverlayPortal` + `CompositedTransformTarget/Follower`，`targetAnchor: Alignment.topRight`、`followerAnchor: Alignment.bottomRight`，上下留 8；外面 `TapRegion(onTapOutside: close)`，按钮和浮层在同一个 `groupId`。宽 300，`t.panelBox()`，内边距 8，行间 6：两行 48 高的 `附件…` / `在远端复制`（右侧小字用 `t.muted`），分组标题，5 列 44 高的按键格，最后一行 48 高的 `收起`。按键和粘住的逻辑从 `composer_bar.dart:145-158` 搬过来。浮层里任何按下先 `state.blurPicture()`（照旧 R24）。
- 提示行 `Key('composer-hint')`，和框同宽，只在 `model.status`、`session.transferStatus`、`inputSource != null && !ascii` 任一存在时出现：左边是状态或输入法那一句（输入法那一句用 `t.accent`、加粗，可点），右边是上传进度和 `取消`。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/composer_panel_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add gui/lib/embed/composer_plus.dart gui/lib/embed/composer_panel.dart gui/test/embed/composer_panel_test.dart
git commit -m "feat(gui): writing panel plus menu and hint line"
```

---

### Task 5: 打开时画面上移 64

**Files:**
- Modify: `gui/lib/ui/stage.dart:139-160`
- Test: `gui/test/ui/stage_test.dart`（或 `composer_panel_test.dart` 里用 `Stage` 的那组）

**Interfaces:**
- Consumes: `session.composer.open`、`session.composerAllowed`
- Produces: `const pictureLift = 64.0`（`composer_panel.dart`）

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('opening lifts the picture 64 and closing puts it back; A is never resized', ...);
  // Stage 800×600，画面已显示；记下 getTopLeft(find.byType(Picture)).dy = y0，清掉 resize 调用；
  // 点「输入」，pumpAndSettle → dy == y0 - 64；stage 尺寸不变；Esc 收起，pumpAndSettle → dy == y0；
  // 全程没有 resize 调用
testWidgets('growing does not move the picture further (W4)', ...);  // setDraft 10 行后 dy 仍是 y0 - 64
testWidgets('the lift is at most 0.15 s, and instant with reduced motion', ...);
  // pump(150ms) 后已到位；wrap(disableAnimations: true) 时一次 pump 就到位
testWidgets('a click on the lifted picture lands where it is seen', ...);
  // 打开后点 Picture 可见区域的中心 → 'mouse' down 调用的坐标 == A 窗口内容的中心（和不上移时点中心的结果相同）
testWidgets('no lift over a detached placeholder', ...);
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/stage_test.dart`
Expected: FAIL（dy 没变）

- [ ] **Step 3: 实现**

`Stage` 里 `stage` 那个 `Container` 外面包一层 `ClipRect(child: ListenableBuilder(listenable: Listenable.merge([rs, rs.composer]), builder: … TweenAnimationBuilder<double>(tween: Tween(end: lifted ? pictureLift : 0), duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150), curve: Curves.easeOut, builder: (_, v, child) => Transform.translate(offset: Offset(0, -v), child: child))))`，`lifted = picture && rs.composer.open && rs.composerAllowed`。`state.stageSize(c.biggest)` 保持在外面，用的仍是没平移的尺寸。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/stage_test.dart test/embed/composer_panel_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add gui/lib/ui/stage.dart gui/lib/embed/composer_panel.dart gui/test/ui/stage_test.dart
git commit -m "feat(gui): the picture moves up one line while the writing panel is open"
```

---

### Task 6: 快捷键 Ctrl+Enter（W8）

所有平台都是 Ctrl+Enter（macOS 上是 ⌃↩），用户 2026-11-14 定。代价用户知道：macOS 上远端收不到 ⌃↩，Linux 上远端收不到 ⌘↩（Linux 的 Ctrl 对应远端的 ⌘）。Return（36）和小键盘 Enter（76）都算。

**Files:**
- Modify: `Sources/RappSession/KeyRouting.swift`（⌃↩ 留在 rapp）
- Modify: `gui/lib/ui/main_state.dart`（加 `composerKey`）
- Modify: `gui/lib/ui/main_window.dart:139-160`（绑定）
- Modify: `gui/lib/embed/flutter_editor.dart`（Ctrl+Enter 不当发送、不换行，往上交）
- Modify: `gui/lib/embed/picture.dart`（跟着 `state.pictureFocused` 取焦点）
- Modify: `gui/lib/embed/linux_session_port.dart:109-135`（Ctrl+Enter 不发给 A）
- Test: `Tests/RappSessionTests/KeyRoutingTests.swift`、`gui/test/ui/main_window_test.dart`、`gui/test/ui/main_state_test.dart`、`gui/test/embed/flutter_editor_test.dart`、`gui/test/embed/linux_session_port_test.dart`

**Interfaces:**
- Consumes: `composer.open`、`composer.wantFocus()`、`composer.editorFocused`、`composer.releaseFocus()`（Task 1）
- Produces: `void MainState.composerKey()`

- [ ] **Step 1: 写失败的测试**

```swift
// KeyRoutingTests
func testControlReturnStaysLocal() {
    XCTAssertEqual(routeKey(keyCode: 36, flags: [.control], pictureFocused: true), .local)
    XCTAssertEqual(routeKey(keyCode: 76, flags: [.control], pictureFocused: true), .local)
    XCTAssertEqual(routeKey(keyCode: 36, flags: [], pictureFocused: true), .remote)        // plain Return goes to A
    XCTAssertEqual(routeKey(keyCode: 36, flags: [.command], pictureFocused: true), .remote) // ⌘↩ goes to A
    XCTAssertEqual(routeKey(keyCode: 36, flags: [.control, .shift], pictureFocused: true), .remote)
}
```

```dart
// main_state_test
test('composerKey: closed → open with the caret; picture → caret; editor → picture, panel stays', ...);
  // 1) open false → open true，focusTick +1
  // 2) open，editorFocused false → focusTick +1，open 不变
  // 3) editorFocused true，画面在舞台上 → releaseTick +1，pictureFocused == sid，open 仍是 true
test('composerKey does nothing without a session or when composerAllowed is false', ...);
// main_window_test
testWidgets('Ctrl+Enter opens the panel and moves the caret back and forth', ...);
  // sendKeyDownEvent(controlLeft) + enter，三次依次：面板出现且编辑区有焦点 → 焦点到画面（Picture 的 Focus 有焦点，
  // port 收到 picture_focus {'sid':1}）→ 编辑区又有焦点；编辑区里没有多出换行，也没有 composer_send
// flutter_editor_test
testWidgets('Ctrl+Enter is neither a send nor a newline', ...);  // onEnter 0 次，read() 不变，事件没被编辑区处理
// linux_session_port_test
test('Ctrl+Enter is rapp\'s: not sent to A', ...);  // 画面有焦点时 handleKeyEvent(Ctrl+Enter) == false，没有 key 消息；
                                                   // Ctrl+J、Shift+Enter、Enter 照旧发
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter KeyRoutingTests`，再 `cd gui && ~/development/flutter/bin/flutter test test/ui/main_state_test.dart test/ui/main_window_test.dart test/embed/flutter_editor_test.dart test/embed/linux_session_port_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**

- `KeyRouting.swift` 的 `routeKey`：`mods == [.control] && (keyCode == 36 || keyCode == 76)` 时 `.local`；文档注释里的保留组合加上 ⌃↩。`KeyTracker` 照旧会先把 A 上按着的 ⌃ 放开。
- `MainState.composerKey()`：`final rs = currentRemote;` 为空或 `!rs.composerAllowed` 返回；三种情况照测试。第三种只在画面在舞台上（`!rs.detached`）时执行，否则只 `releaseFocus()`。
- `main_window.dart`：`SingleActivator(LogicalKeyboardKey.enter, control: true, includeRepeats: false)` 和 `numpadEnter` 同样一条 → `state.composerKey`，所有平台一样。
- `flutter_editor.dart`：按键处理里 Ctrl（不带其他修饰键）+ Enter 返回 `KeyEventResult.ignored`，排在 Enter 和 Shift+Enter 的判断之前，让它交给上面的快捷键。
- `picture.dart`：`build` 里当 `state.pictureFocused == _sid && !_focus.hasFocus` 时，下一帧 `_focus.requestFocus()`。
- `linux_session_port.dart` 的 `handleKeyEvent`：只按着 Ctrl、`logicalKey` 是 `enter` 或 `numpadEnter` 时返回 `false`。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test --filter KeyRoutingTests`，再 `cd gui && ~/development/flutter/bin/flutter test`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RappSession/KeyRouting.swift Tests/RappSessionTests/KeyRoutingTests.swift gui/lib/ui/main_state.dart gui/lib/ui/main_window.dart gui/lib/embed/flutter_editor.dart gui/lib/embed/picture.dart gui/lib/embed/linux_session_port.dart gui/test/ui/main_state_test.dart gui/test/ui/main_window_test.dart gui/test/embed/flutter_editor_test.dart gui/test/embed/linux_session_port_test.dart
git commit -m "feat: Ctrl+Enter opens the writing panel and moves the caret between it and the picture"
```

---

### Task 7: 跟着改的文档和全量验证

**Files:**
- Modify: `docs/superpowers/specs/2026-11-14-rapp-composer-writing-panel-design.md`（状态改成「已确认（用户 2026-11-14：「开始实现」）；S1 已实现」）
- Modify: `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md` §3.5、§5 第 1 条（「浮层只盖不挤」→「浮层不改变舞台大小」，注明输入区打开时画面上移一行、A 的尺寸不变）
- Modify: `docs/superpowers/specs/2026-11-12-rapp-s2-embedded-stage-design.md` §2.5
- Modify: `docs/superpowers/specs/2026-11-12-rapp-design-language.md` §8（加「写作面板」一条：720 宽、一行 48、字号 15 行高 22、「＋」浮层 300 宽）
- Modify: `docs/superpowers/specs/2026-11-13-rapp-product-decisions.md` PD6 和待定清单第 13 条（Sumi 先不用在输入区，留 `ComposerEditor` 这道缝）
- Modify: `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md` §13（输入区行为跟着写作面板规格）
- Modify: `tasks/todo.md`（加写作面板一节：S1 完成和待实机的几条；S0、S2、S3 未做）

- [ ] **Step 1: 改上面的文档**，每处一两句，指向写作面板规格的条目号（W1–W16）。

- [ ] **Step 2: 全量验证**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`，然后 `git checkout gui/pubspec.lock`
Expected: analyze 输出 `No issues found!`；test 末行 `All tests passed!`

- [ ] **Step 3: Commit**

```bash
git add docs tasks/todo.md
git commit -m "docs: writing panel S1 in the main window, stage, design language and decision docs"
```

待实机（写进 `tasks/todo.md`，不在本计划里验收）：在真实 app 上看画面上移 64 碍不碍事（规格评审 U1）；中文输入法下打字、组字时点击。
