// 本机 page: the app 配置 section: every profile (built-in, mine, changed) with edit,
// delete and restore, plus a way to make a new one and to open the folder holding apps.json.
import 'package:flutter/material.dart';

import '../ui/app_profile_store.dart';
import '../ui/controls.dart';
import '../ui/tokens.dart';
import 'app_profile_page.dart';
import 'section_card.dart';

class AppProfilesSection extends StatelessWidget {
  const AppProfilesSection({super.key, required this.store, required this.openFolder});
  final AppProfileStore store;
  final Future<void> Function(String dir) openFolder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final t = RappTokens.of(context);
        final problem = store.problem;
        return SectionCard(
          title: 'app 配置',
          action: Wrap(spacing: 8, children: [
            TextButton(onPressed: () => openAppProfilePage(context, store), child: const Text('新建')),
            TextButton(onPressed: () => openFolder(store.dir), child: const Text('打开配置文件夹')),
          ]),
          children: [
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(problem, style: TextStyle(color: t.accent)),
              ),
            for (final row in store.rows()) _row(context, t, row),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, RappTokens t, ProfileRow row) {
    final mono = TextStyle(fontFamily: t.mono, fontFamilyFallback: t.monoFallback, fontSize: 12, color: t.muted);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(row.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(row.ids.join(', '), style: mono),
            Wrap(spacing: 8, children: [
              Text(sourceLabel(row.source), style: TextStyle(color: t.muted, fontSize: 12)),
              if (!row.tested) Text('未实测', style: TextStyle(color: t.muted, fontSize: 12)),
              if (row.duplicateOf != null)
                Text('和 ${row.duplicateOf} 重复', style: TextStyle(color: t.accent, fontSize: 12)),
            ]),
          ]),
        ),
        TextButton(
          onPressed: () => openAppProfilePage(context, store, appId: row.ids.first, appName: row.name),
          child: const Text('改'),
        ),
        if (row.source == ProfileSource.mine)
          ConfirmButton(label: '删除', onConfirmed: () => store.remove(row.mine!)),
        if (row.source == ProfileSource.changed)
          ConfirmButton(label: '恢复内置', onConfirmed: () => store.restoreBuiltin(row.builtin!)),
      ]),
    );
  }
}
