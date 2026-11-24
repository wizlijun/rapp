import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/shares.dart';

void main() {
  test('the exact row the service sends', () {
    final r = ShareRow.fromJson({
      'port': 8000,
      'note': 'n',
      'allow': [],
      'addr': 'http://localhost:28000',
      'local': 28000,
      'web': true,
      'listening': true,
      'mine': true,
    });
    expect(r.addr, 'http://localhost:28000');
    expect(r.web, isTrue);
    expect(r.mine, isTrue);
  });

  test('a table from the service', () {
    final t = ShareTable.fromJson({
      'ok': true,
      'id': '123456789',
      'me': 'ab' * 32,
      'shares': [
        {
          'port': 8000,
          'note': 'dev',
          'allow': [
            {'fp': 'cd' * 32, 'name': '笔记本'}
          ],
          'addr': '',
          'web': true,
          'listening': true,
          'mine': false,
        },
        {
          'port': 22,
          'note': '',
          'allow': [],
          'addr': 'ssh -p 28001 localhost',
          'local': 28001,
          'web': false,
          'listening': false,
          'mine': true,
        },
      ],
      'known': [
        {'fp': 'ab' * 32, 'name': '本机'},
        {'fp': 'cd' * 32, 'name': '笔记本'},
      ],
    });
    expect(t.id, '123456789');
    expect(t.me, 'ab' * 32);
    expect(t.rows, hasLength(2));
    expect(t.rows[0].port, 8000);
    expect(t.rows[0].note, 'dev');
    expect(t.rows[0].allow.single.name, '笔记本');
    expect(t.rows[0].allow.single.fp, 'cd' * 32);
    expect(t.rows[0].web, isTrue);
    expect(t.rows[0].listening, isTrue);
    expect(t.rows[0].mine, isFalse);
    expect(t.rows[0].addr, isEmpty);
    expect(t.rows[1].addr, 'ssh -p 28001 localhost');
    expect(t.rows[1].web, isFalse);
    expect(t.rows[1].mine, isTrue);
    expect(t.known[0].name, '本机');
    expect(t.known, hasLength(2));
  });

  test('error words', () {
    String t(String s) => shareErrorText(ServiceException(s));
    for (final s in ['offline', 'no key', 'unknown name']) {
      expect(t(s), '离线，读不到它的端口');
    }
    expect(t('old version'), '对方的 rApp 还不支持分享端口');
    expect(t('policy'), '对方的策略不允许远程设置');
    expect(t('limit'), '最多分享 64 个端口');
    expect(t('bad port'), '端口号是 1 到 65535 的数字');
    expect(t('service not running'), '本机的 rApp 服务没有在运行');
    expect(t('service connection closed'), '本机的 rApp 服务没有在运行');
    expect(t('whatever'), '出错了：whatever');
    bool h(String s) => shareErrorHidesInput(ServiceException(s));
    for (final s in ['offline', 'old version', 'policy', 'service not running']) {
      expect(h(s), isTrue, reason: s);
    }
    expect(h('limit'), isFalse);
    expect(h('bad port'), isFalse);
  });

  test('port input', () {
    expect(parsePort('8000'), 8000);
    expect(parsePort(' 8000 '), 8000);
    expect(parsePort('65535'), 65535);
    for (final s in ['', '0', '65536', '80a', '８０００', '-1', '8000.0']) {
      expect(parsePort(s), isNull, reason: s);
    }
  });
}
