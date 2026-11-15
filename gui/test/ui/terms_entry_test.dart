import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/terms_entry.dart';

void main() {
  HubApp app(String bundle) => HubApp(bundle, bundle.split('.').last);
  TermRow pty(String name, {int activity = 0}) => TermRow('term:pty:$name', name, 'zsh', null, 1, 0, activity, false, false);
  TermRow tmuxRow(String name, {int activity = 0}) =>
      TermRow('term:tmux:$name', name, 'zsh', null, 1, 0, activity, false, false);
  TermHost local(List<String> launchers) => TermHost(null, launchers: launchers);

  test('desktop first and terminal apps folded when the entry shows', () {
    final apps = [app('com.apple.Safari'), app('com.apple.Terminal'), app('desktop:'), app('com.googlecode.iterm2')];
    expect(orderApps(apps, entry: true).map((a) => a.app), ['desktop:', 'com.apple.Safari']);
    expect(orderApps(apps, entry: false).map((a) => a.app),
        ['desktop:', 'com.apple.Safari', 'com.apple.Terminal', 'com.googlecode.iterm2']);
  });

  test('terminal apps are the known bundles, in list order', () {
    final apps = [app('net.kovidgoyal.kitty'), app('com.apple.Safari'), app('com.apple.Terminal')];
    expect(terminalAppsOf(apps).map((a) => a.app), ['net.kovidgoyal.kitty', 'com.apple.Terminal']);
  });

  test('the entry shows only with a list that is on and has no error', () {
    expect(showsTermsEntry(null), isFalse);
    expect(showsTermsEntry(const TermList('d', off: true)), isFalse);
    expect(showsTermsEntry(const TermList('d', error: 'timed out')), isFalse);
    expect(showsTermsEntry(const TermList('d', hosts: [TermHost(null, error: 'tmux not found')])), isTrue);
  });

  test('text mode opens the most recently active text terminal', () {
    final list = TermList('d',
        terms: [pty('a', activity: 5), tmuxRow('w', activity: 9), pty('b', activity: 7)], hosts: [local(['Terminal'])]);
    expect(termsTarget(mode: 'text', list: list, apps: const []),
        isA<OpenTerm>().having((t) => t.app, 'app', 'term:pty:b').having((t) => t.name, 'name', 'b'));
  });

  test('text mode with none asks for a new one, if it can open one', () {
    expect(termsTarget(mode: 'text', list: TermList('d', hosts: [local(['Terminal'])]), apps: const []),
        isA<AskNewText>());
    expect(termsTarget(mode: 'text', list: TermList('d', hosts: [local(const [])]), apps: const []), isA<OpenPixels>());
  });

  test('text mode with no launchers opens the most recently active tmux session', () {
    final list = TermList('d', terms: [tmuxRow('a', activity: 5), tmuxRow('w', activity: 9)], hosts: [local(const [])]);
    expect(termsTarget(mode: 'text', list: list, apps: [app('com.googlecode.iterm2')]),
        isA<OpenTerm>().having((t) => t.app, 'app', 'term:tmux:w').having((t) => t.name, 'name', 'w'));
    // An old service sends no hosts at all.
    expect((termsTarget(mode: 'text', list: TermList('d', terms: [tmuxRow('a')]), apps: const []) as OpenTerm).app,
        'term:tmux:a');
  });

  test('text mode asks for a new text terminal before it falls back to tmux', () {
    final list = TermList('d', terms: [tmuxRow('w', activity: 9)], hosts: [local(['Terminal'])]);
    expect(termsTarget(mode: 'text', list: list, apps: const []), isA<AskNewText>());
  });

  test('text mode with no launchers and no sessions opens pixels', () {
    final t = termsTarget(mode: 'text', list: TermList('d', hosts: [local(const [])]), apps: [app('com.googlecode.iterm2')]);
    expect((t as OpenPixels).bundle, 'com.googlecode.iterm2');
  });

  test('pixels mode ignores tmux sessions', () {
    final list = TermList('d', terms: [tmuxRow('w', activity: 9)], hosts: [local(const [])]);
    expect(termsTarget(mode: 'pixels', list: list, apps: const []), isA<OpenPixels>());
  });

  test('pixels mode opens the first terminal app, else Terminal', () {
    expect(
        (termsTarget(mode: 'pixels', list: const TermList('d'), apps: [app('com.googlecode.iterm2')]) as OpenPixels)
            .bundle,
        'com.googlecode.iterm2');
    final fallback = termsTarget(mode: 'pixels', list: const TermList('d'), apps: const []) as OpenPixels;
    expect((fallback.bundle, fallback.name), ('com.apple.Terminal', 'Terminal'));
  });

  test('pixels mode ignores text terminals', () {
    final list = TermList('d', terms: [pty('a', activity: 5)], hosts: [local(['Terminal'])]);
    expect(termsTarget(mode: 'pixels', list: list, apps: const []), isA<OpenPixels>());
  });
}
