# 常用语条 Implementation Plan

**Goal:** iOS 按键区上方的常用语条：一点就发一句话再回车，不碰草稿。

**Architecture:** 条是 KeyBar 的第一行（`keyBarHeightOf` 计入 36 点），所以所有让位计算自动跟着。发送走 `ComposerModel.submitText(phrase: true)` + `port.composerSend`；整轮发完后 `RemoteSession._allSent` 见到常用语轮就只按回车（不收起、不放焦点）。列表存 `UiPrefs`，App 开关在 `AppProfile.phrases`。

**Spec:** `docs/superpowers/specs/2026-11-22-rapp-ios-phrases-design.md`

## Global Constraints

- 条高 36（条 30 + 间距 6）；勾 0.8 s；连发窗口 1 s；提示 2 s。
- 默认 10 条见 spec §3；`gui.json` 字段 `phrase_strip`、`phrases: [{text, put?}]`。
- 记录 `source: "phrase"`；↑ 回溯跳过。
- 只在 iOS 显示条和管理入口。

## Tasks

1. **Model + prefs**（`lib/embed/phrases.dart`、`lib/ui/prefs.dart`、`lib/ui/main_state.dart`）：`Phrase(text, put)`、`defaultPhrases`、prefs 读写、MainState 的 `phrases` / `setPhrases` / `addPhrase` / `setPhraseStrip`。测试：prefs 往返、缺省=默认、坏数据丢弃、addPhrase 去重。
2. **App profile**（`app_profile.dart`、`assets/app_profiles.json`、`app_profile_page.dart`）：`phrases` 字段，resolve 默认 false；内置 8 个打开；页面开关。测试：json 往返、resolve。
3. **Send path**（`composer_model.dart`、`remote_session.dart`、`input_recorder.dart`、`input_history.dart`、`main_state.dart`）：`Outgoing.phrase`、`submitText(phrase:)`、`_allSent` 常用语只回车、记录 `source: phrase`、不进内存回溯、`recallOf` 跳过、`InputEntry.phrase`。`sendPhrase(...)` 返回提示或 null，含 1 s 连发窗口。测试：总是回车且不收起、草稿不动、阻塞/忙返回提示、连发、记录 source、回溯跳过。
4. **Strip UI**（`lib/embed/phrase_strip.dart`、`key_bar.dart`）：条、勾、提示、长按菜单、「全部 ›」底部列表；`keyBarHeightOf` + 显示条件。测试：高度、显示条件（窄条/全局关/App 关/终端）、点了发出+回车、长按菜单、全部列表。
5. **Management**（`lib/pages/phrases_page.dart`、`side_panel.dart`、`history_list.dart` + 两处调用）：管理页、编辑框、全局设置入口、历史「加到常用语」与「常用语」标记。测试：增删改排序恢复默认、历史菜单加入。
6. 全量 `flutter test`、`flutter analyze`，iOS 构建检查，todo.md 记实机检查。
