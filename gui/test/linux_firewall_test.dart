import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/linux_firewall.dart';
import 'package:rapp/pages/linux_firewall_section.dart';
import 'package:rapp/service_client.dart';

void main() {
  final now = DateTime.utc(2026, 11, 16, 14);
  String log({String source = '10.17.0.235', String destination = '10.17.0.27',
    int port = 22028, String protocol = 'UDP', String input = 'wlo1', String output = '',
    int minutesAgo = 1, String action = 'BLOCK'}) => jsonEncode({
      '__REALTIME_TIMESTAMP': '${now.subtract(Duration(minutes: minutesAgo)).microsecondsSinceEpoch}',
      'MESSAGE': '[UFW $action] IN=$input OUT=$output SRC=$source DST=$destination PROTO=$protocol DPT=$port LEN=1208',
    });

  test('only recent incoming drops for our current UDP listener count', () {
    final text = [log(), log(), log(minutesAgo: 11), log(minutesAgo: -1),
      log(port: 22029), log(protocol: 'TCP'), log(destination: '10.17.0.99'),
      log(input: ''), log(output: 'wlo1'), log(source: 'not-an-ip'),
      log(source: '10.17.0.236', action: 'REJECT'), 'broken json'].join('\n');
    expect(recentFirewallBlocks(text, port: 22028, localAddresses: ['10.17.0.27'], now: now),
      ['10.17.0.235', '10.17.0.236']);
    expect(recentFirewallBlocks(text, port: 28001, localAddresses: ['10.17.0.27'], now: now), isEmpty);
  });

  test('IPv6 addresses and nondefault listener ports are supported', () {
    expect(localFirewallAddresses(['123@10.17.0.27:28001', '123@[fd00::1]:28001', '123']),
      ['10.17.0.27', 'fd00::1']);
    expect(recentFirewallBlocks(log(source: 'fd00::2', destination: 'fd00::1', port: 28001),
      port: 28001, localAddresses: ['fd00::1'], now: now), ['fd00::2']);
    expect(ServiceStatus.fromJson({'port': 28001}).port, 28001);
    expect(ServiceStatus.fromJson({'lan_ids': ['123@10.17.0.27:28002']}).port, 28002);
    expect(ServiceStatus.fromJson({'port': 0}).port, 22028);
    expect(ServiceStatus.fromJson({'port': 99999}).port, 22028);
  });

  test('copyable allow command accepts only a single numeric IP and valid port', () {
    expect(ufwAllowCommand('10.17.0.235', 28001), 'sudo ufw allow from 10.17.0.235 to any port 28001 proto udp');
    for (final peer in ['any', '10.17.0.0/24', '10.0.0.1; reboot', r'$(touch /tmp/no)', '']) {
      expect(ufwAllowCommand(peer, 22028), isNull);
    }
    expect(ufwAllowCommand('fd00::2', 22028), contains('from fd00::2'));
    expect(ufwAllowCommand('10.17.0.235', 65536), isNull);
  });

  test('passive check never elevates and unreadable logs do not mean allowed', () async {
    final commands = <String>[];
    final report = await checkLinuxFirewall(port: 28001, localAddresses: ['10.17.0.27'],
      readUfw: () async => 'ENABLED=yes\n', run: (exe, args) async {
        commands.add(exe);
        expect(args.join(' '), contains('DPT=28001'));
        return ProcessResult(1, 1, '', 'permission denied');
      });
    expect(commands, ['/usr/bin/journalctl']);
    expect(report.ufwEnabled, isTrue);
    expect(report.journalChecked, isFalse);
    expect(report.blockedPeers, isEmpty);
  });

  test('explicit authorization is read-only and filters evidence by port and destination', () async {
    final report = await checkLinuxFirewall(port: 22028, localAddresses: ['10.17.0.27'], now: now,
      authorize: true, readUfw: () async => 'ENABLED=no', run: (exe, args) async {
        expect(exe, '/usr/bin/pkexec');
        expect(args.take(4), ['/usr/bin/timeout', '--kill-after=1s', '8s', '/usr/bin/journalctl']);
        expect(args, contains('--dmesg'));
        return ProcessResult(1, 0, log(), '');
      });
    expect(report.blockedPeers, ['10.17.0.235']);
    expect(report.journalChecked, isTrue);
  });

  test('missing tools and cancelled authentication retain unknown status', () async {
    final report = await checkLinuxFirewall(port: 22028, localAddresses: [], authorize: true,
      readUfw: () async => throw const FileSystemException('missing'),
      run: (exe, args) async => throw ProcessException(exe, args));
    expect(report.ufwEnabled, isFalse);
    expect(report.journalChecked, isFalse);
  });

  test('diagnostic process timeouts return promptly and do not hang the UI', () async {
    final elapsed = Stopwatch()..start();
    final result = await runFirewallCommand('/usr/bin/sleep', ['60'], timeout: const Duration(milliseconds: 50));
    expect(result.exitCode, -1);
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
  }, skip: !Platform.isLinux);

  Future<void> pump(WidgetTester tester, FirewallCheck check, {int port = 22028}) =>
    tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), home: Scaffold(body: SingleChildScrollView(child:
      LinuxFirewallSection(port: port, localAddresses: const ['10.17.0.27'], check: check)))));

  testWidgets('known blocked peer prompts a scoped allow command without changing rules', (tester) async {
    final authorized = <bool>[];
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pump(tester, ({required port, required localAddresses, bool authorize = false}) async {
      authorized.add(authorize);
      return const FirewallReport(ufwEnabled: true, journalChecked: true, blockedPeers: ['10.17.0.235']);
    }, port: 28001);
    await tester.pumpAndSettle();
    expect(authorized, [false]);
    expect(find.textContaining('UFW 拦截了来自 10.17.0.235 的 UDP 28001'), findsOneWidget);
    await tester.tap(find.text('放行方法'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制命令'));
    await tester.pump();
    expect(copied, 'sudo ufw allow from 10.17.0.235 to any port 28001 proto udp');
    expect(authorized, [false]);
  });

  testWidgets('UFW enabled is a warning, no records never claims the port is open', (tester) async {
    final authorized = <bool>[];
    await pump(tester, ({required port, required localAddresses, bool authorize = false}) async {
      authorized.add(authorize);
      return FirewallReport(ufwEnabled: true, journalChecked: authorize);
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('检测到 UFW 已启用'), findsOneWidget);
    expect(find.textContaining('尚未确认拦截记录'), findsOneWidget);
    await tester.tap(find.text('授权检查拦截记录'));
    await tester.pumpAndSettle();
    expect(authorized, [false, true]);
    expect(find.text('未找到最近的 UFW 拦截记录，这不代表端口已放行。'), findsOneWidget);
  });

  testWidgets('a late check cannot show evidence for a previous listener', (tester) async {
    final old = Completer<FirewallReport>();
    Future<FirewallReport> check({required int port, required List<String> localAddresses, bool authorize = false}) async =>
      port == 22028 ? old.future : const FirewallReport();
    await pump(tester, check);
    await pump(tester, check, port: 28001);
    await tester.pumpAndSettle();
    old.complete(const FirewallReport(blockedPeers: ['10.17.0.235']));
    await tester.pumpAndSettle();
    expect(find.textContaining('10.17.0.235'), findsNothing);
    expect(find.textContaining('UDP 28001'), findsOneWidget);
  });
}
