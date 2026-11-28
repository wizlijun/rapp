import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_model.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/voice_button.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import 'voice_button_test.dart' show FakeVoice;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late MainState s;
  late FakeSessionPort port;
  late RemoteSession rs;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('voice_sends_test');
    port = FakeSessionPort();
    s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: port, voice: FakeVoice());
    rs = RemoteSession(1, 'Safari');
  });
  tearDown(() {
    rs.dispose();
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('voiceSends routes sendVoice', () {
    final got = <String>[];
    s.voiceSends[rs.sid] = (text, voice) {
      got.add(text);
      return null;
    };
    final hint = sendVoice(state: s, session: rs, port: port, text: ' 你好 ');
    expect(hint, isNull);
    expect(got, ['你好']);
    expect(port.calls.where((c) => c.$1 == 'composer_send'), isEmpty);
  });

  test("no voiceSends keeps today's path", () {
    final hint = sendVoice(state: s, session: rs, port: port, text: '你好', voice: const VoiceOrigin());
    expect(hint, isNull);
    expect(port.calls.where((c) => c.$1 == 'composer_send').length, 1);
    expect(sendVoice(state: s, session: rs, port: port, text: '  '), voiceBlank);
  });

  test('tidy kept for a voiceSends key, not for a stranger', () {
    expect(identical(s.tidyOf('x'), s.tidyOf('x')), isFalse); // today: not kept
    s.voiceSends['k'] = (t, v) => null;
    expect(identical(s.tidyOf('k'), s.tidyOf('k')), isTrue);
    s.removeVoiceSend('k');
    expect(s.voiceSends, isEmpty);
    expect(s.tidyIfAny('k'), isNull);
  });
}
