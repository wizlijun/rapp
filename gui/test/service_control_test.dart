import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/service_control.dart';

void main() {
  const plist = '/Users/u/Library/LaunchAgents/com.rapp.service.plist';

  test('plist path', () {
    expect(launchAgentPlistPath('/Users/u'), plist);
  });

  group('macOS', () {
    List<String> cmd(ServiceAction a) => serviceCommands(
      a,
      os: 'macos',
      uid: 501,
      home: '/Users/u',
      serviceExe: '/A/rapp.app/Contents/MacOS/rapp-service',
    ).map((c) => c.toString()).toList();

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
        final c = serviceCommands(
          a,
          os: 'linux',
          uid: 1000,
          home: '/home/u',
          serviceExe: '/opt/rapp/rapp-service',
        );
        expect(c.single.exe, 'systemctl');
        expect(c.single.args, [
          '--user',
          if (a == ServiceAction.start) ...['enable', '--now'] else a.name,
          'rapp-service.service',
        ]);
      });
    }
  });

  group('Linux service installation', () {
    late Directory tmp;
    late Map<String, String> env;
    late List<String> calls;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rapp-systemd-');
      env = {
        'HOME': tmp.path,
        'XDG_CONFIG_HOME': '${tmp.path}/config',
        'RAPP_HOME': '${tmp.path}/custom data',
      };
      calls = [];
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    ServiceController controller({String exe = '/portable/rapp-service', int reloadExit = 0}) =>
        ServiceController(
          serviceExe: exe,
          env: env,
          os: 'linux',
          runProcess: (cmd, args) async {
            calls.add('$cmd ${args.join(' ')}');
            expect(File(linuxServiceUnitPath(env)).existsSync(), isTrue);
            return ProcessResult(0, args.contains('daemon-reload') ? reloadExit : 0, '', '');
          },
        );

    test('start writes the unit before reloading and enabling it', () async {
      expect(await controller().run(ServiceAction.start), isNull);
      expect(calls, ['systemctl --user daemon-reload', 'systemctl --user enable --now rapp-service.service']);
      final unit = File(linuxServiceUnitPath(env)).readAsStringSync();
      expect(unit, contains('ExecStart=:/usr/bin/env -- "/portable/rapp-service"'));
      expect(unit, contains('Environment="RAPP_HOME=${tmp.path}/custom data"'));
      expect(unit, contains('Environment="XDG_CONFIG_HOME=${tmp.path}/config"'));
      expect(unit, contains('UMask=0077'));
      expect(unit, contains('WantedBy=default.target'));
    });

    test('restart creates a missing unit and follows a moved bundle', () async {
      expect(await controller().run(ServiceAction.restart), isNull);
      expect(calls.last, 'systemctl --user restart rapp-service.service');
      env.remove('RAPP_HOME');
      expect(await controller(exe: '/new location/rapp-service').run(ServiceAction.restart), isNull);
      final unit = File(linuxServiceUnitPath(env)).readAsStringSync();
      expect(unit, contains('ExecStart=:/usr/bin/env -- "/new location/rapp-service"'));
      expect(unit, contains('Environment="RAPP_HOME="'));
      expect(unit, isNot(contains('/custom data')));
    });

    test('reload failure does not attempt to start a stale service', () async {
      expect(await controller(reloadExit: 1).run(ServiceAction.start), contains('exit 1'));
      expect(calls, ['systemctl --user daemon-reload']);
    });

    test('stop does not create or rewrite a unit', () async {
      final c = ServiceController(
        serviceExe: '/unused',
        env: env,
        os: 'linux',
        runProcess: (cmd, args) async {
          calls.add('$cmd ${args.join(' ')}');
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(await c.run(ServiceAction.stop), isNull);
      expect(calls, ['systemctl --user stop rapp-service.service']);
      expect(File(linuxServiceUnitPath(env)).existsSync(), isFalse);
    });

    test('a configuration write error is returned to the UI', () async {
      File(env['XDG_CONFIG_HOME']!).writeAsStringSync('not a directory');
      expect(await controller().run(ServiceAction.start), startsWith('服务配置没写成功：'));
      expect(calls, isEmpty);
    });

    test('systemd accepts a portable path with spaces, quotes, dollars and percent signs', () async {
      final exe = '${tmp.path}/100% \$app "quoted"';
      Link(exe).createSync('/usr/bin/true');
      final unit = File('${tmp.path}/rapp-service.service');
      unit.writeAsStringSync(linuxServiceUnit(exe, {'RAPP_HOME': '${tmp.path}/data % "quoted"\nline'}));
      final r = await Process.run('/usr/bin/systemd-analyze', ['--user', 'verify', '--man=no', unit.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }, skip: !Platform.isLinux || !File('/usr/bin/systemd-analyze').existsSync());

    test('unit quoting preserves literal specifiers, dollars, quotes and newlines', () {
      final unit = linuxServiceUnit('/tmp/100%/\$app "x"/rapp-service', {
        'RAPP_HOME': '/tmp/a\nb%"c\\d',
        'SECRET': 'do-not-copy',
      });
      expect(unit, contains(r'ExecStart=:/usr/bin/env -- "/tmp/100%%/$app \"x\"/rapp-service"'));
      expect(unit, contains(r'Environment="RAPP_HOME=/tmp/a\nb%%\"c\\d"'));
      expect(unit, isNot(contains('do-not-copy')));
      expect(
        linuxServiceUnitPath({'HOME': '/u', 'XDG_CONFIG_HOME': ''}),
        '/u/.config/systemd/user/rapp-service.service',
      );
    });
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
      expect(
        p,
        contains('<key>StandardOutPath</key>\n\t<string>/Users/u/Library/Logs/rapp/launchd.log</string>'),
      );
      expect(
        p,
        contains('<key>StandardErrorPath</key>\n\t<string>/Users/u/Library/Logs/rapp/launchd.log</string>'),
      );
    });

    test('runs rapp-service with RunAtLoad and KeepAlive', () {
      final p = launchAgentPlist('/Applications/rapp.app/Contents/MacOS/rapp-service');
      expect(p, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(p, contains('<key>Label</key>\n\t<string>com.rapp.service</string>'));
      expect(
        p,
        contains(
          '<key>ProgramArguments</key>\n\t<array>\n'
          '\t\t<string>/Applications/rapp.app/Contents/MacOS/rapp-service</string>\n'
          '\t</array>',
        ),
      );
      expect(p, contains('<key>RunAtLoad</key>\n\t<true/>'));
      expect(p, contains('<key>KeepAlive</key>\n\t<true/>'));
      expect(p, isNot(contains('EnvironmentVariables')));
      expect(p, isNot(contains('StandardOutPath')));
      expect(p.trimRight(), endsWith('</plist>'));
    });

    test('escapes XML and passes environment when given', () {
      final p = launchAgentPlist('/tmp/a&b<c>/rapp-service', environment: {'RAPP_HOME': '/tmp/h'});
      expect(p, contains('<string>/tmp/a&amp;b&lt;c&gt;/rapp-service</string>'));
      expect(
        p,
        contains(
          '<key>EnvironmentVariables</key>\n\t<dict>\n\t\t<key>RAPP_HOME</key>\n\t\t<string>/tmp/h</string>\n\t</dict>',
        ),
      );
    });
  });

  test('ensurePrivateDir creates the folder, and tightens an existing one, to 0700', () {
    if (Platform.isWindows) return;
    final tmp = Directory.systemTemp.createTempSync('rapp-logs');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final fresh = '${tmp.path}/a/logs';
    ensurePrivateDir(fresh);
    String mode(String p) => (FileStat.statSync(p).mode & 0x1ff).toRadixString(8);
    expect(mode(fresh), '700');
    final open = Directory('${tmp.path}/open')..createSync();
    Process.runSync('chmod', ['755', open.path]);
    ensurePrivateDir(open.path);
    expect(mode(open.path), '700');
  });
}
