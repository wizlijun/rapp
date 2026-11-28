import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/phone/home_model.dart';
import 'package:rapp/phone/reply_model.dart';
import 'package:rapp/ui/lamp.dart';

TermRow _row(String app, String state, String msg, {String? kind, bool reply = true, int seq = 7}) => TermRow(
      'd\nt', 'n', 'zsh', null, 1, 0, 100, false, false,
      ps: TermPs(state, app: app, kind: kind, msg: msg, seq: seq), reply: reply);

HomeItem _item(HomeKind kind, {String id = 'term\nmac\nt1', List<String>? points}) => HomeItem(
      kind: kind,
      id: id,
      lamp: Lamp.active,
      what: 'w',
      program: 'p',
      device: 'd',
      line: 'l',
      since: 0,
      button: HomeButton.goLook,
      points: points,
    );

CardReply _w(String app, String msg, {String? kind, bool reply = true, bool dev = true, List<String>? points}) =>
    replyOf(_item(HomeKind.waiting, points: points),
        row: _row(app, 'blocked', msg, kind: kind, reply: reply), deviceReply: dev);

void main() {
  test('cc permission gives allow and deny', () {
    final r = _w('claude-code', 'approve Bash: cargo test', kind: 'permission');
    expect(r.kind, ReplyKind.approve);
    expect(r.allow, ['1']);
    expect(r.deny, ['Esc']);
    expect(r.plain, '想跑测试');
    expect(r.quote, 'cargo test');
    expect(r.risk, isNull);
    expect(r.seq, 7);
    expect(r.target, const ReplyTarget('mac', 't1'));
  });
  test('git push is risky', () {
    final r = _w('claude-code', 'approve Bash: git push origin main', kind: 'permission');
    expect(r.risk?.word, '撤不回');
    expect(r.risk?.why, '推上去以后收不回来');
  });
  test('old device shows go-look only', () {
    expect(_w('claude-code', 'approve Bash: ls', kind: 'permission', dev: false).kind, ReplyKind.none);
  });
  test('session from old holder shows go-look only', () {
    expect(_w('claude-code', 'approve Bash: ls', kind: 'permission', reply: false).kind, ReplyKind.none);
  });
  test('center-only item shows go-look only', () {
    expect(replyOf(_item(HomeKind.waiting), row: null, deviceReply: true).kind, ReplyKind.none);
  });
  test('empty msg shows go-look only', () {
    expect(_w('claude-code', '', kind: 'permission').kind, ReplyKind.none);
  });
  test('codex permission is go-look only', () {
    expect(_w('codex', 'approve Bash: cargo test', kind: 'permission').kind, ReplyKind.none);
  });
  test('cc question gives numbered options', () {
    final r = _w('claude-code', 'answer: 用哪个 (甲 · 乙 · 丙)', kind: 'question');
    expect(r.kind, ReplyKind.options);
    expect(r.options, ['甲', '乙', '丙']);
    expect(r.optionKeys(1), ['2']);
  });
  test('cc plan with points gives review', () {
    final r = _w('claude-code', 'approve plan', kind: 'permission', points: ['a', 'b', 'c']);
    expect(r.kind, ReplyKind.review);
    expect(r.planOk, ['2']);
    expect(r.planRevise, ['3']);
  });
  test('cc plan without points is go-look only', () {
    expect(_w('claude-code', 'approve plan', kind: 'permission').kind, ReplyKind.none);
    expect(_w('claude-code', 'approve plan', kind: 'permission', points: []).kind, ReplyKind.none);
  });
  test('done gives voice', () {
    final r = replyOf(_item(HomeKind.done), row: _row('claude-code', 'done', 'ok'), deviceReply: true);
    expect(r.kind, ReplyKind.done);
    expect(r.voice, isTrue);
  });
  test('done on old device has no voice', () {
    final row = _row('claude-code', 'done', 'ok');
    expect(replyOf(_item(HomeKind.done), row: row, deviceReply: false).kind, ReplyKind.none);
    expect(replyOf(_item(HomeKind.done), row: _row('claude-code', 'done', 'ok', reply: false), deviceReply: true).voice, isFalse);
    expect(replyOf(_item(HomeKind.done), row: null, deviceReply: true).voice, isFalse);
    expect(replyOf(_item(HomeKind.done, id: 'x'), row: row, deviceReply: true).kind, ReplyKind.none);
  });
}
