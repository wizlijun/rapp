import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_choice.dart';

void main() {
  test('globMatch: * is any run, the rest literal, case-insensitive', () {
    expect(globMatch('*下载*', '正在下载 3 项'), isTrue);
    expect(globMatch('下载*', '下载'), isTrue);
    expect(globMatch('Settings', 'settings'), isTrue);
    expect(globMatch('a*b*c', 'aXXbYYc'), isTrue);
    expect(globMatch('a*b*c', 'aXXbYY'), isFalse);
    expect(globMatch('(1).txt', '(1).txt'), isTrue); // brackets and dots are literal
    expect(globMatch('a.c', 'abc'), isFalse);
    expect(globMatch('', ''), isTrue);
    expect(globMatch('', 'x'), isFalse);
    expect(globMatch('*', ''), isTrue);
  });

  test('fromJson reads the spec example; toJson writes fields in the authoring order', () {
    final p = AppProfile.fromJson({
      'name': 'Chrome', 'ids': ['com.google.Chrome', 'chrome.exe'],
      'stream': {'mode': 'color16', 'density': 'adaptive', 'fps': 15},
      'afterSend': 'none', 'composer': true,
      'windows': [{'kind': 'floating', 'title': '*下载*', 'action': 'hide'}, {'kind': 'dialog', 'action': 'noComposer'}],
      'tested': false,
    })!;
    expect(p.windows, [const WindowRule(kind: WindowKind.floating, title: '*下载*', action: RuleAction.hide),
                       const WindowRule(kind: WindowKind.dialog, action: RuleAction.noComposer)]);
    expect(p.toJson().keys.toList(), ['name', 'ids', 'stream', 'afterSend', 'composer', 'windows', 'tested']);
    expect(AppProfile(ids: ['x']).toJson(), {'ids': ['x']}); // unset fields are not written
    expect(AppProfile(ids: ['x'], fps: 5).toJson(), {'ids': ['x'], 'stream': {'fps': 5}});
  });

  test('an entry without usable ids is skipped; a bad top level throws', () {
    expect(AppProfile.fromJson({'name': 'x'}), isNull);
    expect(AppProfile.fromJson({'ids': ['  ', '']}), isNull);
    expect(AppProfile.fromJson('nope'), isNull);
    expect(parseProfiles({'version': 1, 'apps': [{'ids': ['a']}, {'name': 'no ids'}, 7]}).length, 1);
    expect(() => parseProfiles({'version': 2, 'apps': []}), throwsFormatException);
    expect(() => parseProfiles({'version': 1, 'apps': {}}), throwsFormatException);
    expect(() => parseProfiles([]), throwsFormatException);
  });

  test('a bad field or rule drops only itself', () {
    final p = AppProfile.fromJson({
      'ids': ['a'], 'stream': {'mode': 'sepia', 'density': 'adaptive', 'fps': 7},
      'afterSend': 'twice', 'composer': 'yes',
      'windows': [{'kind': 'window', 'action': 'hide'}, {'action': 'explode'}, {'title': 'ok', 'action': 'hide'}],
    })!;
    expect(p.mode, isNull);
    expect(p.density, 'adaptive');
    expect(p.fps, isNull);
    expect(p.afterSend, isNull);
    expect(p.composer, isNull);
    expect(p.windows, [const WindowRule(title: 'ok', action: RuleAction.hide)]);
  });

  test('name: trimmed to one line and 40 characters; empty is unset', () {
    expect(AppProfile.fromJson({'ids': ['a'], 'name': 'x' * 50})!.name!.length, 40);
    expect(AppProfile.fromJson({'ids': ['a'], 'name': '  '})!.name, isNull);
  });

  test('resolve: mine over built-in field by field, then the generic default', () {
    final builtin = [AppProfile(ids: ['com.google.Chrome'], name: 'Chrome', mode: 'color16', density: 'adaptive', fps: 15, tested: false)];
    final mine = [AppProfile(ids: ['COM.GOOGLE.CHROME'], fps: 5, windows: [const WindowRule(action: RuleAction.hide)])];
    final r = resolveProfile('com.google.chrome', mine: mine, builtin: builtin);
    expect(r.name, 'Chrome');
    expect(r.stream, const StreamChoice('color16', 'adaptive', 5));
    expect(r.windows.single.action, RuleAction.hide);
    expect(r.tested, isFalse);
    expect(r.afterSend, AfterSend.pressReturn);
    expect(ResolvedProfile.generic.afterSend, AfterSend.pressReturn);
    expect(r.composer, isTrue);
    expect(r.recordInput, isTrue);
    expect(resolveProfile('a', mine: [AppProfile(ids: ['a'], recordInput: false)], builtin: [AppProfile(ids: ['a'], recordInput: true)]).recordInput, isFalse);
    expect(AppProfile(ids: ['a']).toJson().containsKey('recordInput'), isFalse);
    expect(AppProfile.fromJson(AppProfile(ids: ['a'], recordInput: false).toJson())!.recordInput, isFalse);
    expect(r.typeToCompose, isTrue);
    expect(resolveProfile('a', mine: [AppProfile(ids: ['a'], typeToCompose: false)], builtin: [AppProfile(ids: ['a'], typeToCompose: true)]).typeToCompose, isFalse);
    expect(AppProfile(ids: ['a']).toJson().containsKey('typeToCompose'), isFalse);
    expect(AppProfile(ids: ['a'], typeToCompose: false).toJson()['typeToCompose'], false);
    expect(AppProfile.fromJson(AppProfile(ids: ['a'], typeToCompose: false).toJson())!.typeToCompose, isFalse);
    expect(r.focusPane, isTrue);
    expect(resolveProfile('a', mine: [AppProfile(ids: ['a'], focusPane: false)], builtin: [AppProfile(ids: ['a'], focusPane: true)]).focusPane, isFalse);
    expect(AppProfile(ids: ['a']).toJson().containsKey('focusPane'), isFalse);
    expect(AppProfile(ids: ['a'], focusPane: false).toJson()['focusPane'], false);
    expect(AppProfile.fromJson({'ids': ['a'], 'focusPane': false})!.focusPane, isFalse);
    expect(AppProfile.fromJson({'ids': ['a']})!.focusPane, isNull);
    expect(AppProfile(ids: ['a'], focusPane: false).copy().focusPane, isFalse);
    expect(r.rime, isTrue);
    expect(ResolvedProfile.generic.rime, isTrue);
    expect(resolveProfile('a', mine: [AppProfile(ids: ['a'], rime: false)], builtin: [AppProfile(ids: ['a'], rime: true)]).rime, isFalse);
    expect(resolveProfile('a', mine: [AppProfile(ids: ['a'])], builtin: [AppProfile(ids: ['a'], rime: false)]).rime, isFalse);
    expect(AppProfile(ids: ['a']).toJson().containsKey('rime'), isFalse);
    expect(AppProfile(ids: ['a'], rime: false).toJson()['rime'], false);
    expect(AppProfile.fromJson(AppProfile(ids: ['a'], rime: false).toJson())!.rime, isFalse);
    expect(AppProfile.fromJson({'ids': ['a'], 'rime': 'no'})!.rime, isNull);
    expect(AppProfile(ids: ['a'], rime: false).copy().rime, isFalse);
    expect(r.phrases, isFalse);
    expect(ResolvedProfile.generic.phrases, isFalse);
    expect(resolveProfile('a', mine: [AppProfile(ids: ['a'])], builtin: [AppProfile(ids: ['a'], phrases: true)]).phrases, isTrue);
    expect(resolveProfile('a', mine: [AppProfile(ids: ['a'], phrases: false)], builtin: [AppProfile(ids: ['a'], phrases: true)]).phrases, isFalse);
    expect(AppProfile(ids: ['a']).toJson().containsKey('phrases'), isFalse);
    expect(AppProfile.fromJson(AppProfile(ids: ['a'], phrases: true).toJson())!.phrases, isTrue);
    expect(AppProfile.fromJson({'ids': ['a'], 'phrases': 'yes'})!.phrases, isNull);
    expect(AppProfile(ids: ['a'], phrases: true).copy().phrases, isTrue);
    expect(resolveProfile('other', mine: mine, builtin: builtin), same(ResolvedProfile.generic));
    expect(ResolvedProfile.generic.stream, startChoice);
  });

  test('resolve: mine writing windows: [] drops the built-in rules', () {
    final b = [AppProfile(ids: ['a'], windows: [const WindowRule(action: RuleAction.hide)])];
    expect(resolveProfile('a', mine: [AppProfile(ids: ['a'], windows: [])], builtin: b).windows, isEmpty);
  });

  test('resolve: a duplicated id uses the earlier of my profiles; a nameless one shows its first id', () {
    final mine = [AppProfile(ids: ['x.app', 'x.exe'], fps: 30), AppProfile(ids: ['x.app'], name: 'Later', fps: 1)];
    final r = resolveProfile('x.app', mine: mine, builtin: const []);
    expect(r.stream.fps, 30);
    expect(r.name, 'x.app');
  });

  test('composerAt round-trips and resolves mine over built-in', () {
    final p = AppProfile.fromJson({'ids': ['a'], 'composerAt': {'x': 0.3, 'top': 120}})!;
    expect(p.composerAt, const InputPoint(0.3, 120));
    expect(p.toJson()['composerAt'], {'x': 0.3, 'top': 120});
    expect(p.copy().composerAt, p.composerAt);
    expect(AppProfile.fromJson({'ids': ['a'], 'composerAt': {'x': 2, 'top': 1}})!.composerAt, isNull);
    final b = AppProfile(ids: ['a'], composerAt: const InputPoint(0.5, 8, fromBottom: true));
    expect(resolveProfile('a', mine: [p], builtin: [b]).composerAt, const InputPoint(0.3, 120));
    expect(resolveProfile('a', mine: [], builtin: [b]).composerAt, b.composerAt);
    expect(resolveProfile('z', mine: [p], builtin: [b]).composerAt, isNull);
    expect(defaultComposerAt, const InputPoint(0.5, 8, fromBottom: true));
  });
}
