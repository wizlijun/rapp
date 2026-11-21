import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/tidy_mode.dart';

void main() {
  test('chat apps default to chat, terminals and the desktop to prompt', () {
    expect(defaultTidyMode('com.tencent.xinWeChat', '微信'), TidyMode.chat);
    expect(defaultTidyMode('com.tinyspeck.slackmacgap', 'Slack'), TidyMode.chat);
    expect(defaultTidyMode('term:abc', 'zsh'), TidyMode.prompt);
    expect(defaultTidyMode('desktop:', '桌面'), TidyMode.prompt);
    expect(defaultTidyMode('com.apple.Terminal', '终端'), TidyMode.prompt);
  });
  test('tidyModeKey', () {
    expect(tidyModeKey('term:abc', 'd1'), 'term');
    expect(tidyModeKey('desktop:2', 'd1'), 'desktop:d1');
    expect(tidyModeKey('com.x', 'd1'), 'com.x');
  });
  test('mode names and json', () {
    expect((TidyMode.chat.app, TidyMode.chat.label, TidyMode.chat.json), ('dictation-chat', '对人', 'chat'));
    expect((TidyMode.prompt.app, TidyMode.prompt.label, TidyMode.prompt.json), ('dictation', '提示词', 'prompt'));
    expect(tidyModeFromJson('chat'), TidyMode.chat);
    expect(tidyModeFromJson('loud'), isNull);
    expect(tidyModeFromJson(3), isNull);
  });
}
