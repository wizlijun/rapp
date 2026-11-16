// Read-only Linux firewall diagnostics. Never changes rules or elevates on startup.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef FirewallCommand = Future<ProcessResult> Function(String executable, List<String> arguments);

class FirewallReport {
  const FirewallReport({this.ufwEnabled = false, this.blockedPeers = const [], this.journalChecked = false});
  final bool ufwEnabled;
  /// Recent incoming UFW drops for this machine's actual UDP listener.
  final List<String> blockedPeers;
  /// A successful query still cannot prove that a firewall allows the traffic.
  final bool journalChecked;
}

List<String> localFirewallAddresses(List<String> lanIds) => [
  for (final id in lanIds)
    if (id.contains('@'))
      if (Uri.tryParse('udp://${id.split('@').last}') case final Uri uri)
        if (InternetAddress.tryParse(uri.host.replaceAll('[', '').replaceAll(']', '')) case final InternetAddress ip)
          ip.address,
];

String? ufwAllowCommand(String peer, int port) {
  final ip = InternetAddress.tryParse(peer.trim());
  if (ip == null || port < 1 || port > 65535 || ip.address.contains('%')) return null;
  // Only a numeric single-device address can enter the copied command.
  return 'sudo ufw allow from ${ip.address} to any port $port proto udp';
}

List<String> recentFirewallBlocks(String jsonLines, {
  required int port,
  required List<String> localAddresses,
  required DateTime now,
}) {
  final peers = <String>{};
  final local = localAddresses.map(InternetAddress.tryParse).whereType<InternetAddress>().map((a) => a.address).toSet();
  for (final line in const LineSplitter().convert(jsonLines)) {
    try {
      final entry = jsonDecode(line);
      if (entry is! Map || entry['MESSAGE'] is! String) continue;
      final micros = int.tryParse('${entry['__REALTIME_TIMESTAMP']}');
      if (micros == null) continue;
      final age = now.microsecondsSinceEpoch - micros;
      if (age < 0 || age > const Duration(minutes: 10).inMicroseconds) continue;
      final message = entry['MESSAGE'] as String;
      if (!RegExp(r'\[UFW (BLOCK|REJECT)\]').hasMatch(message)) continue;
      final fields = {for (final m in RegExp(r'(?:^|\s)([A-Z]+)=([^\s]*)').allMatches(message)) m[1]!: m[2]!};
      if ((fields['IN'] ?? '').isEmpty || (fields['OUT'] ?? '').isNotEmpty ||
          fields['PROTO'] != 'UDP' || fields['DPT'] != '$port') {
        continue;
      }
      final dst = InternetAddress.tryParse(fields['DST'] ?? '');
      final src = InternetAddress.tryParse(fields['SRC'] ?? '');
      if (src != null && dst != null && local.contains(dst.address)) {
        peers.add(src.address);
      }
    } on FormatException {
      // One malformed/rotated journal line must not hide the remaining evidence.
    }
  }
  return peers.take(5).toList();
}

/// A bounded reader: authorization cancellation, missing tools and inaccessible
/// logs become an unknown result, never a false "port allowed" verdict.
Future<ProcessResult> runFirewallCommand(String executable, List<String> arguments, {Duration? timeout}) async {
  final process = await Process.start(executable, arguments, environment: {'LC_ALL': 'C'});
  final out = <int>[];
  final err = <int>[];
  var oversized = false;
  void collect(List<int> bytes, List<int> target) {
    if (out.length + err.length + bytes.length > 1024 * 1024) {
      oversized = true;
      process.kill(ProcessSignal.sigkill);
    } else {
      target.addAll(bytes);
    }
  }
  final outSubscription = process.stdout.listen((b) => collect(b, out));
  final errSubscription = process.stderr.listen((b) => collect(b, err));
  final stdoutDone = outSubscription.asFuture<void>();
  final stderrDone = errSubscription.asFuture<void>();
  try {
    return await (() async {
      final code = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      return ProcessResult(process.pid, oversized ? -1 : code,
          utf8.decode(out, allowMalformed: true), utf8.decode(err, allowMalformed: true));
    })().timeout(timeout ?? Duration(seconds: executable == '/usr/bin/pkexec' ? 90 : 5));
  } on TimeoutException {
    // A privileged pkexec child may no longer be signalable by this GUI. Do not
    // turn the original timeout into an unbounded wait for that child's exit.
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 1), onTimeout: () => -1);
    return ProcessResult(process.pid, -1, '', 'timeout');
  } finally {
    await Future.wait([outSubscription.cancel(), errSubscription.cancel()]);
  }
}

Future<FirewallReport> checkLinuxFirewall({
  required int port,
  required List<String> localAddresses,
  bool authorize = false,
  FirewallCommand run = runFirewallCommand,
  Future<String> Function()? readUfw,
  DateTime? now,
}) async {
  if (port < 1 || port > 65535) return const FirewallReport();
  var enabled = false;
  try {
    final config = await (readUfw ?? () => File('/etc/ufw/ufw.conf').readAsString())();
    enabled = RegExp(r'^\s*ENABLED\s*=\s*yes\s*(?:#.*)?$', multiLine: true, caseSensitive: false).hasMatch(config);
  } on FileSystemException {
    // UFW is not present or its configuration cannot be read.
  }
  final args = ['--dmesg', '--since=-10min', '--no-pager', '--output=json', '-n', '200',
    '--grep=\\[UFW (BLOCK|REJECT)\\].*PROTO=UDP.*DPT=$port(?: |\$)'];
  try {
    final result = await run(authorize ? '/usr/bin/pkexec' : '/usr/bin/journalctl',
        // Bound the privileged reader on the privileged side as well: after
        // elevation this GUI may not be allowed to signal it.
        authorize ? ['/usr/bin/timeout', '--kill-after=1s', '8s', '/usr/bin/journalctl', ...args] : args);
    if (result.exitCode == 0) {
      return FirewallReport(ufwEnabled: enabled, journalChecked: true,
        blockedPeers: recentFirewallBlocks('${result.stdout}', port: port, localAddresses: localAddresses, now: now ?? DateTime.now()));
    }
  } on ProcessException {
    // No journalctl/polkit, or authorization denied. Keep the actionable UDP hint.
  }
  return FirewallReport(ufwEnabled: enabled);
}
