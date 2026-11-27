import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// T1: the phone shell takes colours, fonts and corner radii from the tokens only.
void main() {
  test('lib/phone has no hard-coded colours, fonts or radii', () {
    final files = Directory('lib/phone').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
    expect(files, isNotEmpty);
    final forbidden = {
      'Color(': RegExp(r'\bColor\('),
      'Colors.': RegExp(r'\bColors\.'),
      'fontFamily:': RegExp(r'fontFamily:'),
      'BorderRadius.circular(<digit>': RegExp(r'BorderRadius\.circular\(\s*\d'),
    };
    final hits = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        for (final e in forbidden.entries) {
          if (e.value.hasMatch(code)) hits.add('${f.path}:${i + 1} ${e.key}');
        }
      }
    }
    expect(hits, isEmpty);
  });
}
