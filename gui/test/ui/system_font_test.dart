import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/system_font.dart';

void main() {
  test('gnomeFontPoints reads the size at the end of a GNOME font name', () {
    expect(gnomeFontPoints("'Cantarell 11'\n"), 11);
    expect(gnomeFontPoints("'Noto Sans CJK SC Medium 10.5'"), 10.5);
    expect(gnomeFontPoints("'Ubuntu'"), isNull);
    expect(gnomeFontPoints(''), isNull);
  });

  test('clampTextSize keeps odd settings inside 11–20', () {
    expect(clampTextSize(13), 13);
    expect(clampTextSize(6), 11);
    expect(clampTextSize(40), 20);
    expect(clampTextSize(double.nan), fallbackTextSize);
  });
}
