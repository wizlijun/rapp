// Cell width of a code point: 0 for combining marks, 2 for East Asian wide and
// fullwidth, 1 for everything else (box drawing and ambiguous width included).

const List<(int, int)> _zero = [
  (0x0300, 0x036F),
  (0x1AB0, 0x1AFF),
  (0x1DC0, 0x1DFF),
  (0x200B, 0x200F),
  (0x20D0, 0x20FF),
  (0xFE00, 0xFE0F),
  (0xFE20, 0xFE2F),
];

const List<(int, int)> _wide = [
  (0x1100, 0x115F),
  (0x2E80, 0x303E),
  (0x3041, 0x33FF),
  (0x3400, 0x4DBF),
  (0x4E00, 0x9FFF),
  (0xA000, 0xA4CF),
  (0xAC00, 0xD7A3),
  (0xF900, 0xFAFF),
  (0xFE30, 0xFE4F),
  (0xFF00, 0xFF60),
  (0xFFE0, 0xFFE6),
  (0x1F300, 0x1F64F),
  (0x1F900, 0x1F9FF),
  (0x20000, 0x2FFFD),
  (0x30000, 0x3FFFD),
];

bool _inTable(List<(int, int)> table, int rune) {
  var lo = 0, hi = table.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final (a, b) = table[mid];
    if (rune < a) {
      hi = mid - 1;
    } else if (rune > b) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

int cellWidth(int rune) {
  if (rune < 0x300) return 1;
  if (_inTable(_zero, rune)) return 0;
  if (_inTable(_wide, rune)) return 2;
  return 1;
}
