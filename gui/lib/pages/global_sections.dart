// The side panel's 全局设置 beyond the switches: 版本升级 and 数据目录. They are about rApp on this machine as a
// whole, not about the service the 本机 page controls, so they live with the other settings.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data_relocate.dart';
import '../paths.dart';
import '../platform_caps.dart';
import '../service_client.dart';
import '../state/state_sync.dart';
import 'data_section.dart';
import 'linux_update_section.dart';
import 'local_section.dart' show UpdateHooks, openInstallerPage;
import 'state_section.dart';
import 'update_section.dart';

class GlobalSections extends StatelessWidget {
  const GlobalSections({
    super.key,
    required this.monitor,
    required this.data,
    this.relocate,
    this.hooks,
    this.stateSync,
    this.openPage = openInstallerPage,
    this.platform,
  });

  final ServiceMonitor monitor;

  /// Null (tests): no 状态服务 block.
  final StateSync? stateSync;

  /// The current data root; the caller rebuilds when it changes.
  final DataDir data;
  final DataRelocator? relocate;

  /// Null (tests): the update buttons only send the command.
  final UpdateHooks? hooks;
  final Future<void> Function(String page) openPage;

  /// Platform override for testing both desktop interfaces on either OS.
  final TargetPlatform? platform;

  /// 立即升级 / 仍然安装 / 回到上一版 leave the app (K28): ask first, send, then quit.
  Future<void> _thenQuit(Future<Object?> Function() send) async {
    final h = hooks;
    if (h != null && !await h.confirmQuit()) return;
    await send();
    await h?.quitNow();
  }

  @override
  Widget build(BuildContext context) {
    final m = monitor;
    final linux = (platform ?? defaultTargetPlatform) == TargetPlatform.linux;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final update = m.status?.update;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (linux)
            LinuxUpdateSection(openPage: openPage)
          else if (update != null && caps.onlineUpdate)
            UpdateSection(
              info: update,
              onCheck: m.updateCheck,
              onApply: (confirm) => _thenQuit(() => m.updateApply(confirm: confirm)),
              onDismiss: m.updateDismiss,
              onRollback: () => _thenQuit(m.updateRollback),
              onSetAuto: (on) => m.setUpdate(autoUpdate: on),
              onOpenPage: (page) => openPage(page).catchError((_) {}),
            ),
          if (stateSync != null) StateSection(sync: stateSync!),
          DataSection(data: data, relocate: relocate),
        ]);
      },
    );
  }
}
