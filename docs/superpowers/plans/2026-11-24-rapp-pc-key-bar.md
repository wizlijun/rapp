# PC Key Bar + Phrase Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS and Linux, use iOS's `KeyBar` and `PhraseStrip` in place of `TermKeyRow`. After any hardware key, the bar collapses to ⊙.

**Architecture:** The desktop branch of `composerLayer` gains a full-width bar layer at the stage's bottom. The panel, button row and tidy card stand above it. `stage.dart` lifts the picture by the bar's height on every platform. `TermKeyRow` and the 「按键排」 menu item go away.

**Tech Stack:** Flutter/Dart (`gui/`).

**Spec:** docs/superpowers/specs/2026-11-24-rapp-pc-key-bar-design.md

**Execution:** native (user said 「计划好直接做完」).

## Global Constraints

- iOS behaviour stays the same; `IosDock` is untouched.
- When the bar shows: terminal sessions and terminal apps always (`keyBarWhenClosed`); other apps only while the panel is open.
- Auto-collapse (desktop only):
  - Trigger: a `KeyDownEvent` whose logical key is not a modifier, and with ⌘/Super not held.
  - Effect: sets `prefs.keyBarSlim = true`. Only a mounted `KeyBar` listens.
- `phraseStripShown`: drop the iOS gate. Being slim hides the strip on iOS only.
- Gaps: panel 8 above the bar; button row 12 above the bar.

## Review Focus

1. ⌘Tab, or ⌘ alone → the bar stays expanded.
2. A key-repeat event → does nothing (only a down collapses it).
3. An app session with the panel closed → no bar, and the 「输入」 row sits at 12.
4. A session switch → the old bar's keyboard handler is removed, so no handler leaks.
5. Narrow stage (< 860) → the ⋯ second row raises the picture and the panel by the taller bar.

### Task 1: desktop key bar + auto-collapse

**Files:**
- Modify: `gui/lib/embed/key_bar.dart`
  - `phraseStripShown`.
  - `_KeyBarState` gets a hardware handler on desktop.
  - New `bool collapsesKeyBar(KeyEvent e)`.
- Modify: `gui/lib/embed/composer_panel.dart`
  - Desktop `composerLayer`: drop `keyRow`, add the bar layer and the offsets.
  - `_TidyLayer`: replace `keys` with the bar height.
- Modify: `gui/lib/ui/stage.dart`: `_lifted` with `bar:` on all platforms; the app layer lift without `_ios`.
- Delete:
  - `gui/lib/term/term_key_row.dart`
  - `gui/test/term/term_key_row_test.dart`
  - `RemoteSession.termCtrl`, and its branch in `term_stage.dart`
  - `prefs.termKeyRow`, `setTermKeyRow`, and the stream_menu / top_bar items
- Modify: `gui/lib/ui/side_panel.dart`: the 常用语 row on every platform.
- Tests:
  - `test/embed/key_bar_test.dart` (desktop cases)
  - `test/embed/stage_buttons_test.dart`, `voice_button_test.dart`, `term_main_test.dart`, `prefs_test.dart` (follow the removals)

- [ ] Tests (desktop, `debugDefaultTargetPlatformOverride = macOS`):
  - `desktop terminal layer shows KeyBar full width at the bottom; 输入 sits above it`
  - `a letter key collapses the bar to ⊙; ⊙ expands; ⌘ alone and ⌘-held keys do not`
  - `desktop strip shows while slim; iOS hides it while slim`
  - `desktop app session: no bar while closed, bar while panel open`
- [ ] Implement.
- [ ] Run: `flutter analyze` (expect no issues), and `flutter test` (expect all pass except the environmental `linux_detach_test`).
- [ ] Add a todo.md section with the spec's real-machine checks.
- [ ] Commit.
