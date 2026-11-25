// The device panel's 终端 entry: which apps it folds in, and what tapping it opens (spec §2.1, §2.2).
import '../hub_client.dart';
import '../term/term_id.dart';

/// The entry's app id. Not `term:`, which [isTermApp] would take for a session.
const termsEntry = 'terms:';
const termsEntryName = '终端';

/// Bundle ids of the terminal apps the entry lists as 只能用画面看.
const terminalApps = {
  'com.apple.Terminal',
  'com.googlecode.iterm2',
  'com.mitchellh.ghostty',
  'com.github.wez.wezterm',
  'net.kovidgoyal.kitty',
  'org.alacritty',
  'dev.warp.Warp-Stable',
};

/// The device allows terminal sessions and the list came without an error.
bool showsTermsEntry(TermList? list) => list != null && !list.off && list.error == null;

/// `desktop:` first, the rest in order; with the entry shown, terminal apps live inside it instead.
List<HubApp> orderApps(List<HubApp> apps, {required bool entry}) => [
      ...apps.where((a) => a.app == 'desktop:'),
      for (final a in apps)
        if (a.app != 'desktop:' && !(entry && terminalApps.contains(a.app))) a,
    ];

List<HubApp> terminalAppsOf(List<HubApp> apps) => [for (final a in apps) if (terminalApps.contains(a.app)) a];

/// What tapping the entry opens.
sealed class TermsTarget {
  const TermsTarget();
}

/// A session row, by its `term:` id.
class OpenTerm extends TermsTarget {
  const OpenTerm(this.app, this.name);
  final String app, name;
}

/// A terminal app's picture session.
class OpenPixels extends TermsTarget {
  const OpenPixels(this.bundle, this.name);
  final String bundle, name;
}

/// Text mode with no text terminal yet: open one with [shell], the default shell's path (null for an old device).
class NewText extends TermsTarget {
  const NewText(this.shell);
  final String? shell;
}

class NoTerminal extends TermsTarget {
  const NoTerminal();
}

/// [mode] is `text` or `pixels`. Text mode opens the latest text terminal, else a new one when this
/// machine has launchers; text mode that can open nothing is treated as pixels.
/// A device explicitly without graphics always uses text, including a saved pixels preference.
TermsTarget termsTarget({required String mode, required TermList list, required List<HubApp> apps, bool graphical = true}) {
  if (mode == 'text' || !graphical) {
    TermRow? latest(String backend) {
      TermRow? out;
      for (final r in list.terms) {
        if (parseTermId(r.id)?.backend != backend) continue;
        if (out == null || r.activity > out.activity) out = r;
      }
      return out;
    }

    final pty = latest('pty');
    if (pty != null) return OpenTerm(pty.id, termDisplayName(pty.shown, pty.host));
    final local = list.hosts.where((h) => h.host == null).firstOrNull;
    if (local != null && local.launchers.isNotEmpty) {
      return NewText(local.shells?.where((s) => s.isDefault).firstOrNull?.path);
    }
  }
  if (!graphical) return const NoTerminal();
  final first = terminalAppsOf(apps).firstOrNull;
  return first == null ? const OpenPixels('com.apple.Terminal', 'Terminal') : OpenPixels(first.app, first.name);
}

/// What the overview's 常用 · 终端 opens: in text mode with local launchers always a new terminal, else [termsTarget].
TermsTarget termsNewTarget({required String mode, required TermList list, required List<HubApp> apps, bool graphical = true}) {
  if (mode == 'text' || !graphical) {
    final local = list.hosts.where((h) => h.host == null).firstOrNull;
    if (local != null && local.launchers.isNotEmpty) {
      return NewText(local.shells?.where((s) => s.isDefault).firstOrNull?.path);
    }
  }
  return termsTarget(mode: mode, list: list, apps: apps, graphical: graphical);
}
