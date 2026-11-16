import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/terms_entry.dart';

void main() {
  HubApp app(String bundle) => HubApp(bundle, bundle.split('.').last);
  TermRow pty(String name, {int activity = 0}) => TermRow('term:pty:$name', name, 'zsh', null, 1, 0, activity, false, false);
  TermRow tmuxRow(String name, {int activity = 0}) =>
      TermRow('term:tmux:$name', name, 'zsh', null, 1, 0, activity, false, false);
  TermHost local(List<String> launchers, {List<TermShell>? shells}) => TermHost(null, launchers: launchers, shells: shells);

  test('a device without graphics never invents a macOS terminal', () {
    expect(termsTarget(mode: 'text', list: const TermList('linux'), apps: const [], graphical: false), isA<NoTerminal>());
    expect(termsTarget(mode: 'pixels', list: const TermList('linux'), apps: const [], graphical: false), isA<NoTerminal>());
    expect(termsTarget(mode: 'text', list: TermList('linux', hosts: [local(['ghostty'])]), apps: const [], graphical: false), isA<NewText>());
  });

  test('a device without graphics treats a saved pixels choice as text', () {
    final list = TermList('linux', terms: [pty('old', activity: 1), pty('recent', activity: 5)]);
    expect(termsTarget(mode: 'pixels', list: list, apps: const [], graphical: false),
        isA<OpenTerm>().having((t) => t.app, 'app', 'term:pty:recent'));
    final fresh = TermList('linux', hosts: [local(['kitty'], shells: [const TermShell('bash', '/bin/bash', true)])]);
    expect(termsTarget(mode: 'pixels', list: fresh, apps: const [], graphical: false),
        isA<NewText>().having((t) => t.shell, 'shell', '/bin/bash'));
  });

  test('a no-graphics capability wins over stale graphical app entries', () {
    expect(termsTarget(mode: 'pixels', list: const TermList('linux'),
        apps: [app('com.apple.Terminal')], graphical: false), isA<NoTerminal>());
  });

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
    expect(showsTermsEntry(const TermList('d', hosts: [TermHost(null)])), isTrue);
  });

  test('text mode opens the most recently active text terminal', () {
    final list = TermList('d',
        terms: [pty('a', activity: 5), tmuxRow('w', activity: 9), pty('b', activity: 7)], hosts: [local(['Terminal'])]);
    expect(termsTarget(mode: 'text', list: list, apps: const []),
        isA<OpenTerm>().having((t) => t.app, 'app', 'term:pty:b').having((t) => t.name, 'name', 'b'));
  });

  test('text mode with none opens a new one with the default shell, if it can open one', () {
    const shells = [TermShell('bash', '/bin/bash', false), TermShell('zsh', '/bin/zsh', true)];
    expect(termsTarget(mode: 'text', list: TermList('d', hosts: [local(['Terminal'], shells: shells)]), apps: const []),
        isA<NewText>().having((n) => n.shell, 'shell', '/bin/zsh'));
    expect(termsTarget(mode: 'text', list: TermList('d', hosts: [local(['Terminal'])]), apps: const []),
        isA<NewText>().having((n) => n.shell, 'shell', null));
    expect(termsTarget(mode: 'text', list: TermList('d', hosts: [local(const [])]), apps: const []), isA<OpenPixels>());
  });

  test('text mode with only tmux rows and no launchers opens pixels', () {
    final list = TermList('d', terms: [tmuxRow('a', activity: 5), tmuxRow('w', activity: 9)], hosts: [local(const [])]);
    expect(termsTarget(mode: 'text', list: list, apps: const []), isA<OpenPixels>());
    expect(termsTarget(mode: 'text', list: TermList('d', terms: [tmuxRow('a')]), apps: [app('com.googlecode.iterm2')]),
        isA<OpenPixels>());
  });

  test('text mode opens a new text terminal when the only rows are tmux ones', () {
    final list = TermList('d', terms: [tmuxRow('w', activity: 9)], hosts: [local(['Terminal'])]);
    expect(termsTarget(mode: 'text', list: list, apps: const []), isA<NewText>());
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
