# Sumi candidate presentation

Vendored from `mdeditor/tauri-plugin-native-editor/native` at
`83638b30ed03d5198ed7ef3da467aceafcf01a9f` (Apache-2.0, see LICENSE).
`candidates-view.h` preserves Sumi's typography, wrapping, local pagination,
original candidate indices and accessibility behavior.

Changes in `candidates-bridge.h`: defer `prepared` until Flutter has sized the
native editor, reject repeated `present` after an action, validate JSON index
and pagination types. The vendored files also use explicit types and strong local
references to satisfy the runner’s strict Objective-C warnings. `ComposerNative.m` supplies the editor's own font cascade,
text color and line height; no separate candidate palette or font is used.

The bridge is opt-in through NSTextInputClient's marked-text attribute marker.
It requires Fcitx5 for Sumi; ordinary input methods keep their normal candidates.
Only the focused, visible editor in the key window grants a lease. Closing,
hiding, loss of focus or heartbeat timeout releases it without altering text.
