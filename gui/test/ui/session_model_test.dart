import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/session_model.dart';

SessionEntry e(String device, String appName) => SessionEntry(
    sid: 1, id: device, app: 'bundle.$appName', appName: appName,
    device: device, path: 'lan', lamp: Lamp.active);

void main() {
  test('groups by device, sorted, entries stable', () {
    final g = groupSessions([e('mini', 'Safari'), e('air', 'Notes'), e('mini', 'Mail')], Grouping.device);
    expect(g.map((x) => x.title), ['air', 'mini']);
    expect(g[1].entries.map((x) => x.appName), ['Mail', 'Safari']);
  });
  test('groups by app', () {
    final g = groupSessions([e('mini', 'Safari'), e('air', 'Safari')], Grouping.app);
    expect(g.single.title, 'Safari');
    expect(g.single.entries.map((x) => x.device), ['air', 'mini']);
  });
  test('stepKey cycles across groups both ways', () {
    final g = groupSessions([e('a', 'X'), e('b', 'Y'), e('b', 'Z')], Grouping.device);
    expect(stepKey(g, 'a/bundle.X', 1), 'b/bundle.Y');
    expect(stepKey(g, 'b/bundle.Z', 1), 'a/bundle.X');
    expect(stepKey(g, 'a/bundle.X', -1), 'b/bundle.Z');
    expect(stepKey(g, null, 1), 'a/bundle.X');
    expect(stepKey(const [], null, 1), isNull);
  });
}
