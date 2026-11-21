// 按用途整理: the gateway app a voice tidy runs depends on where the text goes. `dictation` writes prompts
// (bullet points allowed); `dictation-chat` keeps the speaker's tone and does not list.
import '../term/term_id.dart';
import '../ui/session_model.dart' show isDesktopApp;

enum TidyMode { prompt, chat }

extension TidyModeInfo on TidyMode {
  String get app => this == TidyMode.chat ? 'dictation-chat' : 'dictation';
  String get label => this == TidyMode.chat ? '对人' : '提示词';
  String get json => name;
  TidyMode get other => this == TidyMode.chat ? TidyMode.prompt : TidyMode.chat;
}

TidyMode? tidyModeFromJson(Object? v) {
  for (final m in TidyMode.values) {
    if (v == m.json) return m;
  }
  return null;
}

const _chatApps = [
  'WeChat', '微信', 'Lark', 'Feishu', '飞书', 'WeCom', '企业微信', 'DingTalk', '钉钉', 'Telegram', 'Slack', 'Mail', '邮件',
  'Messages', '信息', 'QQ',
];

/// A terminal or the whole desktop is a prompt; a chat or mail app is for people; the rest is a prompt.
TidyMode defaultTidyMode(String app, String appName) {
  if (isTermApp(app) || isDesktopApp(app)) return TidyMode.prompt;
  final a = app.toLowerCase(), n = appName.toLowerCase();
  for (final k in _chatApps) {
    final l = k.toLowerCase();
    if (a.contains(l) || n.contains(l)) return TidyMode.chat;
  }
  return TidyMode.prompt;
}

/// The key a choice is remembered under: all terminals share one, the desktop is per device, an app is its own.
String tidyModeKey(String app, String deviceId) {
  if (isTermApp(app)) return 'term';
  if (isDesktopApp(app)) return 'desktop:$deviceId';
  return app;
}
