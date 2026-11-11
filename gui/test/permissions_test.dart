import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/permissions.dart';

void main() {
  test('missing permissions from the service map', () {
    expect(missingPermissions({'screen_recording': false, 'accessibility': true}), [Permission.screenRecording]);
    expect(missingPermissions({'screen_recording': true, 'accessibility': true}), isEmpty);
    expect(missingPermissions({'screen_recording': false, 'accessibility': false}),
        [Permission.screenRecording, Permission.accessibility]);
    // Hosts that do not report permissions (old, Windows, Omarchy) show nothing.
    expect(missingPermissions(null), isEmpty);
    expect(missingPermissions('x'), isEmpty);
  });

  test('missing permissions from an open error', () {
    const e = 'rapp-host exited: missing permission: Screen Recording, Accessibility\n'
        'Allow rapp (or the terminal running rapp-host) under System Settings > Privacy & Security, then connect again.';
    expect(missingFromError(e), [Permission.screenRecording, Permission.accessibility]);
    expect(missingFromError('rapp-host exited: missing permission: Accessibility'), [Permission.accessibility]);
    expect(missingFromError('bad password'), isNull);
  });

  test('names, purposes and settings links', () {
    expect(Permission.screenRecording.label, '屏幕录制');
    expect(Permission.accessibility.label, '辅助功能');
    expect(Permission.screenRecording.purpose, '把这台电脑上 app 窗口的画面传给另一台电脑');
    expect(Permission.accessibility.purpose, '让另一台电脑的鼠标键盘操作这里的 app，并移动窗口、使用菜单');
    expect(Permission.screenRecording.settingsUrl,
        'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture');
    expect(Permission.accessibility.settingsUrl,
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility');
  });

  test('remote hint says what is missing and where to fix it', () {
    expect(remoteHint('mac-a', [Permission.screenRecording, Permission.accessibility]),
        '「mac-a」缺少 屏幕录制、辅助功能 权限。请在那台电脑上打开 rapp，在 本机 › 权限 里点「打开系统设置」。');
  });
}
