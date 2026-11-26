import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/device_apps.dart';
import 'package:rapp/ui/terms_entry.dart';

void main() {
  const desktop = HubApp('desktop:', '桌面');
  const terminal = HubApp('com.apple.Terminal', 'Terminal');
  const safari = HubApp('com.apple.Safari', 'Safari');
  const notes = HubApp('com.apple.Notes', 'Notes');
  const terms = TermList('m1');

  List<String> titles(List<DeviceAppGroup> g) => [for (final x in g) x.title];
  List<String> ids(DeviceAppGroup g) => [for (final a in g.apps) a.app];

  test('screen, then the terminal entry with terminal apps, then the rest', () {
    final g = deviceAppGroups(const AppList('m1', 'lan', [safari, terminal, desktop, notes]), terms);
    expect(titles(g), ['屏幕', '终端', '应用（2）']);
    expect(ids(g[0]), ['desktop:']);
    expect(ids(g[1]), [termsEntry, 'com.apple.Terminal']);
    expect(ids(g[2]), ['com.apple.Safari', 'com.apple.Notes']);
  });

  test('without terminal sessions, terminal apps stay with the rest', () {
    final g = deviceAppGroups(const AppList('m1', 'lan', [terminal, safari]), const TermList('m1', off: true));
    expect(titles(g), ['应用（2）']);
    expect(ids(g[0]), ['com.apple.Terminal', 'com.apple.Safari']);
  });

  test('a text-only device has only the terminal entry', () {
    final g = deviceAppGroups(const AppList('m1', 'lan', [], capabilities: {'graphical': false}), terms);
    expect(titles(g), ['终端']);
    expect(ids(g[0]), [termsEntry]);
  });

  test('applications off: no terminal apps under the entry', () {
    final g = deviceAppGroups(
        const AppList('m1', 'lan', [desktop, terminal], capabilities: {'applications': false}), terms);
    expect(ids(g[1]), [termsEntry]);
  });

  test('no apps yet: only what the terminal list gives', () {
    expect(titles(deviceAppGroups(null, terms)), ['终端']);
    expect(deviceAppGroups(null, null), isEmpty);
  });

  test('filter: name contains, any case; empty groups go; titles keep their count', () {
    final g = deviceAppGroups(const AppList('m1', 'lan', [desktop, safari, notes]), null);
    final f = filterAppGroups(g, '  SAF ');
    expect(titles(f), ['应用（2）']);
    expect(ids(f[0]), ['com.apple.Safari']);
    expect(filterAppGroups(g, ''), same(g));
    expect(filterAppGroups(g, 'zzz'), isEmpty);
    // A labelled row is found by the title it shows, too.
    final byLabel = filterAppGroups(g, '查文档', shownAs: (a) => a.app == 'com.apple.Notes' ? '查文档' : a.name);
    expect(ids(byLabel[0]), ['com.apple.Notes']);
  });
}
