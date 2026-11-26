import 'dart:convert';
import 'dart:io';

import '../embed/app_profile.dart' show InputPoint;
import '../embed/phrases.dart';
import '../embed/strip_cmds.dart';
import '../embed/tidy_mode.dart';
import '../embed/voice_key_gate.dart';
import 'tokens.dart';

/// Which layer the window opens on (`first` in gui.json): the devices or the projects.
enum FirstLayer { device, project }

/// Which screen edge the stage's button stack (iOS) stands on.
enum StageSide { left, right }

/// Size factor of each writing-panel zoom step (⌘= / ⌘- / ⌘0): the default, then four larger.
const composerZoomScales = [1.0, 1.15, 1.3, 1.5, 1.75];

/// The top zoom step; 0 is the default and the smallest.
final composerZoomMax = composerZoomScales.length - 1;

/// GUI preferences, stored in `<dir>/gui.json` (`devices/<id>/` in the data root).
class UiPrefs {
  UiPrefs({
    this.theme = RappTheme.matrix,
    this.startFullscreen = true,
    this.autoSaveTraffic = true,
    this.inputHistory = true,
    this.keyBarMore = false,
    this.quickHiddenTerm = false,
    this.quickHiddenApp = true,
    this.quickAutoHide,
    this.termComposerAt,
    this.phraseStrip = true,
    List<StripItem>? phrases,
    this.phraseCmdsSeeded = true,
    this.termFit = true,
    this.voiceAiTidy = true,
    this.voiceAiThink = false,
    this.keepAwake = true,
    this.rimeEnabled = true,
    this.imeIntent = true,
    this.chineseIme,
    this.rimeDictionary = 'bundled',
    this.first = FirstLayer.device,
    this.composerZoom = 0,
    this.stageButtonsSide = StageSide.right,
    this.settingsFolded = false,
    this.voiceHotkey = VoiceHotkey.standard,
    this.voiceLanguageHintShown = false,
    Map<String, String>? termOpen,
    Map<String, TidyMode>? voiceTidyMode,
    Map<String, String>? termApp,
  })  : phrases = phrases ?? defaultStripItems,
        termOpen = termOpen ?? {},
        voiceTidyMode = voiceTidyMode ?? {},
        termApp = termApp ?? {};

  RappTheme theme;
  bool startFullscreen;

  /// 网络差时自动省流量 (`auto_save_traffic`): A may lower the stream below the choice while the
  /// network is poor. Missing means on.
  bool autoSaveTraffic;

  /// 记下写作面板发出去的话 (`input_history`): the input record is kept. Missing or bad means on.
  bool inputHistory;

  /// 按键区 (iOS): the second row is open (`key_bar_more`). Missing or bad means closed.
  bool keyBarMore;

  /// 快捷区 folded to its handle for text terminals and terminal apps (`quick_hidden_term`). An old
  /// `key_bar_slim: true` reads as true; missing means shown.
  bool quickHiddenTerm;

  /// 快捷区 folded for every other app (`quick_hidden_app`). Missing means hidden.
  bool quickHiddenApp;

  /// 打字后自动收起 (`quick_auto_hide`): null (missing) means on for macOS/Linux, off for iOS.
  bool? quickAutoHide;

  /// Where the writing panel stands for every text terminal (`term_composer_at`); null is the default place.
  InputPoint? termComposerAt;

  /// 显示常用语条 (`phrase_strip`, iOS): the 常用语 strip over the key bar. Missing or bad means on.
  bool phraseStrip;

  /// 常用语 (`phrases`, iOS): in strip order. Missing or not a list means [defaultPhrases]; bad entries are
  /// dropped on load.
  List<StripItem> phrases;

  /// The six built-in commands were put in front of the saved list once (`phrase_cmds_seeded`).
  bool phraseCmdsSeeded;

  /// 跟着我的窗口 (`term_fit`): the host's terminal window follows this console's size. Missing or bad means on.
  bool termFit;

  /// 长语音先让 AI 整理 (`voice_ai_tidy`): a voice text over 10 characters goes through the LLM 接入点 first.
  /// Missing or bad means on.
  bool voiceAiTidy;

  /// AI 整理时先思考 (`voice_ai_think`): the tidy asks the model to think first; new names come out righter, the
  /// first word about 1.5 s later (measured 2026-11-21). Missing or bad means off (user 2026-11-21).
  bool voiceAiThink;

  /// 屏幕常亮 (`keep_awake`, iOS): no auto-lock while a live session is on the stage. Missing or bad means on.
  bool keepAwake;

  /// 实体键盘用内置输入法 (`rime_enabled`, iOS): the master switch; each session's app profile can still turn it
  /// off for that app (`rime`). Missing or bad means on.
  bool rimeEnabled;

  /// 打开写作版时切到中文，回到画面时切回英文 (`ime_intent`): the writing panel switches this device's input method.
  /// Missing or bad means on.
  bool imeIntent;

  /// The Chinese input method last left when the caret came out of the writing panel (`chinese_ime`): the next
  /// switch asks for it. Null (missing or bad) lets the device pick.
  String? chineseIme;

  /// 词库 (`rime_dictionary`, iOS): `'bundled'` (自带雾凇) or `'user'` (我的目录). Anything else means `'bundled'`.
  String rimeDictionary;

  /// 输入板缩放档 (`composer_zoom`): 0 is the default size, up to [composerZoomMax]. Missing or bad means 0.
  int composerZoom;

  /// 按钮排的边 (`stage_buttons_side`, iOS): the edge the stage's button stack stands on. Missing or bad means right.
  StageSide stageButtonsSide;

  /// 全局设置折起 (`settings_folded`): the side panel's settings are folded away. Missing or bad means open.
  bool settingsFolded;

  /// 语音输入快捷键 (`voice_hotkey`, macOS): hold to talk. Missing or bad means long-press Right Option.
  VoiceHotkey voiceHotkey;

  /// 语音语言提示已显示 (`voice_language_hint_shown`). Missing or bad means false.
  bool voiceLanguageHintShown;

  /// 排列 (`first`): the layer shown first. Missing or unknown means devices.
  FirstLayer first;

  /// 终端打开方式 (`term_open`): device id to `text` or `pixels`. Unknown values are dropped on load.
  final Map<String, String> termOpen;

  /// 整理用途 the user chose per app (see [tidyModeKey]); an app not here follows [defaultTidyMode].
  final Map<String, TidyMode> voiceTidyMode;

  String termOpenFor(String device) => termOpen[device] ?? 'text';

  /// 终端 app (`term_app`): device id to the terminal app a new text terminal opens in. Non-string values are
  /// dropped on load.
  final Map<String, String> termApp;

  /// The stored app when [launchers] still has it, else the first launcher.
  String termAppFor(String device, List<String> launchers) {
    final a = termApp[device];
    return a != null && launchers.contains(a) ? a : launchers.first;
  }

  /// Never throws: a missing or corrupt file gives the defaults.
  /// A saved list from before the commands: the built-in ones go in front once (those it does not hold yet).
  static List<StripItem> _seeded(List<StripItem> l, bool done) {
    if (done) return l;
    final have = {for (final c in l.whereType<StripCmd>()) c.id};
    return [for (final id in builtinCmdOrder) if (!have.contains(id)) StripCmd(id), ...l];
  }

  static UiPrefs load(String dir) {
    try {
      final j = jsonDecode(File('$dir/gui.json').readAsStringSync());
      if (j is! Map) return UiPrefs();
      final name = j['theme'];
      final fs = j['start_fullscreen'];
      final save = j['auto_save_traffic'];
      final ih = j['input_history'];
      final tf = j['term_fit'];
      final vt = j['voice_ai_tidy'];
      final vk = j['voice_ai_think'];
      final ka = j['keep_awake'];
      final re = j['rime_enabled'];
      final ii = j['ime_intent'];
      final ci = j['chinese_ime'];
      final rd = j['rime_dictionary'];
      final fl = j['first'];
      final cz = j['composer_zoom'];
      final sb = j['stage_buttons_side'];
      final sf = j['settings_folded'];
      final vh = j['voice_hotkey'];
      final vl = j['voice_language_hint_shown'];
      final to = j['term_open'];
      final ta = j['term_app'];
      final tm = j['voice_tidy_mode'];
      final qt = j['quick_hidden_term'];
      final qa = j['quick_hidden_app'];
      final qh = j['quick_auto_hide'];
      return UiPrefs(
        theme: RappTheme.values.firstWhere(
          (t) => t.name == name,
          orElse: () => RappTheme.matrix,
        ),
        startFullscreen: fs is bool ? fs : true,
        autoSaveTraffic: save is bool ? save : true,
        inputHistory: ih is bool ? ih : true,
        keyBarMore: j['key_bar_more'] == true,
        quickHiddenTerm: qt is bool ? qt : j['key_bar_slim'] == true,
        quickHiddenApp: qa is bool ? qa : true,
        quickAutoHide: qh is bool ? qh : null,
        termComposerAt: InputPoint.fromJson(j['term_composer_at']),
        phraseStrip: j['phrase_strip'] != false,
        phrases: j['phrases'] is List
            ? _seeded([for (final e in j['phrases'] as List) ?stripItemFromJson(e)], j['phrase_cmds_seeded'] == true)
            : null,
        termFit: tf is bool ? tf : true,
        voiceAiTidy: vt is bool ? vt : true,
        voiceAiThink: vk is bool ? vk : false,
        keepAwake: ka is bool ? ka : true,
        rimeEnabled: re is bool ? re : true,
        imeIntent: ii is bool ? ii : true,
        chineseIme: ci is String && ci.isNotEmpty ? ci : null,
        rimeDictionary: rd == 'user' ? 'user' : 'bundled',
        composerZoom: cz is int ? cz.clamp(0, composerZoomMax) : 0,
        stageButtonsSide: sb == 'left' ? StageSide.left : StageSide.right,
        settingsFolded: sf is bool ? sf : false,
        voiceHotkey: VoiceHotkey.fromJson(vh),
        voiceLanguageHintShown: vl is bool ? vl : false,
        first: FirstLayer.values.firstWhere(
          (v) => v.name == fl,
          orElse: () => FirstLayer.device,
        ),
        voiceTidyMode: {
          if (tm is Map)
            for (final e in tm.entries)
              if (e.key is String && tidyModeFromJson(e.value) != null) e.key as String: tidyModeFromJson(e.value)!,
        },
        termOpen: {
          if (to is Map)
            for (final e in to.entries)
              if (e.key is String && (e.value == 'text' || e.value == 'pixels')) e.key as String: e.value as String,
        },
        termApp: {
          if (ta is Map)
            for (final e in ta.entries)
              if (e.key is String && e.value is String) e.key as String: e.value as String,
        },
      );
    } catch (_) {
      return UiPrefs();
    }
  }

  /// Synchronous; creates [dir] if needed. Throws [FileSystemException].
  void save(String dir) {
    Directory(dir).createSync(recursive: true);
    File('$dir/gui.json').writeAsStringSync(
      jsonEncode({
        'theme': theme.name,
        'start_fullscreen': startFullscreen,
        'auto_save_traffic': autoSaveTraffic,
        'input_history': inputHistory,
        'key_bar_more': keyBarMore,
        'quick_hidden_term': quickHiddenTerm,
        'quick_hidden_app': quickHiddenApp,
        if (quickAutoHide != null) 'quick_auto_hide': quickAutoHide,
        if (termComposerAt != null) 'term_composer_at': termComposerAt!.toJson(),
        'phrase_strip': phraseStrip,
        'phrases': [for (final p in phrases) p.toJson()],
        'phrase_cmds_seeded': phraseCmdsSeeded,
        'term_fit': termFit,
        'voice_ai_tidy': voiceAiTidy,
        'voice_ai_think': voiceAiThink,
        'keep_awake': keepAwake,
        'rime_enabled': rimeEnabled,
        'ime_intent': imeIntent,
        if (chineseIme != null) 'chinese_ime': chineseIme,
        'rime_dictionary': rimeDictionary,
        'first': first.name,
        'composer_zoom': composerZoom,
        'stage_buttons_side': stageButtonsSide.name,
        'settings_folded': settingsFolded,
        'voice_hotkey': voiceHotkey.toJson(),
        'voice_language_hint_shown': voiceLanguageHintShown,
        'voice_tidy_mode': {for (final e in voiceTidyMode.entries) e.key: e.value.json},
        'term_open': termOpen,
        'term_app': termApp,
      }),
    );
  }
}
