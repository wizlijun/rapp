import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/update.dart';

UpdateInfo info(String state,
        {String? latest = '0.5.0',
        int? progress,
        String? error,
        bool autoUpdate = true,
        bool needsConfirm = false,
        bool needsAdmin = false,
        bool dismissed = false}) =>
    UpdateInfo(
      current: '0.4.1',
      state: state,
      latest: latest,
      progress: progress,
      error: error,
      autoUpdate: autoUpdate,
      needsConfirm: needsConfirm,
      needsAdmin: needsAdmin,
      dismissed: dismissed,
    );

void main() {
  test('fromJson tolerates missing fields', () {
    final u = UpdateInfo.fromJson({'current': '0.4.1', 'state': 'idle'})!;
    expect(u.current, '0.4.1');
    expect(u.state, 'idle');
    expect(u.autoUpdate, isTrue);
    expect([u.checkUpdates, u.needsConfirm, u.needsAdmin, u.dismissed, u.canRollback], everyElement(isFalse));
    expect([u.latest, u.error, u.notes, u.page, u.progress], everyElement(isNull));
    expect(UpdateInfo.fromJson(null), isNull);
    expect(UpdateInfo.fromJson('x'), isNull);
  });

  test('fromJson reads every field', () {
    final u = UpdateInfo.fromJson({
      'current': '0.4.1',
      'state': 'ready',
      'latest': '0.5.0',
      'progress': 45,
      'error': null,
      'notes': 'n',
      'page': 'https://example.invalid/p',
      'auto_update': false,
      'check_updates': true,
      'needs_confirm': true,
      'needs_admin': true,
      'dismissed': true,
      'can_rollback': true,
    })!;
    expect(u.latest, '0.5.0');
    expect(u.progress, 45);
    expect(u.notes, 'n');
    expect(u.page, 'https://example.invalid/p');
    expect(u.autoUpdate, isFalse);
    expect([u.checkUpdates, u.needsConfirm, u.needsAdmin, u.dismissed, u.canRollback], everyElement(isTrue));
  });

  test('view per state', () {
    const a = UpdateAction.apply, any = UpdateAction.applyAnyway, d = UpdateAction.dismiss;
    const c = UpdateAction.check, o = UpdateAction.openPage;
    final cases = <(UpdateInfo, String, List<UpdateAction>)>[
      (info('off', latest: null), '开发构建，不检查更新', []),
      (info('idle', latest: null), '当前 0.4.1', [c]),
      (info('idle', latest: '0.4.1'), '当前 0.4.1 · 已是最新', [c]),
      (info('up_to_date', latest: '0.4.1'), '当前 0.4.1 · 已是最新', [c]),
      (info('checking'), '当前 0.4.1 · 正在检查', []),
      (info('downloading', progress: 45), '正在下载 0.5.0（45%）', []),
      (info('ready'), '0.5.0 已下载，没人在用时会自动装好', [a, d]),
      (info('ready', autoUpdate: false), '0.5.0 已下载', [a, d]),
      (info('ready', needsConfirm: true), '这一版换了签名，装上以后要重新授权屏幕录制和辅助功能', [any, d]),
      (info('ready', needsAdmin: true), '这次需要管理员密码', [o, d]),
      (info('installing'), '正在安装 0.5.0', []),
      (info('failed', error: '大小不对'), '升级没有完成：大小不对', [c]),
      (info('idle', dismissed: true), '当前 0.4.1 · 0.5.0 先不装', [c]),
    ];
    for (final (u, line, actions) in cases) {
      final v = updateView(u);
      expect(v.line, line, reason: u.state);
      expect(v.actions, actions, reason: line);
    }
  });

  test('badge only while an update is pending', () {
    for (final s in ['downloading', 'ready', 'installing']) {
      expect(updateBadge(info(s)), isTrue, reason: s);
    }
    expect(updateBadge(info('ready', dismissed: true)), isFalse);
    for (final s in ['up_to_date', 'failed', 'off', 'idle', 'checking']) {
      expect(updateBadge(info(s)), isFalse, reason: s);
    }
    expect(updateBadge(null), isFalse);
  });
}
