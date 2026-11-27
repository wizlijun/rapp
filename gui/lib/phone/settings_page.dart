/// The settings page: theme, this device, 中心服务 (V1b Task 7).
library;

import 'package:flutter/material.dart';

import '../pages/ios_local_section.dart';
import '../pages/state_section.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'phone_nav.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.state, required this.nav});
  final MainState state;
  final PhoneNav nav;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    return PhonePage(
      title: '设置',
      onBack: nav.home,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final hub = state.hub;
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final th in themeOrder)
                InkWell(
                  onTap: () => state.setTheme(th),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: phoneTap),
                    alignment: Alignment.centerLeft,
                    child: Row(children: [
                      Expanded(
                        child: Text(themeLabel(th),
                            style: style?.copyWith(
                                color: th == state.prefs.theme ? t.text : t.muted,
                                fontWeight: th == state.prefs.theme ? FontWeight.w600 : null)),
                      ),
                      if (th == state.prefs.theme) Icon(Icons.check, size: 18, color: t.text),
                    ]),
                  ),
                ),
              const SizedBox(height: 12),
              if (hub != null)
                IosLocalSection(hub: hub, prefs: state.prefs, onPrefs: state.savePrefs, data: state.data),
              if (state.stateSync != null) StateSection(sync: state.stateSync!),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('手机和展开后的 Pad 界面用同一个主题。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted)),
              ),
            ],
          );
        },
      ),
    );
  }
}
