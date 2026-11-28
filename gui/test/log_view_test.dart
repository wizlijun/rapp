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

  test('presence', () {
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

  test('LogPage reads again; newer may come without events', () {
    final p = LogPage.fromJson({
      'events': [],
      'more': false,
      'newer': 'n~0~9',
      'again': [
        {'src': 'service', 'at': 'a~0~1', 'repeat': 7, 'raw': '{"ev":"auth_fail"}'},
      ],
    });
    expect(p.events, isEmpty);
    expect(p.newer, 'n~0~9');
    expect(p.older, isNull);
    expect(p.again.single.at, 'a~0~1');
    expect(p.again.single.repeat, 7);
    expect(LogPage.fromJson({'events': [], 'more': false}).again, isEmpty);
  });

  test('LogQuery omits null and false', () {
    expect(const LogQuery().toJson(), isEmpty);
    expect(const LogQuery(kind: LogKind.fault, before: 'b', q: 'x', limit: 5, problems: true, src: {'hub', 'service'}).toJson(),
        {'kind': 'fault', 'before': 'b', 'q': 'x', 'limit': 5, 'problems': true, 'src': ['hub', 'service']});
  });

  group('real emitter payloads', () {
    String sum(Map<String, dynamic> ev, {LogKind? kind}) => logLine(entry(ev, kind: kind), nameOf: (id) => 'mini').summary;

    test('request ok vs failed', () {
      expect(sum({'ev': 'request', 'lvl': 'info', 'peer': '1.2.3.4:5', 'path': 'lan', 'op': 'open', 'app': 'Safari', 'result': 'ok'}), '请求 1.2.3.4:5 · open · Safari');
      expect(sum({'ev': 'request', 'lvl': 'warn', 'peer': '1.2.3.4:5', 'op': 'open', 'result': 'no such app'}, kind: LogKind.refused),
          '请求失败 1.2.3.4:5 · open · no such app');
    });
    test('update_applied', () {
      expect(sum({'ev': 'update_applied', 'from': '0.13.1', 'to': '0.14.0', 'mode': 'upgrade'}), '更新已安装 0.13.1 → 0.14.0');
    });
    test('update_check', () {
      expect(sum({'ev': 'update_check', 'result': 'available', 'latest': '0.14.0'}), '检查更新 有新版本 · 0.14.0');
      expect(sum({'ev': 'update_check', 'result': 'up_to_date', 'latest': '0.14.0'}), '检查更新 已是最新 · 0.14.0');
      expect(sum({'ev': 'update_check', 'lvl': 'warn', 'result': 'failed', 'reason': 'network'}), '检查更新失败 network');
    });
    test('update_failed has the stage', () {
      expect(sum({'ev': 'update_failed', 'stage': 'install', 'reason': 'needs admin'}), '更新失败 install · needs admin');
    });
    test('worker_exit', () {
      expect(sum({'ev': 'worker_exit', 'app': 'term:', 'code': 0, 'reason': 'exited'}), 'worker 退出 term: · exited');
      expect(sum({'ev': 'worker_exit', 'app': 'term:', 'code': 2, 'reason': 'exited'}), 'worker 退出 term: · exited · 代码 2');
    });
    test('opened and closed', () {
      expect(sum({'ev': 'opened', 'sid': 3, 'id': '111', 'app': 'Safari', 'path': 'relay', 'host_name': 'mac'}), '已打开 mac · Safari · 中继');
      expect(sum({'ev': 'closed', 'sid': 3, 'id': '111', 'app': 'Safari', 'secs': 9, 'reason': 'user'}), '已关闭 mini · Safari · user');
    });
    test('不锁屏 events use the access-log wording', () {
      expect(sum({'ev': 'no_lock_set', 'lvl': 'info', 'by': 'local', 'on': true}), '打开了「不锁屏」');
      expect(sum({'ev': 'no_lock_set', 'lvl': 'info', 'by': '1a2b3c4d', 'peer': 'p', 'on': false}), '关掉了「不锁屏」');
      expect(sum({'ev': 'no_lock_refused', 'lvl': 'warn', 'reason': 'not supported'}), '拒绝改「不锁屏」：not supported');
      expect(sum({'ev': 'no_lock_hold_failed', 'lvl': 'warn', 'code': null, 'stderr': 'boom'}), '没能保持唤醒：boom');
    });
    test('map_refused', () {
      expect(sum({'ev': 'map_refused', 'id': '111', 'port': 8080, 'local': 29350, 'reason': 'unreachable'}, kind: LogKind.refused),
          '端口映射被拒绝 mini · 端口 8080 · unreachable');
      expect(sum({'ev': 'map_refused', 'local': 29350, 'reason': 'gone'}), '端口映射被拒绝 本地 29350 · gone');
    });
  });
}
