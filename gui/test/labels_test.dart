import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/labels.dart';

void main() {
  test('a table drops empty and malformed labels and keeps the rest', () {
    final t = LabelTable.fromJson({
      'rev': 3,
      'labels': {
        'a': {'title': '写作', 'note': ''},
        'b': {'title': '', 'note': ''},
        'c': 'junk',
        'd': {'note': '只有备注'},
      },
    });
    expect(t.rev, 3);
    expect(t.labels, {'a': const SessionLabel(title: '写作'), 'd': const SessionLabel(note: '只有备注')});
    expect(LabelTable.fromJson({}).labels, isEmpty);
  });

  test('title: trimmed, one line, at most 64 characters (counted as the service counts them)', () {
    expect(cleanLabelTitle('  写作 ').value, '写作');
    expect(cleanLabelTitle('a\nb').error, '标题只能是一行');
    expect(cleanLabelTitle('字' * 64).value, '字' * 64);
    expect(cleanLabelTitle('😀' * 64).value, isNotNull, reason: 'an emoji is one character, not two');
    expect(cleanLabelTitle('字' * 65).error, '标题最多 64 个字');
  });

  test('note: line breaks and tabs fold to spaces, at most 200 characters, no other control characters', () {
    expect(cleanLabelNote('第一行\r\n第二行\t完').value, '第一行  第二行 完');
    expect(cleanLabelNote('响\u0007铃').error, '备注里有不能显示的字符');
    expect(cleanLabelNote('x' * 200).value, hasLength(200));
    expect(cleanLabelNote('x' * 201).error, '备注最多 200 个字');
  });
}
