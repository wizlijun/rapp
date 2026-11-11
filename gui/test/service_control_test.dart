import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/service_control.dart';

void main() {
  const plist = '/Users/u/Library/LaunchAgents/com.rapp.service.plist';

  test('plist path', () {
    expect(launchAgentPlistPath('/Users/u'), plist);
  });

  group('macOS', () {
    List<String> cmd(ServiceAction a) => serviceCommands(a,
            os: 'macos', uid: 501, home: '/Users/u', serviceExe: '/A/rapp.app/Contents/MacOS/rapp-service')
        .map((c) => c.toString())
        .toList();

    test('start bootstraps the LaunchAgent', () {
      expect(cmd(ServiceAction.start), ['launchctl bootstrap gui/501 $plist']);
    });
    test('stop boots it out by label', () {
      expect(cmd(ServiceAction.stop), ['launchctl bootout gui/501/com.rapp.service']);
    });
    test('restart kickstarts with -k', () {
      expect(cmd(ServiceAction.restart), ['launchctl kickstart -k gui/501/com.rapp.service']);
    });
  });

  group('linux', () {
    for (final a in ServiceAction.values) {
      test('${a.name} uses systemctl --user', () {
        final c = serviceCommands(a, os: 'linux', uid: 1000, home: '/home/u', serviceExe: '/opt/rapp/rapp-service');
        expect(c.single.exe, 'systemctl');
        expect(c.single.args, ['--user', a.name, 'rapp-service.service']);
      });
    }
  });

  group('windows', () {
    const exe = r'C:\rapp\rapp-service.exe';
    List<ShellCommand> cmd(ServiceAction a) =>
        serviceCommands(a, os: 'windows', uid: 0, home: r'C:\Users\u', serviceExe: exe);

    test('start registers Run key and launches detached', () {
      final c = cmd(ServiceAction.start);
      expect(c.first.exe, 'reg');
      expect(c.first.args, [
        'add',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'rapp-service',
        '/t',
        'REG_SZ',
        '/d',
        '"$exe"',
        '/f',
      ]);
      expect(c.last.exe, exe);
      expect(c.last.detached, isTrue);
    });
    test('stop uses taskkill', () {
      expect(cmd(ServiceAction.stop).single.toString(), 'taskkill /IM rapp-service.exe /F');
    });
    test('restart is stop then launch', () {
      final c = cmd(ServiceAction.restart);
      expect(c.first.exe, 'taskkill');
      expect(c.last.exe, exe);
      expect(c.last.detached, isTrue);
    });
  });

  group('openFolderCommand', () {
    test('open on macOS, explorer on Windows, xdg-open elsewhere', () {
      expect('${openFolderCommand('/l', 'macos')}', 'open /l');
      expect('${openFolderCommand(r'C:\l', 'windows')}', r'explorer C:\l');
      expect('${openFolderCommand('/l', 'linux')}', 'xdg-open /l');
    });
  });

  group('launchAgentPlist', () {
    test('sends launchd stdout and stderr to the log file when given', () {
      final p = launchAgentPlist('/x/rapp-service', logPath: '/Users/u/Library/Logs/rapp/launchd.log');
      expect(p, contains('<key>StandardOutPath</key>\n\t<string>/Users/u/Library/Logs/rapp/launchd.log</string>'));
      expect(p, contains('<key>StandardErrorPath</key>\n\t<string>/Users/u/Library/Logs/rapp/launchd.log</string>'));
    });

    test('runs rapp-service with RunAtLoad and KeepAlive', () {
      final p = launchAgentPlist('/Applications/rapp.app/Contents/MacOS/rapp-service');
      expect(p, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(p, contains('<key>Label</key>\n\t<string>com.rapp.service</string>'));
      expect(
          p,
          contains('<key>ProgramArguments</key>\n\t<array>\n'
              '\t\t<string>/Applications/rapp.app/Contents/MacOS/rapp-service</string>\n'
              '\t</array>'));
      expect(p, contains('<key>RunAtLoad</key>\n\t<true/>'));
      expect(p, contains('<key>KeepAlive</key>\n\t<true/>'));
      expect(p, isNot(contains('EnvironmentVariables')));
      expect(p, isNot(contains('StandardOutPath')));
      expect(p.trimRight(), endsWith('</plist>'));
    });

    test('escapes XML and passes environment when given', () {
      final p = launchAgentPlist('/tmp/a&b<c>/rapp-service', environment: {'RAPP_HOME': '/tmp/h'});
      expect(p, contains('<string>/tmp/a&amp;b&lt;c&gt;/rapp-service</string>'));
      expect(p, contains('<key>EnvironmentVariables</key>\n\t<dict>\n\t\t<key>RAPP_HOME</key>\n\t\t<string>/tmp/h</string>\n\t</dict>'));
    });
  });
}
