/// Hold to talk on a phone card (V1c Task 12): 「说一句」 and 「要改」. One [VoiceHold] per button; a recognised sentence
/// goes through the reply path, never a terminal view.
library;

import 'package:flutter/material.dart';

import '../embed/composer_model.dart';
import '../embed/voice_button.dart';
import '../embed/voice_overlay.dart';
import '../embed/voice_tidy_card.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'widgets.dart';

/// What a spoken reply does on a phone card.
enum ReplyVoiceUse { say, revise, assistant }

/// Owns one [VoiceHold] for [key2]: registers [send] and [edit] in `state.voiceSends` / `voiceEdits` while it is
/// mounted, and takes them (and the key's tidy) away on dispose. Without a recogniser (`state.voice == null`, V6) it
/// shows nothing. The overlay and the tidy card go in the root overlay, over the whole screen.
class PhoneVoice extends StatefulWidget {
  const PhoneVoice({
    super.key,
    required this.state,
    required this.key2,
    required this.send,
    required this.edit,
    required this.builder,
    this.ownTidyCard = true,
    this.tidy = true,
  });
  final MainState state;
  final Object key2;
  final VoiceSend send;

  /// 「编辑」: the words go to the draft of the session.
  final void Function(String text) edit;
  final Widget Function(BuildContext context, VoiceHold hold) builder;

  /// Draws the tidy card in its own overlay. False where another layer already draws that key's card.
  final bool ownTidyCard;

  /// False: the key's words never go to the AI tidy.
  final bool tidy;

  @override
  State<PhoneVoice> createState() => _PhoneVoiceState();
}

class _PhoneVoiceState extends State<PhoneVoice> {
  VoiceHold? _hold;
  final _portal = OverlayPortalController();
  VoiceSend? _mine;
  // The hold needs a composer to keep words in when it is cut short; a card has none, so this one is thrown away.
  final _composer = ComposerModel();

  MainState get _s => widget.state;

  @override
  void initState() {
    super.initState();
    final voice = _s.voice;
    if (voice == null) return;
    final k = widget.key2;
    // The widget at call time: a rebuild may bring a new card's closures under the same key.
    final mine = _mine = (text, origin) {
      final t = text.trim();
      return t.isEmpty ? voiceBlank : widget.send(t, origin);
    };
    _s.voiceSends[k] = mine;
    // Only a tidy card's 编辑 reads voiceEdits; a key with no tidy has none.
    if (widget.tidy) {
      _s.voiceEdits[k] = (text, ai) => widget.edit(text);
    } else {
      _s.voiceNoTidy.add(k);
    }
    _hold = VoiceHold(
      voice: voice,
      send: (text, heard) {
        final t = text.trim();
        return t.isEmpty ? voiceBlank : widget.send(t, VoiceOrigin(heard: heard));
      },
      edit: (text, heard) => widget.edit(text),
      composer: () => _composer,
      tidy: (text, pick, at, heard) => _s.tidyOf(k).begin(text, pick, at: at, heard: heard.heard),
      fix: (t) => _s.voiceFix(k, t),
      log: _s.voiceLog,
      wouldTidy: (text) => _s.tidyOf(k).would(text),
      onPress: () => _s.tidyIfAny(k)?.interrupt(),
      prefetch: (t) =>
          t == null ? _s.tidyIfAny(k)?.prefetch(null) : _s.tidyOf(k).prefetch(t),
    );
    _portal.show();
  }

  @override
  void dispose() {
    final h = _hold;
    if (h != null) {
      // A hold still going ends here as 取消 (a new card took this one's place, C6): the finger's later lift finds
      // nothing to release, and nothing is sent.
      h.cancel();
      h.dispose();
      if (identical(_s.voiceSends[widget.key2], _mine)) _s.voiceNoTidy.remove(widget.key2);
      _s.removeVoiceSend(widget.key2, only: _mine);
    }
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hold = _hold;
    final voice = _s.voice;
    if (hold == null || voice == null) return const SizedBox.shrink();
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        final tidy = _s.tidyOf(widget.key2);
        return Stack(children: [
          Positioned.fill(child: VoiceOverlay(hold: hold, voice: voice)),
          ListenableBuilder(
            listenable: hold,
            builder: (context, _) => hold.hint == null || hold.active
                ? const SizedBox.shrink()
                : Positioned(left: 12, right: 12, bottom: 96, child: Center(child: voiceHint(hold))),
          ),
          if (widget.ownTidyCard)
            ListenableBuilder(
              listenable: tidy,
              builder: (context, _) {
                final at = tidy.at;
                final size = MediaQuery.sizeOf(context);
                final w = (at?.width ?? size.width - 24).clamp(0.0, size.width - 24);
                return Positioned(
                  left: (at?.left ?? 12).clamp(12.0, size.width - 12 - w),
                  top: at?.top,
                  bottom: at == null ? 24 : null,
                  width: w,
                  child: VoiceTidyCard(tidy: tidy, tail: true),
                );
              },
            ),
        ]);
      },
      child: widget.builder(context, hold),
    );
  }
}

/// The wide hold-to-talk button of a card: 64 high, the microphone on the left, the label.
Widget phoneVoiceButton(VoiceHold hold, String label, {Key? key}) => voiceHoldArea(
      hold,
      child: ValueListenableBuilder<double>(
        valueListenable: hold.buttonOpacity,
        builder: (context, o, child) => Opacity(opacity: o, child: child),
        child: Builder(builder: (context) {
          final t = RappTokens.of(context);
          final style = Theme.of(context).textTheme.bodyMedium;
          return Semantics(
            button: true,
            label: label,
            excludeSemantics: true,
            child: Container(
              key: key ?? const Key('phone-voice'),
              constraints: const BoxConstraints(minHeight: phonePrimaryTap),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: t.raiseBox(),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.mic_none, color: t.text),
                const SizedBox(width: 8),
                Flexible(child: Text(label, style: style?.copyWith(color: t.text, fontWeight: FontWeight.w600))),
              ]),
            ),
          );
        }),
      ),
    );
