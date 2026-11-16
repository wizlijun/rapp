// 本机 › 版本与升级: the service's `update` object and what the GUI says about it (K26, K27).

class UpdateInfo {
  const UpdateInfo({
    required this.current,
    required this.state,
    this.latest,
    this.error,
    this.notes,
    this.page,
    this.progress,
    this.autoUpdate = true,
    this.checkUpdates = false,
    this.needsConfirm = false,
    this.needsAdmin = false,
    this.dismissed = false,
    this.canRollback = false,
    this.needsReinstall = false,
    this.reinstallPage,
  });

  /// The running bundle version ('' when the service could not read it).
  final String current;

  /// off | idle | checking | downloading | ready | installing | failed | up_to_date
  final String state;
  final String? latest, error, notes, page;

  /// Download progress in percent.
  final int? progress;
  final bool autoUpdate, checkUpdates, needsConfirm, needsAdmin, dismissed, canRollback;

  /// The pkg that ran here is older than this build: run it again (install-level spec).
  final bool needsReinstall;

  /// Where to get that pkg.
  final String? reinstallPage;

  /// Null unless [j] is a map (an older service sends no `update`).
  static UpdateInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    String? s(String k) => j[k]?.toString();
    final p = j['progress'];
    return UpdateInfo(
      current: s('current') ?? '',
      state: s('state') ?? 'off',
      latest: s('latest'),
      error: s('error'),
      notes: s('notes'),
      page: s('page'),
      progress: p is num ? p.round() : null,
      autoUpdate: j['auto_update'] != false,
      checkUpdates: j['check_updates'] == true,
      needsConfirm: j['needs_confirm'] == true,
      needsAdmin: j['needs_admin'] == true,
      dismissed: j['dismissed'] == true,
      canRollback: j['can_rollback'] == true,
      needsReinstall: j['needs_reinstall'] == true,
      reinstallPage: s('reinstall_page'),
    );
  }
}

enum UpdateAction { check, apply, applyAnyway, dismiss, openPage, reinstall }

/// The one line under 版本与升级 and the buttons beside it (K26).
({String line, List<UpdateAction> actions}) updateView(UpdateInfo u) {
  final v = u.latest ?? '';
  final cur = '当前 ${u.current}';
  const check = [UpdateAction.check];
  switch (u.state) {
    case 'off':
      return (line: '开发构建，不检查更新', actions: const []);
    case 'checking':
      return (line: '$cur · 正在检查', actions: const []);
    case 'downloading':
      return (line: '正在下载 $v（${u.progress ?? 0}%）', actions: const []);
    case 'installing':
      return (line: '正在安装 $v', actions: const []);
  }
  // Running the pkg again also brings whatever is waiting or failed, so it is said before them.
  if (u.needsReinstall) {
    return (line: '这一版要重新运行一次安装包，才能用上命令行 rapp 和 ssh 的 .rapp 设置', actions: const [UpdateAction.reinstall]);
  }
  if (u.state == 'failed') return (line: '升级没有完成：${u.error ?? ''}', actions: check);
  if (u.dismissed && u.latest != null) return (line: '$cur · $v 先不装', actions: check);
  if (u.state == 'ready') {
    // An admin password blocks the install whatever is confirmed, so it is said first.
    if (u.needsAdmin) return (line: '这次需要管理员密码', actions: const [UpdateAction.openPage, UpdateAction.dismiss]);
    if (u.needsConfirm) {
      return (
        line: '这一版换了签名，装上以后要重新授权屏幕录制和辅助功能',
        actions: const [UpdateAction.applyAnyway, UpdateAction.dismiss],
      );
    }
    return (
      line: u.autoUpdate ? '$v 已下载，没人在用时会自动装好' : '$v 已下载',
      actions: const [UpdateAction.apply, UpdateAction.dismiss],
    );
  }
  if (u.state == 'idle' && u.latest == null) return (line: cur, actions: check);
  if (u.state == 'idle' && _newer(u.latest, u.current)) return (line: '$cur · 有新版本 $v', actions: check);
  return (line: '$cur · 已是最新', actions: check);
}

/// True when dotted version [a] is above [b]; an unreadable part counts as 0.
bool _newer(String? a, String b) {
  if (a == null) return false;
  List<int> p(String s) => [for (final x in s.split('.')) int.tryParse(x) ?? 0];
  final x = p(a), y = p(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d > 0;
  }
  return false;
}

/// The quiet dot on the 本机 chip: a version is on its way in and was not dismissed (K27).
bool updateBadge(UpdateInfo? u) =>
    u != null &&
    u.state != 'off' &&
    (u.needsReinstall || !u.dismissed && const {'downloading', 'ready', 'installing'}.contains(u.state));
