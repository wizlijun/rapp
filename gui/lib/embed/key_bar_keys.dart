// The keys of the virtual key bar (iOS input toggle) and which of them each row holds at a given width and mode.
// Pure data and layout: the widget draws what keyBarRows says and sends what barKeys says.
import 'modifier_latch.dart';

enum BarKind { send, mod, copy, paste, more }

/// One key. [wire] is the terminal wire name; [code] and [mods] the macOS key code and modifier bits for app sessions;
/// [bit] the latch bit of a mod key; [alt] the id of the swipe-up key.
typedef BarKey = ({
  String id,
  String label,
  String spoken,
  BarKind kind,
  String? wire,
  int? code,
  int mods,
  int? bit,
  String? alt,
  bool repeats,
});

const keyBarKeyHeight = 42.0;
const keyBarGap = 4.0;
const keyBarPad = 6.0;

double keyBarHeight(int rows) => rows * keyBarKeyHeight + (rows - 1) * keyBarGap + 2 * keyBarPad;

/// macOS key codes of the letters, for the ⌃-letter keys.
const macLetterCodes = <String, int>{'a':0,'s':1,'d':2,'f':3,'h':4,'g':5,'z':6,'x':7,'c':8,'v':9,'b':11,'q':12,'w':13,'e':14,'r':15,'y':16,'t':17,'o':31,'u':32,'i':34,'p':35,'l':37,'j':38,'k':40,'n':45,'m':46};

const barKeys = <String, BarKey>{
  'esc': (id: 'esc', label: 'Esc', spoken: 'Esc', kind: BarKind.send, wire: 'Esc', code: 53, mods: 0, bit: null, alt: null, repeats: false),
  'stab': (id: 'stab', label: '⇧Tab', spoken: 'Shift Tab', kind: BarKind.send, wire: 'Shift-Tab', code: 48, mods: latchShift, bit: null, alt: null, repeats: false),
  'tab': (id: 'tab', label: 'Tab', spoken: 'Tab', kind: BarKind.send, wire: 'Tab', code: 48, mods: 0, bit: null, alt: null, repeats: false),
  'cc': (id: 'cc', label: '⌃C', spoken: 'Control C', kind: BarKind.send, wire: 'Ctrl-C', code: 8, mods: latchCtrl, bit: null, alt: null, repeats: false),
  'cr': (id: 'cr', label: '⌃R', spoken: 'Control R', kind: BarKind.send, wire: 'Ctrl-R', code: 15, mods: latchCtrl, bit: null, alt: null, repeats: false),
  'co': (id: 'co', label: '⌃O', spoken: 'Control O', kind: BarKind.send, wire: 'Ctrl-O', code: 31, mods: latchCtrl, bit: null, alt: null, repeats: false),
  'ct': (id: 'ct', label: '⌃T', spoken: 'Control T', kind: BarKind.send, wire: 'Ctrl-T', code: 17, mods: latchCtrl, bit: null, alt: null, repeats: false),
  'cb': (id: 'cb', label: '⌃B', spoken: 'Control B', kind: BarKind.send, wire: 'Ctrl-B', code: 11, mods: latchCtrl, bit: null, alt: null, repeats: false),
  'cl': (id: 'cl', label: '⌃L', spoken: 'Control L', kind: BarKind.send, wire: 'Ctrl-L', code: 37, mods: latchCtrl, bit: null, alt: null, repeats: false),
  'left': (id: 'left', label: '←', spoken: '左', kind: BarKind.send, wire: 'Left', code: 123, mods: 0, bit: null, alt: 'home', repeats: true),
  'up': (id: 'up', label: '↑', spoken: '上', kind: BarKind.send, wire: 'Up', code: 126, mods: 0, bit: null, alt: 'pgup', repeats: true),
  'down': (id: 'down', label: '↓', spoken: '下', kind: BarKind.send, wire: 'Down', code: 125, mods: 0, bit: null, alt: 'pgdn', repeats: true),
  'right': (id: 'right', label: '→', spoken: '右', kind: BarKind.send, wire: 'Right', code: 124, mods: 0, bit: null, alt: 'end', repeats: true),
  'enter': (id: 'enter', label: '⏎', spoken: '回车', kind: BarKind.send, wire: 'Enter', code: 36, mods: 0, bit: null, alt: null, repeats: false),
  'home': (id: 'home', label: 'Home', spoken: 'Home', kind: BarKind.send, wire: 'Home', code: 115, mods: 0, bit: null, alt: null, repeats: false),
  'end': (id: 'end', label: 'End', spoken: 'End', kind: BarKind.send, wire: 'End', code: 119, mods: 0, bit: null, alt: null, repeats: false),
  'pgup': (id: 'pgup', label: 'PgUp', spoken: 'Page Up', kind: BarKind.send, wire: 'PageUp', code: 116, mods: 0, bit: null, alt: null, repeats: false),
  'pgdn': (id: 'pgdn', label: 'PgDn', spoken: 'Page Down', kind: BarKind.send, wire: 'PageDown', code: 121, mods: 0, bit: null, alt: null, repeats: false),
  'bksp': (id: 'bksp', label: '⌫', spoken: '删除', kind: BarKind.send, wire: 'Backspace', code: 51, mods: 0, bit: null, alt: null, repeats: true),
  'ctrl': (id: 'ctrl', label: '⌃', spoken: 'Control', kind: BarKind.mod, wire: null, code: null, mods: 0, bit: latchCtrl, alt: null, repeats: false),
  'opt': (id: 'opt', label: '⌥', spoken: 'Option', kind: BarKind.mod, wire: null, code: null, mods: 0, bit: latchOpt, alt: null, repeats: false),
  'cmd': (id: 'cmd', label: '⌘', spoken: 'Command', kind: BarKind.mod, wire: null, code: null, mods: 0, bit: latchCmd, alt: null, repeats: false),
  'copy': (id: 'copy', label: '⌘C', spoken: '复制', kind: BarKind.copy, wire: null, code: null, mods: 0, bit: null, alt: null, repeats: false),
  'paste': (id: 'paste', label: '⌘V', spoken: '粘贴', kind: BarKind.paste, wire: null, code: null, mods: 0, bit: null, alt: null, repeats: false),
  'more': (id: 'more', label: '⋯', spoken: '更多按键', kind: BarKind.more, wire: null, code: null, mods: 0, bit: null, alt: null, repeats: false),
};

/// The rows of the bar, each a list of key ids, grouped by what the key is for (key-bar-keys research, 2026-11-25).
/// First row, ten keys: complete and switch mode (Tab ⇧Tab), stop (Esc ⌃C), more keys (⌃ ⋯), choose (↑ ↓), then ⌫
/// and ⏎ at the right end. [more] adds the second row: copy and paste (shown as ⌘C ⌘V), ⌥ (and ⌘ for an app), ← →,
/// then the ⌃ keys by how often the agent CLIs use them. Any other ⌃ key is the sticky ⌃ and a typed letter.
List<List<String>> keyBarRows({required bool app, required bool more}) {
  const first = ['tab', 'stab', 'esc', 'cc', 'ctrl', 'more', 'up', 'down', 'bksp', 'enter'];
  if (!more) return [first];
  return [
    first,
    [
      'copy', 'paste',
      'opt', if (app) 'cmd',
      'left', 'right',
      'co', 'cr', 'ct', 'cb', 'cl',
    ],
  ];
}
