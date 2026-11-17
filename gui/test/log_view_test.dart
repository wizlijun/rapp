import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/access_log.dart';
import 'package:rapp/log_view.dart';

LogEntry entry(Map<String, dynamic> ev, {LogKind? kind, int repeat = 0}) =>
    LogEntry.fromJson({'src': 'service', 'at': 'x', 'kind': kind?.wire, 'repeat': repeat == 0 ? null : repeat, 'raw': jsonEncode(ev)});

String two(int n) => n.toString().padLeft(2, '0');

void main() {
  test('time: today is HH:mm:ss, other days MM-dd HH:mm:ss', () {
    final now = DateTime(2026, 11, 18, 12, 0, 0);
    final today = DateTime(2026, 11, 18, 9, 5, 7);
    final yest = DateTime(2026, 11, 17, 23, 30, 11);
    expect(logLine(entry({'ts': today.toUtc().toIso8601String(), 'ev': 'x'}), now: now).time, '09:05:07');
    expect(logLine(entry({'ts': yest.toUtc().toIso8601String(), 'ev': 'x'}), now: now).time, '11-17 23:30:11');
  });

  test('rejected', () {
    final l = logLine(entry({'ev': 'rejected', 'peer': '5.6.7.8:51022', 'reason': 'wrong password'}, kind: LogKind.refused));
    expect(l.summary, '拒绝 5.6.7.8:51022 · wrong password');
    expect(l.warn, isTrue);
  });

  test('route failure uses the device name', () {
    final l = logLine(entry({'ev': 'route', 'lvl': 'warn', 'id': '111', 'path': 'relay', 'result': 'timeout'}, kind: LogKind.unreachable),
        nameOf: (id) => 'mini');
    expect(l.summary, '路由失败 mini · 中继 · timeout');
    expect(l.warn, isTrue);
  });

  test('session_end reuses the access-log wording', () {
    final ev = {'ev': 'session_end', 'reason': 'kicked', 'peer': '1.2.3.4'};
    final l = logLine(entry(ev));
    expect(l.summary, contains(historyRow(ev).result));
    expect(l.warn, isFalse);
  });

  test('unknown events fall back to ev · msg', () {
    expect(logLine(entry({'ev': 'zzz', 'msg': 'hi'})).summary, 'zzz · hi');
    expect(logLine(entry({'ev': 'zzz'})).summary, 'zzz');
  });

  test('presence and update', () {
    expect(logLine(entry({'ev': 'presence', 'id': '1', 'online': true}), nameOf: (_) => 'mini').summary, 'mini 上线');
    expect(logLine(entry({'ev': 'presence', 'id': '1', 'online': false}), nameOf: (_) => 'mini').summary, 'mini 离线');
  });

  test('repeat suffix', () {
    expect(logLine(entry({'ev': 'zzz'}, repeat: 4)).summary, endsWith('（又重复 4 次）'));
  });

  test('fields', () {
    final l = logLine(entry({
      'ts': '2026-11-17T15:30:11.204Z',
      'ev': 'x',
      'lvl': 'info',
      'peer': '5.6.7.8:51022',
      'path': 'direct',
      'reason': 'r',
      'sid': 's1',
      'secs': 989,
      'app': 'a',
      'foo': 'bar',
    }));
    expect(l.fields, [
      ('来源地址', '5.6.7.8:51022'),
      ('路径', '直连'),
      ('原因', 'r'),
      ('会话', 's1'),
      ('时长', '989 秒'),
      ('app', 'a'),
      ('foo', 'bar'),
    ]);
  });

  test('raw that does not parse', () {
    final e = LogEntry.fromJson({'src': 'hub', 'at': 'x', 'raw': 'half {"ev'});
    expect(e.fields, isEmpty);
    final l = logLine(e);
    expect(l.summary, 'half {"ev');
    expect(l.fields, isEmpty);
  });

  test('LogQuery omits null and false', () {
    expect(const LogQuery().toJson(), isEmpty);
    expect(const LogQuery(kind: LogKind.fault, before: 'b', q: 'x', limit: 5, problems: true, src: {'hub', 'service'}).toJson(),
        {'kind': 'fault', 'before': 'b', 'q': 'x', 'limit': 5, 'problems': true, 'src': ['hub', 'service']});
  });
}
