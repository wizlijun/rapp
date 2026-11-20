# 长语音先让 AI 整理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A voice send or edit longer than 10 characters first goes through the gateway's `dictation`, with a card that lets the user send or edit the original at any time, and the record notes the AI and keeps the original.

**Architecture:** `VoiceHold._release` hands long text to a per-session `VoiceTidy` (owned by `MainState`, keyed by sid, moved on reconnect). `VoiceTidy` runs `LlmApi.run('dictation')` and then sends or edits through callbacks that `MainState` wires to `sendVoice` / `composer.keep`. The AI origin rides on `Outgoing.voice` into `InputRecorder`, which writes `source` and `ai`. A shared `VoiceTidyCard` sits in `composerLayer`.

**Tech Stack:** Flutter/Dart only (gui/). No native, Rust or protocol change.

**Spec:** `docs/superpowers/specs/2026-11-20-rapp-voice-ai-tidy-design.md`

## Global Constraints

- Flutter: `~/development/flutter/bin/flutter` (not on PATH). Run tests from `gui/`; after each run, `git checkout pubspec.lock`.
- Threshold: `text.replaceAll(RegExp(r'\s'), '').runes.length > 10`.
- Gateway app: `dictation`. Overall cap 30 s from the start of the tidy. `LlmApi.run` keeps its own `firstByte` (10 s, so headers wait up to 15 s).
- Only `LlmDone` with a non-blank text replaces the original. A blank one is a failure with reason `AI 没有给出结果`. The overall cap failure reason is `LLM 没有及时回应`.
- UI copy, exactly:
  - card titles `AI 整理中…` and `AI 整理失败`; buttons `编辑` and `直接发送`
  - note after an auto-send `已用 AI 整理` (1.5 s); other notes (`voiceBlocked`, `voiceBusy`) 2 s
  - switch `长语音先让 AI 整理`, note `超过 10 个字时，先用 LLM 接入点整理再发`
  - history badge `AI`; menu items `原话放进输入框`, `复制原话`
- Never log text content. A log line carries the app, the result kind or `LlmFailed.log`, and the elapsed ms.
- The key stays only in `local/llm.json`. No key in tests, docs or commits.
- Work on branch `feat/llm-endpoint` in `/Users/bruce/git/rapp-llm-endpoint`. Never commit to main.
- End commits with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A reconnect while tidying.** The tidy and its card move to the new sid, and the result goes to the new session. → Task 4, test `reconnect moves the tidy to the new session`.
2. **The window closes while tidying.** The original ends up in that session's draft before the session's draft record is written. → Task 4, test `closing the session keeps the original in its draft record`.
3. **A new press while a failure card waits.** The original goes to the draft, nothing is sent, and the new hold works normally. → Task 3, test `interrupt while failed keeps the original, sends nothing`.
4. **Focus is on a password field.** No request goes to the gateway; the text is sent as before. → Task 4, test `a secure focus skips the tidy`.
5. **The session is busy or blocked when the AI result arrives.** The AI text goes to the draft, `pendingAi` is set, and the card shows the hint. → Task 3, test `done while busy keeps the AI text and notes the hint`; Task 1, test `sendVoice keeps AI text with pendingAi when blocked`.

---

### Task 1: The AI origin on sends and records

**Files:**
- Modify: `gui/lib/embed/composer_model.dart`. Add the classes near `Outgoing` (:27). Also touch `submitText` (:649), `keep` (:663), the panel submit that builds `Outgoing(parts)` (~:590), `_step` (~:520), `adoptFrom` (:740) and the `draft` setter (:96).
- Modify: `gui/lib/embed/voice_button.dart`, `sendVoice` (:64-90).
- Modify: `gui/lib/history/input_recorder.dart`, `_sentRecord` (:515-535).
- Modify: `docs/superpowers/specs/2026-11-14-rapp-input-history-design.md`, §4: the `source` row (line 85) becomes `typed` | `voice`, plus a new optional `ai` row.
- Test: `gui/test/embed/composer_model_test.dart`, `gui/test/history/input_recorder_test.dart`, `gui/test/embed/voice_button_test.dart`

**Interfaces:**
- Produces (in `composer_model.dart`):
  - `class VoiceAi { const VoiceAi({required String app, required String original, required String result}); Map<String, Object> toJson(); }`. `toJson` gives `{'app','original','result'}`; define `==` and `hashCode`.
  - `class VoiceOrigin { const VoiceOrigin({VoiceAi? ai}); final VoiceAi? ai; }`
  - `Outgoing(List<Object> parts, {bool draftless = false, VoiceOrigin? voice})` with `final VoiceOrigin? voice`.
  - `Submit ComposerModel.submitText(String text, {VoiceOrigin? voice})`
  - `VoiceAi? ComposerModel.pendingAi` (public field)
- Produces (in `voice_button.dart`): `String? sendVoice({required MainState state, required RemoteSession session, required SessionPort port, required String text, VoiceOrigin voice = const VoiceOrigin()})`

Steps:

- [ ] **Step 1: Write the failing tests**
  - composer_model_test:
    - `submitText carries the voice origin`: `submitText('长一点的话', voice: VoiceOrigin(ai: ai))`. The `onSubmitted` `Outgoing` has `voice!.ai == ai` and `draftless` true.
    - `a panel send takes pendingAi once`: set `pendingAi = ai`, set the draft to `'整理后'` and send it from the panel with the file's existing send helper. The `Outgoing` has `voice?.ai == ai`, `pendingAi` is null, and a second send has `voice == null`.
    - `pendingAi goes when the draft is emptied`: `draft = ''` makes `pendingAi` null.
    - `pendingAi goes when ↑ recalls another text`: run `arrow(true)` with a non-empty `recall` and let the step finish. `pendingAi` is null.
    - `adoptFrom carries pendingAi and each row's voice`: the old model has `pendingAi` set and a failed voice row. The new model gets `pendingAi == ai`, and the made row's `voice` is the old row's `voice`.
  - input_recorder_test:
    - `a voice send records source voice`: the record has `source == 'voice'` and no `ai` key.
    - `an AI send records ai`: the record has `source == 'voice'` and `ai == {'app':'dictation','original':'嗯那个我门明天开会','result':'我们明天开会。'}`.
    - `a typed send stays typed`.
  - voice_button_test: `sendVoice keeps AI text with pendingAi when blocked`. When `sendBlocked` is true, `sendVoice(..., voice: VoiceOrigin(ai: ai))` returns `voiceBlocked`, the draft ends with the AI text, and `composer.pendingAi == ai`. Use the file's existing blocked-session setup; if it has none, `voiceBusy` with a busy composer covers the same path.

- [ ] **Step 2: Run them and see them fail**
  - Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/composer_model_test.dart test/history/input_recorder_test.dart test/embed/voice_button_test.dart`
  - Expected: compile errors (`VoiceAi` not defined).

- [ ] **Step 3: Implement**
  - The `draft` setter clears `pendingAi` when the new value is empty. The panel submit reads `pendingAi` into `Outgoing.voice` (`VoiceOrigin(ai: pendingAi)`) before it sets `draft = ''`, then clears it. A draft that only came from `keep` with no `pendingAi` gives `voice: null`; the spec marks only AI-carried panel sends.
  - `_step` clears `pendingAi` when it applies a recalled text.
  - `adoptFrom` does `pendingAi ??= old.pendingAi` and makes rows with `voice: o.voice`. `retry` reuses its row, so nothing changes there.
  - `sendVoice` passes `voice` to `submitText`. Whenever it `keep`s and `voice.ai != null`, it also sets `c.pendingAi = voice.ai`.
  - `_sentRecord` writes `'source': o.voice != null ? 'voice' : 'typed'` and, when `o.voice?.ai` is set, `'ai': ai.toJson()`.
  - Update the input-history spec §4 to match.

- [ ] **Step 4: Run the tests from Step 2.** Expected: PASS. Then run `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with message `feat(voice): 发送和记录带上语音、AI 来源`.

### Task 2: VoiceHold hands long text to a tidy

**Files:**
- Modify: `gui/lib/embed/voice_button.dart`, the `VoiceHold` constructor (:108), `start()` (:182), `_release()` (:296-329)
- Test: `gui/test/embed/voice_button_test.dart`

**Interfaces:**
- Produces: two new optional `VoiceHold` parameters:
  - `bool Function(String text, VoicePick pick)? tidy`: true means it took the text.
  - `VoidCallback? onPress`: called in `start()` right after `_pressed = true`, before `voice.start()`.

Steps:

- [ ] **Step 1: Write the failing tests**
  - `a taken release neither sends nor edits`: `tidy` returns true. `send` and `edit` are not called, `onEnd` gets `VoicePick.send`, `hint` is null, and the language hint is not shown.
  - `a declined release sends as before`: `tidy` returns false, and `send` is called with the text.
  - `tidy gets the edit pick`: release on `VoicePick.edit`, and `tidy` sees `(text, VoicePick.edit)`.
  - `blank text never reaches tidy`: with `stopResult = '  '`, `tidy` is not called and the hint is `voiceBlank`.
  - `a press calls onPress before start`: `onPress` count is 1 and `FakeVoice.starts` is 1, in that order.

- [ ] **Step 2: Run** `flutter test test/embed/voice_button_test.dart`. Expected: FAIL.

- [ ] **Step 3: Implement.** In `_release`, after the `_disposed` check:
  - when `text.trim()` is non-empty, ask `tidy?.call(text, which)`;
  - when it returns true, skip the send/edit branch and the language-hint block;
  - `_end(which)` still runs.

- [ ] **Step 4: Run.** Expected: PASS. Then run `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with message `feat(voice): 松手时可把长文字交给整理`.

### Task 3: VoiceTidy, the state machine

**Files:**
- Create: `gui/lib/embed/voice_tidy.dart`
- Modify: `gui/lib/llm_api.dart`. Add a test seam to `LlmCall`: make `_client` nullable, and add `@visibleForTesting LlmCall.manual()` and `@visibleForTesting void complete(LlmResult r) => _finish(r)`.
- Test: `gui/test/embed/voice_tidy_test.dart` (new)

**Interfaces:**
- Consumes: `VoiceAi`, `VoiceOrigin` (Task 1); `VoicePick` (voice_input.dart); `LlmApi.run`, `LlmCall`, `LlmResult` (llm_api.dart); `voiceBlocked`, `voiceBusy` (voice_button.dart).
- Produces:
  - `enum TidyPhase { idle, tidying, failed, note }`
  - The constructor:

    ```dart
    VoiceTidy({
      required Object sid,
      required LlmEndpoint Function() endpoint,
      required LlmApi api,
      required bool Function(Object sid) allowed,
      required String? Function(Object sid, String text, VoiceOrigin voice) send,
      required void Function(Object sid, String text, VoiceAi? ai) edit,
      required void Function(Object sid, String text) keep,
      Duration overall = const Duration(seconds: 30),
      void Function(String line)? log,
    })
    ```
  - `static bool long(String text)`
  - `bool begin(String text, VoicePick pick)`
  - `void sendOriginal()`, `void editOriginal()`, `void interrupt()`, `void closed()`, `void moveTo(Object sid)`
  - Getters:
    - `Object sid`
    - `TidyPhase phase`
    - `String original`
    - `String shown`: AI text so far; empty until the first chunk.
    - `String? reason`: failed only.
    - `String? note`: note phase only.
    - `VoicePick pick`: the release's pick.

Behaviour (spec §5.2):
- `begin` returns false unless `long(text) && allowed(sid)`. A pending `note` is dropped first.
- `begin` runs `api.run(endpoint(), 'dictation', text.trim(), onText: …)`, enters `tidying` and starts the overall timer.
- `LlmDone(t)` with non-blank `t`:
  - pick `send`: `send(sid, t.trim(), VoiceOrigin(ai: VoiceAi(app: 'dictation', original, result: t.trim())))`. Then the `note` phase with the returned hint, or `已用 AI 整理` when the hint is null.
  - pick `edit`: `edit(sid, t.trim(), thatAi)`, then `idle`.
- `LlmFailed` (or the overall cap) → `failed`, with `reason`. Nothing is sent.
- `sendOriginal`: cancel, then `send(sid, original, const VoiceOrigin())`. A non-null hint becomes a `note`; otherwise `idle`.
- `editOriginal`: cancel, then `edit(sid, original, null)`, then `idle`.
- `interrupt` while `tidying` or `failed`: cancel, then `keep(sid, original)`, then `idle`. While `note`: just `idle`.
- `closed`: as `interrupt`.
- `dispose` cancels the call and the timers.
- `LlmCancelled` is ignored.

Steps:

- [ ] **Step 1: Write the failing tests.** Use `fakeAsync`, and a `_FakeApi extends LlmApi` whose `run` records `(app, input)`, keeps `onText`, and returns an `LlmCall.manual()` the test completes.
  - `long counts non-space characters`:
    - `long('一二三四五六七八九十')` is false;
    - `long('一二三四五六七八九十一')` is true;
    - `long('一 二 三 四 五 六 七 八 九 十')` is false.
  - `short or not allowed is declined`: `begin` returns false and no `run` is made.
  - `done sends the AI text with its origin`:
    - `run` gets `('dictation', original)`;
    - after `complete(LlmDone(' 我们明天开会。 '))`, `send` gets `'我们明天开会。'` and `voice.ai == VoiceAi(app:'dictation', original:…, result:'我们明天开会。')`;
    - phase is `note` and note is `已用 AI 整理`;
    - after 1.5 s, phase is `idle`.
  - `done on edit puts the AI text in the panel`: `edit` gets the AI text and its `VoiceAi`, and phase is `idle`.
  - `partial text shows as it comes`: `onText('我们')`, then `shown == '我们'`, and listeners were notified.
  - `failure stops and waits`: `complete(LlmFailed('连不上 LLM 接入点'))`. Phase is `failed`, reason matches, and nothing was sent after 60 s.
  - `blank done is a failure`: reason is `AI 没有给出结果`.
  - `send original while tidying cancels and sends the original`: the call is `cancelled`, and `send` gets `(original, voice.ai == null)`.
  - `edit original while tidying`: `edit(original, null)` and the call is cancelled.
  - `interrupt while tidying keeps the original, sends nothing`.
  - `interrupt while failed keeps the original, sends nothing`.
  - `the overall cap fails the tidy`: `overall: 30 s`, elapse 30 s. The call is cancelled, phase is `failed`, and reason is `LLM 没有及时回应`.
  - `moveTo sends the result to the new sid`.
  - `closed keeps the original`.
  - `done while busy keeps the AI text and notes the hint`: `send` returns `voiceBusy`, so phase is `note` with note `voiceBusy` and the phase is still `note` 1.9 s later.
  - `log lines carry no text`: no line contains the original or the result.

- [ ] **Step 2: Run** `flutter test test/embed/voice_tidy_test.dart`. Expected: FAIL (file missing).

- [ ] **Step 3: Implement** `voice_tidy.dart` and the `LlmCall` seam.

- [ ] **Step 4: Run** the new test plus `test/llm_api_test.dart`. Expected: PASS. Then run `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with message `feat(voice): 整理语音的状态机 VoiceTidy`.

### Task 4: Wiring in MainState, both voice entries, and the switch

**Files:**
- Modify: `gui/lib/ui/prefs.dart`. Add a `voiceAiTidy` field (`voice_ai_tidy`, default true) in the constructor, `load` and `save`.
- Modify: `gui/lib/ui/main_state.dart`:
  - `setVoiceAiTidy` next to `setTermFit` (:3072).
  - the tidy map.
  - `_dropOld` (:1749).
  - every `remote.remove(…)?.dispose()` site (:1494, :1728, :1920, :2190).
  - the session-end block at :1720 (before `recorder.sessionEnded`).
  - `dispose` (:3727).
- Modify: `gui/lib/embed/voice_desktop.dart:86` and `gui/lib/embed/composer_panel.dart:834`. Pass `tidy:` and `onPress:` to `VoiceHold`.
- Modify: `gui/lib/ui/side_panel.dart:262`. Add the toggle right above `LlmSettingsRow`, on all platforms.
- Modify: the spec §5.2's first paragraph. The tidies live in `MainState`, keyed by sid (one per session, as before; `RemoteSession` has no `MainState`).
- Test: `gui/test/ui/voice_tidy_wiring_test.dart` (new; follow `test/embed/voice_wiring_test.dart`'s `env`, and the reconnect tests near `test/ui/main_state_test.dart:962` for a swap). Also `gui/test/ui/side_panel_test.dart`.

**Interfaces:**
- Consumes: `VoiceTidy` (Task 3); `sendVoice(..., voice:)` and `ComposerModel.pendingAi` (Task 1); `VoiceHold(tidy:, onPress:)` (Task 2).
- Produces:
  - `VoiceTidy MainState.tidyOf(Object sid)` (made on first use)
  - `VoiceTidy? MainState.tidyIfAny(Object sid)`
  - `void MainState.setVoiceAiTidy(bool v)`
  - `bool UiPrefs.voiceAiTidy`

Wiring:
- `allowed`: `(sid) => prefs.voiceAiTidy && llm.configured && !(remote[sid]?.secureFocus ?? true)`.
- `send`: looks up `remote[sid]` and `portOf(sid)`, then calls `sendVoice(..., voice:)`; when either is missing it keeps and returns `voiceBlocked`.
- `edit`: `composer.keep(text)`, `pendingAi = ai`, `open = true`.
- `keep`: `composer.keep(text)`.
- `log`: `debugPrint('voice tidy: …')`.
- `_dropOld`: when `old` has a tidy, dispose any tidy under `fresh`, then `moveTo(fresh)` and re-key it. With no `to`, run `closed()` then `dispose()`.
- Each `remote.remove(sid)?.dispose()`: first `_tidies.remove(sid)?..closed()..dispose()`. At :1720, do this before `recorder.sessionEnded`.
- In both voice entries:
  - `tidy: (t, p) => widget.state.tidyOf(widget.session.sid).begin(t, p)`
  - `onPress: () => widget.state.tidyIfAny(widget.session.sid)?.interrupt()`

Steps:

- [ ] **Step 1: Write the failing tests.** Use a fake `LlmApi` passed as `MainState(llmApi:)`, and `llm` set to a configured endpoint (`setLlm`).
  - `a long voice text goes to the tidy, a short one is sent`: `tidyOf(1).begin(long, VoicePick.send)` is true; with a short text it is false.
  - `done sends to the port with an AI record`: the port sees `composer_send` with the AI text, and the recorder's record has `ai`.
  - `the switch off skips the tidy`: after `setVoiceAiTidy(false)`, `begin` is false, and `gui.json` has `voice_ai_tidy: false` after a reload.
  - `no endpoint skips the tidy`: `begin` is false, and no hint is shown.
  - `a secure focus skips the tidy`.
  - `reconnect moves the tidy to the new session`: begin on the old sid and complete the reconnect swap. `tidyIfAny(old)` is null, `tidyOf(fresh)` is the same object in `tidying`, and done sends on `fresh`.
  - `closing the session keeps the original in its draft record`: begin, then end the session. The recorder's draft record text contains the original.
  - side_panel_test: `the AI tidy switch saves`. Toggle `Key('voice-ai-tidy')` and check that `prefs.voiceAiTidy` flips; the label `长语音先让 AI 整理` shows.

- [ ] **Step 2: Run** both test files. Expected: FAIL.

- [ ] **Step 3: Implement** the wiring above.

- [ ] **Step 4: Run** the new tests, plus `test/embed/voice_wiring_test.dart`, `test/embed/voice_desktop_test.dart` and `test/ui/main_state_test.dart`. Expected: PASS. Then run `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with message `feat(voice): 接上整理：每会话一个、重连跟着走、全局开关`.

### Task 5: The card

**Files:**
- Create: `gui/lib/embed/voice_tidy_card.dart`
- Modify: `gui/lib/embed/composer_panel.dart`. In `composerLayer` (:512), add a `Positioned` layer after the panel's, so it paints above it. Also touch `_VoiceAbovePanel` (:775) for iOS with the panel open.
- Modify: the spec §5.3's desktop bullet. With the panel open, the card stays at the stage row's spot (bottom-right) and paints over the floating panel; the panel floats anywhere, so there is no fixed "above the panel" spot.
- Test: `gui/test/embed/composer_panel_test.dart` (or `voice_desktop_test.dart`, whichever already pumps `composerLayer` with a session)

**Interfaces:**
- Consumes: `MainState.tidyIfAny` / `tidyOf` and `TidyPhase` (Tasks 3–4).
- Produces: `VoiceTidyCard({Key? key, required VoiceTidy tidy})`. Keys:
  - `tidy-card`
  - `tidy-title`
  - `tidy-reason`
  - `tidy-body`
  - `tidy-send`
  - `tidy-edit`
  - `tidy-note`

Layout (spec §5.3):
- `idle` is `SizedBox.shrink()`.
- `tidying`:
  - title `AI 整理中…`;
  - body `shown` when non-empty, else `original` in `t.muted`;
  - at most 4 lines, showing the last 4 (reuse the tail logic of `voice_overlay.dart`'s `_tailOf`).
- `failed`: title `AI 整理失败`, `reason` in the error colour, and the body is `original`.
- Buttons:
  - `RappButton` `直接发送` → `sendOriginal`, and `编辑` → `editOriginal`.
  - Primary is `直接发送`, or `编辑` when `pick == VoicePick.edit`.
- `note`: just the note line (`tidy-note`) in `t.floatBox()`.
- Fade in and out over 160 ms (respect `MediaQuery.disableAnimationsOf`).
- Width is at most 360, and never more than the stage width minus 24.
- Position:
  - Desktop, panel closed: right edge `rowRight` from the stage's right, bottom just above the stage row.
  - Desktop, panel open: at the stage row's spot.
  - iOS: above the stage button stack on `state.stageSide`'s edge; with the panel open, in `_VoiceAbovePanel` above the voice button.
- The other stage buttons stay visible and tappable.

Steps:

- [ ] **Step 1: Write the failing widget tests**
  - `the card shows while tidying and its buttons act`: after `begin`, `tidy-title` reads `AI 整理中…`. Tapping `tidy-send` sends the original (the port sees `composer_send` with it) and the card goes.
  - `failure shows the reason and the original`.
  - `stage buttons stay usable under the card`: tapping `Key('composer-open')` while tidying opens the panel, and the card is still there.
  - `the card shows with the panel open`.
  - `edit pick makes 编辑 primary`: check the `RappButton` kind of `tidy-edit`.

- [ ] **Step 2: Run.** Expected: FAIL.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run** the test file, `test/embed/voice_button_test.dart` and `test/embed/voice_desktop_test.dart`. Expected: PASS. Then run `git checkout pubspec.lock`.

- [ ] **Step 5: Commit** with message `feat(voice): 整理卡片`.

### Task 6: History shows AI and offers the original

**Files:**
- Modify: `gui/lib/history/input_history.dart`. Add a getter on `InputEntry` (:13).
- Modify: `gui/lib/history/history_list.dart`. Add a badge next to the `没发出` one (:283-292), and menu items (:191-219).
- Modify: `tasks/todo.md`. Add real-machine checks under a new heading `长语音先让 AI 整理`:
  1. a long hold on macOS sends tidied text;
  2. 直接发送 while tidying;
  3. gateway down shows the fault and waits;
  4. edit pick opens the panel with AI text;
  5. the iOS card position;
  6. the history row shows AI and ⋮ 原话 works;
  7. a reconnect while tidying.
- Test: `gui/test/history/input_history_test.dart`, `gui/test/history/history_list_test.dart`

**Interfaces:**
- Produces: `String? InputEntry.aiOriginal`. It is `raw['ai']['original']` when that is a String, else null.

Steps:

- [ ] **Step 1: Write the failing tests**
  - `aiOriginal reads the original`: it is null for a record without `ai`, and null when `ai` is not a map.
  - `an AI row shows the AI badge`: there is a `Key('ai-${id}')` with text `AI`, and no badge on a plain row.
  - `the menu puts and copies the original`: `Key('put-original-${id}')` (`原话放进输入框`) calls `onPut` with the original, and `Key('copy-original-${id}')` (`复制原话`) sets the clipboard to the original. Neither item shows on a plain row.

- [ ] **Step 2: Run.** Expected: FAIL.

- [ ] **Step 3: Implement.** The badge uses the draft badge's style. The two items go right under `放进输入框`, and `put-original` follows `w.onPut != null` for `enabled`.

- [ ] **Step 4: Run** both test files. Expected: PASS. Then run `git checkout pubspec.lock`.

- [ ] **Step 5: Final checks.**
  - Run `cd gui && ~/development/flutter/bin/flutter analyze` (clean) and the full `flutter test`. Only the known `linux_detach_test` failures are allowed (environmental: there is no `rust/target/release/rapp-session` in this worktree).
  - Then `git checkout pubspec.lock`.

- [ ] **Step 6: Commit** with message `feat(history): 记录里标出 AI，⋮ 菜单可用原话`.
