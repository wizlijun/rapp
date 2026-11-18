# Controls Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each kind of GUI control is drawn one way. Its shape comes from one component in `gui/lib/ui/controls.dart`, or from one sub-theme in `themeDataFor`. Tappable controls are 40 tall on mouse platforms and 48 on touch platforms.

**Architecture:**
- `tokens.dart` gains a platform-keyed control height, and the theme sets density and the sub-themes (switch, checkbox, popup menu, input decoration, slider).
- New shared widgets go in `controls.dart`: `RappSwitchRow`, `RappCheckRow`, `RappChoice`, `RappDropdown` and `RappButton.quiet`.
- Every call site moves onto them, one control family per task.

**Tech Stack:** Flutter/Dart (gui only).

**Spec:** `docs/superpowers/specs/2026-11-18-rapp-controls-unify-design.md`

## Global Constraints

- Control height is 40 on mouse platforms (macOS, Linux, Windows) and 48 on touch platforms (iOS, Android). It is keyed by platform only.
- Fixed sizes stay as they are:
  - top bar 56
  - session strip 60
  - app row 68
  - writing panel line 48
  - writing panel ＋ and 发送 40
- Do not change colour values, font sizes, theme token values or layout structure.
- Do not touch the embedded remote picture or the terminal picture itself.
- The composer's own text field stays borderless.
- Colours come from tokens only:
  - `accent`, `accent-ink`, `line`, `text`, `muted`, `raise`, `bg`
  - corner radius is `r`
  - error text is `colorScheme.error`, which equals `accent`
- Existing tests that find widgets by key must keep finding them. Keep the old keys on the new widgets.
- Tests run on the default test platform (Android, touch), where 48 stays 48. Only new tests check macOS heights.
- Revert `gui/pubspec.lock` after running tests. Flutter is `~/development/flutter/bin/flutter`. Use `/usr/bin/grep`.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **macOS really measures 40.** Material subtracts 8 from base sizes at `VisualDensity.compact`. So the theme keeps base sizes at 48 and sets density explicitly, and custom rows use `controlHeightOf(context)`. A widget that hard-codes 48 would be 48 on Mac. Covered by Task 1's macOS height tests and by each task's macOS test of its component.
2. **iPad stays ≥48 everywhere.** Each task's component test also runs under `TargetPlatform.iOS` and expects 48.
3. **Disabled controls.** A null `onChanged` or `onTap` leaves the row inert (no ripple, no toggle) and the label `muted`. Covered by the Task 2 component tests.
4. **Inherited-value grey labels.** In `app_profile_page`, labels show `muted` when the value is inherited. The new rows take a `dim` flag, so this survives. Covered by the existing app_profile_page tests, plus one new assertion in Task 2.
5. **Action menus show no tick.** A `RappDropdown` without a `current` value renders no check column and never the selected style. Covered by Task 3.

---

### Task 1: control height, theme sub-themes, spec text

**Files:**
- Modify: `gui/lib/ui/tokens.dart` (top-level helpers; `themeDataFor`, lines 295–354)
- Modify: `gui/lib/ui/side_panel.dart:36`, so that `settingsRowHeight` delegates to `controlHeightFor`
- Modify: `docs/superpowers/specs/2026-11-12-rapp-design-language.md` §6 and §8
- Test: `gui/test/ui/tokens_test.dart`
- Create: `gui/test/ui/platform_helpers.dart`

**Interfaces (produces):**
- `bool touchPlatform(TargetPlatform p)`: true for iOS and Android.
- `double controlHeightFor(TargetPlatform p)`: 48 when touch, 40 otherwise.
- `double controlHeightOf(BuildContext c)`: `controlHeightFor(Theme.of(c).platform)`.
- `ThemeData themeDataFor(RappTheme theme, {double textSize = fallbackTextSize, TargetPlatform? platform})`. `platform` defaults to `defaultTargetPlatform`, and the result's `platform` is set to it.
- In the test helper, `Future<void> onPlatform(TargetPlatform p, Future<void> Function() body)`. It sets `debugDefaultTargetPlatformOverride`, runs `body`, and resets the override in a `finally`.

- [ ] **Step 1: Write failing tests** in `tokens_test.dart`:
  - `controlHeightFor`:
    - `macOS`, `linux` and `windows` give 40.
    - `iOS` and `android` give 48.
  - `themeDataFor(RappTheme.values.first, platform: TargetPlatform.macOS)`:
    - `visualDensity == VisualDensity.compact`
    - `materialTapTargetSize == MaterialTapTargetSize.shrinkWrap`
    - `platform == TargetPlatform.macOS`
    - with `platform: iOS`: `standard` and `padded`
  - Widget test: under `onPlatform(macOS)` with `themeDataFor(..., platform: macOS)`, a `FilledButton(onPressed: () {}, child: Text('x'))` measures height 40. The same test under iOS measures 48.
  - Sub-themes present, checked with a `WidgetState` set:
    - `switchTheme.trackColor` resolves `{selected}` to `t.accent`.
    - `checkboxTheme.fillColor` resolves `{selected}` to `t.accent`.
    - `checkboxTheme.shape` is a `RoundedRectangleBorder` with radius `t.r / 2`.
    - `popupMenuTheme.color == t.bg`, and its shape has a `t.text` side and radius `t.r`.
    - `inputDecorationTheme`:
      - `isDense == true`
      - `floatingLabelBehavior == FloatingLabelBehavior.always`
      - `enabledBorder` is an `OutlineInputBorder` with a `t.line` side and radius `t.r`
      - `focusedBorder` side is `t.text`
    - `sliderTheme`:
      - `activeTrackColor == t.accent`
      - `inactiveTrackColor == t.line`
      - `trackHeight == 3`
- [ ] **Step 2:** Run `flutter test test/ui/tokens_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Keep button `minimumSize` at 48 and `listTileTheme.minTileHeight` at 48; on mouse platforms, density brings both to 40. Drop `listTileTheme`'s own `visualDensity`.
  - `switchTheme`:
    - thumb: `accentInk` when selected, `muted` otherwise
    - track: `accent` when selected, `line` otherwise
    - track outline: `line`
  - `checkboxTheme`:
    - fill: `accent` when selected, transparent otherwise
    - check: `accentInk`
    - side: `line`
    - radius: `r/2`
  - `popupMenuTheme`: `color: bg`, shape with a `text` side and radius `r`, elevation 8, `shadowColor: Colors.black`.
  - `inputDecorationTheme`:
    - `isDense: true`
    - `contentPadding`: horizontal 12, and vertical so that a single-line field is `controlHeightFor(platform)` tall
    - `floatingLabelBehavior: always`
    - outline borders: `line` at rest, `text` when focused, `colorScheme.error` on error, all radius `r`
    - `errorStyle` colour: `scheme.error`
  - `sliderTheme`: copy the values from `composer_plus.dart:235-241` (accent track and thumb, `line` inactive track, no overlay, track height 3).
  - `settingsRowHeight(p)` returns `controlHeightFor(p)`. Ruling: side panel rows go from 34 to 40 on Mac, so they match everything else.
- [ ] **Step 4: Update the spec text.**
  - §6 first bullet becomes `可点控件的高度：触屏（iOS、Android）48，鼠标（macOS、Linux、Windows）40。`
  - Add rows to the §8 table:
    - 开关：整行可点，开关 38×24 在行最右，打开时 `--accent`
    - 勾选：框在左，勾上时 `--accent` 底
    - 单选：18 的圆点图标，选中 `--accent`、未选 `--muted`
    - 下拉：`--line` 线框盒子，右边 `--muted` 18 的箭头；打开或选值时用标签的选中样式；弹出菜单当前项左边打勾
    - 弱按钮：`--muted` 字、无边框、透明底（对话框的「取消」、页面里的链接式按钮）
    - 输入框：`--line` 线框、聚焦 `--text`、圆角 `--r`，标签贴在框上沿
- [ ] **Step 5:**
  - Run `flutter test test/ui/tokens_test.dart test/ui/side_panel_test.dart`. Expected: PASS. If side panel tests measured 34 on desktop, update them to 40.
  - Run `flutter analyze`. Expected: no issues.
  - Then run the full `flutter test`. Expected: only the 2 known `linux_detach_test` failures, which predate this work.
  - Fix any golden or size expectations that moved, and say which in the report.
- [ ] **Step 6:** Commit with the message `feat(gui): one control height per platform, and the control sub-themes`.

### Task 2: switch, check and choice rows

**Files:**
- Modify: `gui/lib/ui/controls.dart`
- Test: `gui/test/ui/controls_test.dart`
- Replace call sites:
  - Switches:
    - `ui/side_panel.dart:231-262` (the `toggle` helper)
    - `pages/update_section.dart:118-126`
    - `pages/local_section.dart:188`
    - `pages/ios_local_section.dart:145`
    - `pages/app_profile_page.dart:340-378` (four switches)
    - `embed/composer_plus.dart:195` (`_returnAfter`: a drawn check icon that is really a toggle)
  - Check rows:
    - `ui/unlock.dart:212`, `:223`
    - `ui/allow_dialog.dart:55`
  - Choices:
    - `ui/devices_tab.dart:820-845` (`_ModeChoice`; delete it)
    - `pages/app_profile_page.dart:167` (`_radio`)
    - `ui/allow_dialog.dart:42` (`_choice`)
  - Scope buttons: `history/history_list.dart:92` move to `TabChip`'s selected style.

**Interfaces (produces):**
- `RappSwitchRow({Key? key, Key? switchKey, required String label, String? note, required bool value, ValueChanged<bool>? onChanged, bool dim = false, TextStyle? style})`
  - `switchKey` goes on the inner `Switch`, and `key` on the row's `InkWell`.
  - `dim` draws the label in `muted`; it is the inherited value in app_profile_page.
  - `style` overrides the label style; the side panel passes its small style.
  - `note` is a second line in `muted`.
  - The `Switch` sits in a 38×24 `SizedBox` with a `FittedBox`, with `materialTapTargetSize: shrinkWrap`, at the right end.
  - The row's min height is `controlHeightOf(context)`.
  - `InkWell` has radius `r`, and `onTap` is `() => onChanged!(!value)`. The `Switch` gets the same `onChanged`.
  - When `onChanged` is null, the row is inert and the label is `muted`.
  - The whole row is wrapped in `MergeSemantics`.
- `RappCheckRow({Key? key, required String label, required bool value, ValueChanged<bool>? onChanged, TextStyle? style})`
  - `Checkbox` first, then the label.
  - Same row height, ink and disabled rules as `RappSwitchRow`.
- `RappChoice({Key? key, required String label, required bool selected, VoidCallback? onTap, bool dim = false})`
  - It is `_ModeChoice` moved here: icon 18, `accent` when selected and `muted` otherwise, Semantics `inMutuallyExclusiveGroup` and `checked`.
  - Its height becomes `controlHeightOf(context)`, and its `InkWell` gets radius `r`.
  - `dim` mutes the label.

- [ ] **Step 1: Write failing tests** in `controls_test.dart`:
  - `RappSwitchRow`:
    - Tapping the label text calls `onChanged(!value)`.
    - Tapping the `Switch` by `switchKey` calls it once (not twice).
    - The `Switch`'s rendered size is 38×24.
    - With `onChanged: null`, a tap does nothing and the label colour is `t.muted`.
    - `dim: true` gives a `muted` label.
    - Row height is 40 under `onPlatform(macOS)` and 48 under `onPlatform(iOS)`.
  - `RappCheckRow`:
    - Tapping the label toggles.
    - The checkbox's left edge is left of the label's left edge.
    - Height is 40 on macOS and 48 on iOS.
  - `RappChoice`:
    - Selected icon colour is `t.accent`, unselected is `t.muted`.
    - Semantics has `isInMutuallyExclusiveGroup` and `isChecked`.
    - Height is 40 on macOS and 48 on iOS.
- [ ] **Step 2:** Run `flutter test test/ui/controls_test.dart`. Expected: FAIL (classes not defined).
- [ ] **Step 3: Implement** the three widgets.
- [ ] **Step 4:** Run `flutter test test/ui/controls_test.dart`. Expected: PASS.
- [ ] **Step 5: Replace every listed call site.**
  - Keep existing keys:
    - `focus-pane-switch`, `composer-switch`, `record-input-switch`, `type-to-compose-switch` go to `switchKey`.
    - The side panel's toggle keys go to `key`.
  - In `app_profile_page`, pass `dim: d.<field> == null`.
  - For `update_section`, the row sits in the existing `Wrap`. Give it a bounded width (`ConstrainedBox(maxWidth: 320)`) so the right-end switch sits near its label.
  - Ruling: a full-width row in a wide settings page would push the switch far from 自动升级.
- [ ] **Step 6:** Add one assertion to `test/ui/app_profile_page_test.dart`: an inherited `composer` value renders the 「显示「输入」」 label in `t.muted`.
- [ ] **Step 7:**
  - Run `flutter analyze` and the full `flutter test`. Expected: only the 2 known failures.
  - Run `/usr/bin/grep -rn "Switch(\|CheckboxListTile(" gui/lib | /usr/bin/grep -v "ui/controls.dart"`. Expected: no output.
- [ ] **Step 8:** Commit with the message `feat(gui): one switch row, check row and choice for every page`.

### Task 3: dropdowns and menus

**Files:**
- Modify: `gui/lib/ui/controls.dart`
- Test: `gui/test/ui/controls_test.dart`
- Replace call sites:
  - `ui/window_menu.dart:76` (box) and `:124`, `:197` (menus)
  - `ui/devices_tab.dart:172` and `:265`
  - `ui/log_screen.dart:224` and `:268`
  - `ui/project_menu.dart:60` and `:123`; it gains a border
  - `ui/side_panel.dart:215` (`DropdownButton`)
  - `pages/app_profile_page.dart:140` (`_dropdown`, a `DropdownButton`)
  - `ui/shares_section.dart:293` (`PopupMenuButton`, an action menu)
  - The current-item marking in `embed/picture.dart:417` and `embed/stream_menu.dart:712` (`_Item`) moves to the left-tick form.
- Leave alone: `ui/top_bar.dart:314` (session block) and `ui/hint_history.dart:53`. They follow the top bar's own rule.

**Interfaces (produces):**
- `RappDropdown<T>({Key? key, required Widget label, IconData? icon, T? current, required List<RappMenuItem<T>> items, required ValueChanged<T> onSelected, bool selected = false, double? minWidth, bool dim = false})`
  - The box:
    - min height `controlHeightOf(context)`, radius `r`
    - `line` border at rest
    - when the menu is open, or when `selected` is true: `raiseBox`, a `text` border and w600
    - trailing `arrow_drop_down`, size 18, `muted`
  - Opening calls `showRappMenu`, anchored under the box.
  - `dim` mutes the label; it is app_profile_page's inherited value.
- `RappMenuItem<T>({required T value, required String label, Widget? trailing, bool enabled = true})`. `trailing` carries window_menu's per-row close ×.
- `Future<T?> showRappMenu<T>(BuildContext c, {required RelativeRect position, required List<RappMenuItem<T>> items, T? current})`
  - It uses `showMenu`.
  - Each entry is at least `controlHeightOf(c)` tall.
  - When `current != null`, every row has a leading 18-wide column with `Icons.check` (18, `text`) on the current row and empty on the others.
  - The current row is not bold.
  - When `current == null`, there is no leading column.

- [ ] **Step 1: Write failing tests:**
  - `RappDropdown`:
    - The box has a `t.line` border at rest.
    - Tapping it opens a menu whose current row shows `Icons.check`, and the other rows don't.
    - Choosing an item calls `onSelected`.
    - With `current: null`, the opened menu has no `Icons.check`.
    - Box height is 40 on macOS and 48 on iOS.
    - Arrow size is 18 and colour `t.muted`.
  - The popup's `Material` shape has a `t.text` side.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5: Replace every listed site, keeping keys.**
  - `log_screen` keeps `minWidth: 96` and `selected: true`.
  - `devices_tab` and `window_menu` pass `selected` where they styled a selected state before.
  - `shares_section` passes no `current`.
- [ ] **Step 6:**
  - Run `flutter analyze` and the full `flutter test`. Expected: only the 2 known failures.
  - Run `/usr/bin/grep -rn "DropdownButton\|PopupMenuButton" gui/lib | /usr/bin/grep -v "ui/controls.dart"`. Expected: no output.
- [ ] **Step 7:** Commit with the message `feat(gui): one dropdown box and one menu style`.

### Task 4: buttons

**Files:**
- Modify: `gui/lib/ui/controls.dart` (`RappButton.quiet`; `IconButton` sizing)
- Test: `gui/test/ui/controls_test.dart`
- Replace call sites. These come from the audit, so re-grep to catch any the audit missed:
  - `FilledButton` → `primary`:
    - `main.dart:285`
    - `ui/unlock.dart:245`
    - `ui/access_setup.dart:108`
    - `pages/local_section.dart:305/332/414/455`
    - `pages/permissions_panel.dart:121`
    - `pages/data_section.dart:127/152`
  - `FilledButton.tonal` → `secondary`: `pages/cm_page.dart:92`
  - `OutlinedButton` → `secondary`:
    - `ui/access_setup.dart:137`
    - `pages/ios_local_section.dart:151`
    - `pages/permissions_panel.dart:50/68`
    - `pages/access_log_section.dart:88/89`
    - `pages/local_section.dart:484`
    - `pages/linux_update_section.dart:76/80/85/90`
    - `pages/data_section.dart:166/168/189`
  - `TextButton` → `quiet`:
    - Dialog actions:
      - `main.dart:284`
      - `ui/unlock.dart:241`
      - `pages/local_section.dart:331/413/454`
      - `pages/permissions_panel.dart:119/120`
      - `pages/data_section.dart:126/151`
      - `pages/linux_firewall_section.dart:73/74`
    - Page links:
      - `ui/unlock.dart:232`
      - `pages/local_section.dart:365`
      - `pages/ios_local_section.dart:122`
      - `pages/linux_firewall_section.dart:101/103`
      - `pages/app_profiles_section.dart:26/27/59`
      - `ui/stage.dart:288`
  - `IconButton` → icon 20, colour `text`:
    - `ui/side_panel.dart:120`
    - `ui/devices_tab.dart:658`
    - `pages/access_log_section.dart:75`
    - `pages/local_section.dart:218`; also drop its `VisualDensity.compact`
- Leave alone: the colours at `ui/stage.dart:301/338/340/342/343`, which sit on the yellow banner. Their size follows the theme.

**Interfaces (produces):**
- `RappButton.quiet({Key? key, required String label, VoidCallback? onPressed, String? semanticLabel, FocusNode? focusNode, IconData? icon})`
  - A `TextButton` with foreground `t.muted`, no border, transparent fill and radius `r`.
  - Same min size and 0.97 press scale as the other kinds.
  - `ConfirmButton`'s resting look uses it.

- [ ] **Step 1: Write failing tests** for `quiet`:
  - Foreground is `t.muted`.
  - No `side`.
  - Height is 40 on macOS and 48 on iOS.
  - The press scale is 0.97 while the pointer is down. Reuse the existing primary press-scale test's pattern.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement `quiet`.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5: Replace every listed site.**
  - In dialogs, the actions are `[quiet 取消, primary 确认]`, with confirm last.
  - Keep keys and labels.
  - Where a test found a button by type (`find.byType(FilledButton)` and so on), switch it to the key or the label.
- [ ] **Step 6:**
  - Run `flutter analyze` and the full `flutter test`. Expected: only the 2 known failures.
  - Run `/usr/bin/grep -rn "FilledButton\|OutlinedButton\|TextButton(" gui/lib | /usr/bin/grep -v "ui/controls.dart"`. Expected: no output. The `stage.dart` banner buttons are the exception: if they must stay `TextButton` for their banner colours, each needs a one-line comment saying so.
- [ ] **Step 7:** Commit with the message `feat(gui): every button through RappButton, with a quiet kind`.

### Task 5: text fields

**Files:**
- Modify the call sites. Remove their own `isDense`, `contentPadding`, `border`, `enabledBorder` and `focusedBorder`, and keep `labelText`, `hintText`, `prefixIcon` and `suffixIcon`:
  - `ui/access_setup.dart:90/99`
  - `ui/unlock.dart:200`
  - `pages/local_section.dart:266/319/402`
  - `pages/data_section.dart:124`
  - `pages/linux_firewall_section.dart:63`
  - `ui/devices_tab.dart:364`
  - `ui/add_device_form.dart:82/89`
  - `ui/shares_section.dart:219/228`
  - `ui/inline_edit.dart:85`
  - `ui/projects_tab.dart:131`
  - `embed/stream_menu.dart:525`
  - `ui/log_screen.dart:185` (keep width 200)
  - `history/history_list.dart:113`
  - `pages/app_profile_page.dart:172` (`_deco`; used at `:236/:293/:302/:451`)
  - `ui/secure_text_field.dart`, if it sets its own decoration
- Error colours: change `Colors.red` at `pages/local_section.dart:327`, and the hard-coded `t.accent` error text in `shares_section` and `app_profile_page`, to `Theme.of(context).colorScheme.error`.
- Leave alone: `embed/flutter_editor.dart:133` (the composer), and multiline fields, which keep the border but not the fixed height.
- Test: `gui/test/ui/controls_test.dart`, or a new `gui/test/ui/fields_test.dart`

- [ ] **Step 1: Write failing tests:**
  - A plain `TextField(decoration: InputDecoration(labelText: '名字'))` under `themeDataFor(..., platform: macOS)`:
    - renders an `OutlineInputBorder` with `t.line`
    - its `InputDecorator` box is 40 tall (48 under iOS)
  - In `log_screen` and `history_list`, the search fields are the same height as each other, on macOS.
- [ ] **Step 2:** Run it. Expected: FAIL. This test checks the call sites, not only the theme: history_list currently overrides the decoration.
- [ ] **Step 3:** Strip the per-site decoration overrides listed above. If the theme's vertical padding from Task 1 doesn't give exactly 40/48 with `floatingLabelBehavior.always`, adjust that padding in `tokens.dart`.
- [ ] **Step 4:**
  - Run `flutter analyze` and the full `flutter test`. Expected: only the 2 known failures.
  - Run `/usr/bin/grep -rn "Colors.red" gui/lib`. Expected: no output.
- [ ] **Step 5:** Commit with the message `feat(gui): one text field style from the theme`.

### Task 6: small targets, ripple corners, key caps

**Files:**
- Hit area at least `controlHeightOf(context)`, drawn size unchanged. Use padding inside the tappable widget, not a bigger icon:
  - `ui/window_menu.dart:157` (row close ×)
  - `ui/tab_chip.dart:78` (close ×)
  - `embed/composer_float.dart:217` (close ×; the grip at `:172` stays as it is)
  - `embed/picture.dart:395`: popup close. Replace the accent circle with an `IconButton`: `Icons.close`, size 20, colour `text`.
  - `pages/local_section.dart:241` (LAN fold)
  - `embed/composer_panel.dart:323` (IME link)
  - `term/term_stage.dart:943` (`_Pill`): it becomes an `InkWell` with radius `r`, keeping its look.
- `ui/log_screen.dart:506` stays compact on mouse platforms. Leave it alone.
- Add `borderRadius: BorderRadius.circular(t.r)` to the `InkWell`s at:
  - `ui/sessions_tab.dart:120`
  - `embed/stream_menu.dart:722`
  - `ui/inline_edit.dart:111`
  - `ui/projects_tab.dart:434`
  - `embed/composer_panel.dart:323`
  - `pages/local_section.dart:241`
- Key caps:
  - `embed/composer_plus.dart:282`: height becomes `controlHeightOf(context)`. A sticky key gets a 2 px `accent` border on `raise` fill instead of a solid `text` fill.
  - `term/term_key_row.dart:140`: keeps its size and its 2 px accent "lit" border.
  - `embed/app_key_row.dart:199`: keeps its size; its latched state is an accent border.
  - Ruling: the latched-with-accent-fill variant becomes an accent border, so all three read the same.
- Test: the existing test files for these widgets.

- [ ] **Step 1: Write failing tests:**
  - Under `onPlatform(macOS)`, the hit-test size (`tester.getSize` of the tappable widget, found by key) is ≥40 for:
    - the tab_chip close
    - the window_menu row close
    - the composer_float close
    - the picture popup close
    - the local_section LAN fold
  - Under `onPlatform(iOS)`, the same are ≥48.
  - A composer_plus sticky key's decoration has an `accent` border and no `text` fill.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:**
  - Run them. Expected: PASS.
  - Run `flutter analyze` and the full `flutter test`. Expected: only the 2 known failures.
  - Run `/usr/bin/grep -rn "InkWell(" gui/lib`, and check each hit has a `borderRadius`, or is a full-bleed surface where a square ripple is correct. List those in the report.
- [ ] **Step 5:** Commit with the message `feat(gui): hit areas up to the control height, rounded ripples, one key cap look`.
