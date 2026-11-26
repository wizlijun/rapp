// A device's apps in groups, for the overview's 打开应用 menu (spec 2026-11-25-rapp-overview-open-apps-design).
// Same order as the device panel: 桌面, then 终端 with the terminal apps it folds in, then the rest.
import '../hub_client.dart';
import 'terms_entry.dart';

class DeviceAppGroup {
  const DeviceAppGroup(this.title, this.apps);
  final String title;
  final List<HubApp> apps;
}

/// [apps] null = not probed yet. A group with nothing in it is left out.
List<DeviceAppGroup> deviceAppGroups(AppList? apps, TermList? terms) {
  final entry = showsTermsEntry(terms);
  final graphical = apps?.capabilities?['graphical'] != false;
  final applications = graphical && apps?.capabilities?['applications'] != false;
  final all = graphical ? apps?.apps ?? const <HubApp>[] : const <HubApp>[];
  final ordered = orderApps(all, entry: entry);
  final screen = [for (final a in ordered) if (a.app == 'desktop:') a];
  final rest = [for (final a in ordered) if (a.app != 'desktop:') a];
  final term = [
    if (entry) const HubApp(termsEntry, termsEntryName),
    if (entry && applications) ...terminalAppsOf(all),
  ];
  return [
    if (screen.isNotEmpty) DeviceAppGroup('屏幕', screen),
    if (term.isNotEmpty) DeviceAppGroup('终端', term),
    if (rest.isNotEmpty) DeviceAppGroup('应用（${rest.length}）', rest),
  ];
}

/// The rows whose name, or the title it is shown with ([shownAs], a label's), holds [query] (trimmed, any case);
/// empty groups go, titles stay as they were.
List<DeviceAppGroup> filterAppGroups(List<DeviceAppGroup> groups, String query, {String Function(HubApp)? shownAs}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return groups;
  bool hits(HubApp a) => a.name.toLowerCase().contains(q) || (shownAs?.call(a).toLowerCase().contains(q) ?? false);
  return [
    for (final g in groups)
      if (g.apps.where(hits).toList() case final hit when hit.isNotEmpty)
        DeviceAppGroup(g.title, hit),
  ];
}
