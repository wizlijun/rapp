import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';

import 'fakes.dart';

Map<String, dynamic> _list(Map<String, dynamic> row) => {
      'id': 'm1',
      'terms': [
        {'id': 'term:pty:a', 'name': 'a', 'command': 'zsh', 'panes': 1, 'attached': 0, 'activity': 0, ...row}
      ],
    };

void main() {
  test('termListFromJson reads reply', () {
    expect(termListFromJson(_list({'reply': true}), 'm1').terms.single.reply, isTrue);
    expect(termListFromJson(_list({}), 'm1').terms.single.reply, isFalse);
  });

  group('replyTerm', () {
    late FakeTransport t;
    late HubClient hub;
    setUp(() {
      t = FakeTransport();
      hub = HubClient(t);
    });

    test('sends one cmd and resolves on term_replied', () async {
      final f = hub.replyTerm('m1', 'term:pty:a', seq: 7, keys: ['1']);
      final cmd = t.sent.last;
      expect(cmd, {'cmd': 'reply_term', 'id': 'm1', 'term': 'term:pty:a', 'seq': 7, 'keys': ['1'], 'req': anything});
      expect(t.sent.length, 1);
      t.emit({'event': 'term_replied', 'id': 'm1', 'term': 'term:pty:a', 'req': cmd['req']});
      await f;
    });

    test('writes text and enter only when given', () async {
      final f = hub.replyTerm('m1', 'term:pty:a', text: 'x', enter: true);
      expect(t.sent.last,
          {'cmd': 'reply_term', 'id': 'm1', 'term': 'term:pty:a', 'text': 'x', 'enter': true, 'req': anything});
      t.emit({'event': 'term_replied', 'id': 'm1', 'term': 'term:pty:a', 'req': t.sent.last['req']});
      await f;
    });

    test('throws the error word', () async {
      final f = hub.replyTerm('m1', 'term:pty:a', seq: 7);
      t.emit({'event': 'error', 'req': t.sent.last['req'], 'error': 'changed'});
      await expectLater(f, throwsA(isA<HubException>().having((e) => e.message, 'message', 'changed')));
    });
  });
}
