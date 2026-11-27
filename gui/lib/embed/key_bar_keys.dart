// The keys of the virtual key bar (iOS input toggle) and which of them each row holds at a given width and mode.
// Pure data and layout: the widget draws what keyBarRows says and sends what barKeys says.
import 'modifier_latch.dart';

enum BarKind { send, mod, copy, paste, cmdT, more }

/// One key. [wire] is the terminal wire name; [code] and [mods] the macOS key code and modifier bits for app sessions;
/// [bit] the latch bit of a mod key.
typedef BarKey = ({
  String id,
  String label,
  String spoken,
  BarKind kind,
  String? wire,
  int? code,
  int mods,
  int? bit,
  bool repeats,
});

const keyBarKeyHeight = 42.0;
const keyBarGap = 4.0;
const keyBarPad = 6.0;

double keyBarHeight(int rows) => rows * keyBarKeyHeight + (rows - 1) * keyBarGap + 2 * keyBarPad;

/// macOS key codes of the letters, for the ⌃-letter keys and ⌘T.
const macLetterCodes = <String, int>{'a':0,'s':1,'d':2,'f':3,'h':4,'g':5,'z':6,'x':7,'c':8,'v':9,'b':11,'q':12,'w':13,'e':14,'r':15,'y':16,'t':17,'o':31,'u':32,'i':34,'p':35,'l':37,'j':38,'k':40,'n':45,'m':46};

const barKeys = <String, BarKey>{
  'esc': (id: 'esc', label: 'Esc', spoken: 'Esc', kind: BarKind.send, wire: 'Esc', code: 53, mods: 0, bit: null, repeats: false),
  'stab': (id: 'stab', label: '⇧Tab', spoken: 'Shift Tab', kind: BarKind.send, wire: 'Shift-Tab', code: 48, mods: latchShift, bit: null, repeats: false),
  'tab': (id: 'tab', label: 'Tab', spoken: 'Tab', kind: BarKind.send, wire: 'Tab', code: 48, mods: 0, bit: null, repeats: false),
  'cc': (id: 'cc', label: '⌃C', spoken: 'Control C', kind: BarKind.send, wire: 'Ctrl-C', code: 8, mods: latchCtrl, bit: null, repeats: false),
  'cr': (id: 'cr', label: '⌃R', spoken: 'Control R', kind: BarKind.send, wire: 'Ctrl-R', code: 15, mods: latchCtrl, bit: null, repeats: false),
  'co': (id: 'co', label: '⌃O', spoken: 'Control O', kind: BarKind.send, wire: 'Ctrl-O', code: 31, mods: latchCtrl, bit: null, repeats: false),
  'ct': (id: 'ct', label: '⌃T', spoken: 'Control T', kind: BarKind.send, wire: 'Ctrl-T', code: 17, mods: latchCtrl, bit: null, repeats: false),
  'cb': (id: 'cb', label: '⌃B', spoken: 'Control B', kind: BarKind.send, wire: 'Ctrl-B', code: 11, mods: latchCtrl, bit: null, repeats: false),
  'cl': (id: 'cl', label: '⌃L', spoken: 'Control L', kind: BarKind.send, wire: 'Ctrl-L', code: 37, mods: latchCtrl, bit: null, repeats: false),
  'left': (id: 'left', label: '←', spoken: '左', kind: BarKind.send, wire: 'Left', code: 123, mods: 0, bit: null, repeats: true),
  'up': (id: 'up', label: '↑', spoken: '上', kind: BarKind.send, wire: 'Up', code: 126, mods: 0, bit: null, repeats: true),
  'down': (id: 'down', label: '↓', spoken: '下', kind: BarKind.send, wire: 'Down', code: 125, mods: 0, bit: null, repeats: true),
  'right': (id: 'right', label: '→', spoken: '右', kind: BarKind.send, wire: 'Right', code: 124, mods: 0, bit: null, repeats: true),
  'enter': (id: 'enter', label: '⏎', spoken: '回车', kind: BarKind.send, wire: 'Enter', code: 36, mods: 0, bit: null, repeats: false),
  'pgup': (id: 'pgup', label: 'PgUp', spoken: 'Page Up', kind: BarKind.send, wire: 'PageUp', code: 116, mods: 0, bit: null, repeats: false),
  'pgdn': (id: 'pgdn', label: 'PgDn', spoken: 'Page Down', kind: BarKind.send, wire: 'PageDown', code: 121, mods: 0, bit: null, repeats: false),
  'bksp': (id: 'bksp', label: '⌫', spoken: '删除', kind: BarKind.send, wire: 'Backspace', code: 51, mods: 0, bit: null, repeats: true),
  'ctrl': (id: 'ctrl', label: '⌃', spoken: 'Control', kind: BarKind.mod, wire: null, code: null, mods: 0, bit: latchCtrl, repeats: false),
  'opt': (id: 'opt', label: '⌥', spoken: 'Option', kind: BarKind.mod, wire: null, code: null, mods: 0, bit: latchOpt, repeats: false),
  'cmd': (id: 'cmd', label: '⌘', spoken: 'Command', kind: BarKind.mod, wire: null, code: null, mods: 0, bit: latchCmd, repeats: false),
  'copy': (id: 'copy', label: '⌘C', spoken: '复制', kind: BarKind.copy, wire: null, code: null, mods: 0, bit: null, repeats: false),
  'paste': (id: 'paste', label: '⌘V', spoken: '粘贴', kind: BarKind.paste, wire: null, code: null, mods: 0, bit: null, repeats: false),
  'cmdt': (id: 'cmdt', label: '⌘T', spoken: 'Command T', kind: BarKind.cmdT, wire: null, code: null, mods: 0, bit: null, repeats: false),
  'more': (id: 'more', label: '⋯', spoken: '更多按键', kind: BarKind.more, wire: null, code: null, mods: 0, bit: null, repeats: false),
};

/// The rows of the bar, each a list of key ids, grouped by what the key is for (key-bar-keys research, 2026-11-25).
/// First row, eight keys: complete and switch mode (Tab ⇧Tab), stop (Esc ⌃C), ⌫ ⏎, then ↑ and ⋯ (second row) at the
/// right end. [more] adds the second row (bar-cmd, 2026-11-27): copy and paste (shown as ⌘C ⌘V), ⌘T, the sticky ⌘ and
/// ⌃, PgUp PgDn (on a terminal a page of rApp's own history, in a full-screen program its keys), then ← ↓ → under ↑ ⋯,
/// the arrows as on a keyboard (user 2026-11-27: 「和普通键盘里面的上下左右是比较一致的视觉」). Any ⌃ key is the sticky ⌃
/// and a typed letter; on a terminal the sticky ⌘ and a letter is rApp's own shortcut. No ⌄: the 快捷区 folds from
/// its toggle beside 语音 and 输入 only (user 2026-11-27). The rows are the same for an app and a terminal; [app] is
/// kept for the callers that tell them apart.
List<List<String>> keyBarRows({required bool app, required bool more}) {
  const first = ['tab', 'stab', 'esc', 'cc', 'bksp', 'enter', 'up', 'more'];
  if (!more) return [first];
  return [
    first,
    ['copy', 'paste', 'cmdt', 'cmd', 'ctrl', 'pgup', 'pgdn', 'left', 'down', 'right'],
  ];
}

/// The bar's column grid: the arrow block's keys are each one column of [keyBarColumns] wide, so ↓ stands under ↑
/// and → under ⋯ whichever row is longer; the keys before them share what is left.
const keyBarColumns = 10;

const _arrowBlock = {'up', 'more', 'left', 'down', 'right'};

/// How many keys at the end of [ids] belong to the arrow block (one column wide each).
int keyBarTail(List<String> ids) {
  var n = 0;
  while (n < ids.length && _arrowBlock.contains(ids[ids.length - 1 - n])) {
    n++;
  }
  return n;
}
