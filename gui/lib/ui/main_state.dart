// The single source of UI state for the main window.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import '../paths.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../embed/phrases.dart';
import '../embed/remote_session.dart';
import '../embed/session_port.dart';
import '../embed/stream_choice.dart';
import '../embed/voice_input.dart';
import '../embed/voice_button.dart' show sendVoice, voiceBlocked;
import '../embed/tidy_held.dart';
import '../embed/voice_tidy.dart';
import '../embed/linux_speech.dart';
import '../embed/voice_key_gate.dart';
import '../embed/traffic_label.dart' show segments;
import '../history/input_history.dart';
import '../history/input_recorder.dart';
import '../hub_client.dart';
import '../permissions.dart';
import '../embed/app_profile.dart';
import '../embed/composer_model.dart';
import '../embed/modifier_latch.dart';
import '../term/term_id.dart';
import '../term/term_session_port.dart';
import '../term/term_wire.dart' show TermPane;
import 'app_profile_store.dart';
import 'lamp.dart';
import 'term_status.dart' show programLamp, programWord, termAskWord;
import 'lifecycle.dart';
import 'net_marker.dart' show weakRttMs;
import 'pin_files.dart';
import 'prefs.dart';
import '../embed/composer_editor.dart' show ZoomKey;
import '../embed/tidy_diff.dart' show LearnAction, LearnItem, editLearns;
import '../embed/voice_fix.dart';
import 'project_positions.dart';
import '../llm_api.dart';
import 'projects.dart';
import 'resources_state.dart';
import '../embed/tidy_mode.dart';
import 'session_model.dart';
import 'terms_entry.dart';
import 'tokens.dart';
import 'unlock.dart';
import 'workspace_store.dart';

export 'lifecycle.dart' show hubWord, hubWords;

enum PanelTab { sessions, devices, projects, resources }

/// The two top-bar corners; at most one is open.
/// The top bar's popovers: the stream menu, 需要你, 本机, 远程, and the session list.
enum Corner { stream, needs, session, remote, sessions, hints }

/// One line of the status queue (the hint's ▾ list): what rApp said in the hint, or a change a program on some
/// device reported ([device] and [app] name its session, [title] its shown name, [lamp] its state).
/// [inferred]: read off the screen by rules rather than reported by the program (GUI apps, not built yet).
class HintRecord {
  const HintRecord(this.text, this.at, {this.device, this.app, this.title, this.lamp, this.inferred = false});
  final String text;
  final DateTime at;
  final String? device, app, title;
  final Lamp? lamp;
  final bool inferred;

  /// Whether a tap goes to a session.
  bool get goes => device != null && app != null;
}

enum NeedKind { session, device, terminal }

/// One thing waiting for the person: a disconnected session ([target] its record key) or a
/// device that dropped ([target] its id), or a text terminal blocked on the person ([target] its session id,
/// [device] its device, [title] its shown name). Newer [seq] first.
class NeedItem {
  const NeedItem(this.kind, this.target, this.text, this.seq, {this.reconnectWord = '重连', this.device, this.title});
  final String reconnectWord;
  final String? device, title;
  final NeedKind kind;
  final String target;
  final String text;
  final int seq;
}

class DeviceProbe {
  DeviceProbe(this.lamp, this.word, {this.apps, this.error});
  Lamp lamp;
  String word;
  AppList? apps;
  String? error;
}

/// Why a terminal session cannot open on a GUI without a terminal port.
const noTermPortWord = '这台主控台还不能看终端会话';

class LockBanner {
  const LockBanner(this.text, this.action);
  final String text;
  final String action;
}

/// A line about what A just did around this session (v13 host hints): a window of another app
/// covers where the click went, or a click opened another app. Its buttons act on it.
class HostNotice {
  const HostNotice.covered(this.text, {required this.coverId, required this.dismissable, required this.desktop})
      : bundle = null,
        name = null;
  const HostNotice.opened(this.text, {required String this.bundle, required String this.name})
      : coverId = null,
        dismissable = false,
        desktop = false;
  final String text;
  /// The cover's id for 「关掉它」 (null: an opened app).
  final int? coverId;
  /// A says the cover may be closed for the user (never a security or password prompt).
  final bool dismissable;
  /// 「在桌面会话里处理」 is offered (not from the desktop session itself).
  final bool desktop;
  /// The opened app 「打开」 opens or switches to.
  final String? bundle;
  final String? name;
}

/// How long a host notice stays unless acted on or closed.
const hostNoticeFor = Duration(seconds: 15);

String coveredText(String name) => 'A 上「$name」的弹窗挡住了点击';
String openedText(String name) => 'A 上打开了「$name」';

const desktopLockText = '远程电脑已锁屏；输入系统密码解锁';
const childLockText = '远程电脑已锁屏；请在主窗口输入系统密码解锁';

/// A screen was plugged into A while its desktop is open: it is not opened by itself.
const screenAddedHint = 'A 多了一块屏，在顶栏的屏幕菜单里切过去';

class MainState extends ChangeNotifier {
  MainState({
    required this.hub,
    this.hubError,
    required this.data,
    required this.prefs,
    this.port,
    this.termPort,
    this.doubleClick = const Duration(milliseconds: 500),
    DateTime Function()? clock,
    AppProfileStore? profiles,
    UnlockStore? unlockStore,
    void Function(String line)? log,
    VoiceInput? voice,
    LlmApi? llmApi,
  })  : resources = ResourcesState(clock: clock),
        voice = voice ??
            (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS
                ? VoiceInput()
                : defaultTargetPlatform == TargetPlatform.linux
                    ? VoiceInput(channel: LinuxSpeechChannel(), finalWait: LinuxSpeechChannel.finalResultWait)
                    : null),
        unlockStore = unlockStore ?? UnlockStore(),
        _now = clock ?? DateTime.now,
        positions = ProjectPositions.load(data.localDir),
        llm = LlmEndpoint.load(data.localDir),
        llmApi = llmApi ?? const LlmApi(),
        _log = log ?? ((_) {}) {
    recorder = InputRecorder(data: () => data, enabled: () => prefs.inputHistory,
        recordsApp: (a) => this.profiles.resolve(a).recordInput,
        log: _log, clock: clock);
    history = InputHistory(data: () => data, log: _log);
    _writtenSub = recorder.written.listen(history.add);
    recorder.onSent = history.remember;
    this.voice?.hotwords = voiceHotwords;
    _refreshHotwords();
    _loadRules();
    resources.addListener(notifyListeners);
    _portSub = port?.events.listen(_onPortEvent);
    _termSub = termPort?.events.listen(_onPortEvent);
    if (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux) port?.setVoiceHotkey(prefs.voiceHotkey);
    hub?.addListener(_onHub);
    hub?.askNet();
    _lastError = hub?.lastError;
    _netLevel = hub?.net?.level;
    final loaded = loadWorkspace(data.sharedDir);
    workspace = loaded.workspace;
    if (loaded.problem != null) hint = loaded.problem!;
    this.profiles = profiles ?? AppProfileStore.load(data.sharedDir, null);
    final pp = this.profiles.problem;
    if (pp != null) hint = hint.isEmpty ? pp : '$hint；$pp';
    this.profiles.addListener(_onProfiles);
    positions.dropExcept({for (final p in workspace.projects) p.id});
    if (prefs.first == FirstLayer.project) grouping = Grouping.project;
    _entries = _mapEntries();
    _trackAttention();
    refreshDevices();
    _restorePins();
    unawaited(recorder.sweep());
    unawaited(history.refresh()); // never throws; the panel's ↑ has what is read by then
  }

  /// The input record: what the writing panel sends, and the drafts it leaves.
  late final InputRecorder recorder;

  /// The input record read back, every device's (R2, R4); what [recorder] writes comes in at once.
  late final InputHistory history;
  StreamSubscription<Map<String, Object?>>? _writtenSub;

  /// The record key (`host/app`) of [rs]'s session, null when no record claims it.
  String? historyKeyOf(RemoteSession rs) => (_recordOfSid(rs.sid) ?? _recordOfLastSid(rs.sid))?.key;

  /// What ↑ brings back in [rs]'s writing panel, newest first (R2); empty for a session no
  /// record claims. 常用语 sends are left out (phrases spec §4.8).
  List<InputEntry> recallOf(RemoteSession rs) {
    final r = _recordOfSid(rs.sid) ?? _recordOfLastSid(rs.sid);
    if (r == null) return const [];
    // A host's text terminals share one history (each keeps its own draft).
    final all = isTermApp(r.app)
        ? history.forSession('${r.key.substring(0, r.key.indexOf('/') + 1)}term:', prefix: true)
        : history.forSession(r.key);
    final out = <InputEntry>[];
    for (final e in all) {
      if (e.phrase || (out.isNotEmpty && out.last.text == e.text)) continue;
      out.add(e);
    }
    return out;
  }

  /// Switches to a moved data root: later reads and writes go there and `workspace.json` is reread.
  /// Pinned entries saved under the old root follow to the new one.
  void relocate(DataDir d) {
    _flushPositions();
    final oldRoot = data.root;
    data = d;
    llm = LlmEndpoint.load(d.localDir);
    _loadRules();
    _forgetHotwords();
    final loaded = loadWorkspace(d.sharedDir);
    workspace = loaded.workspace;
    if (loaded.problem != null) hint = loaded.problem!;
    _reloadProjectState();
    profiles.removeListener(_onProfiles);
    profiles = AppProfileStore.loadWith(d.sharedDir, profiles.builtin);
    final pp = profiles.problem;
    if (pp != null) hint = hint.isEmpty ? pp : '$hint；$pp';
    profiles.addListener(_onProfiles);
    for (final rs in remote.values) {
      rs.setProfile(profiles.resolve(rs.appId));
      _syncHidden(rs);
    }
    _applyFps();
    _entries = _mapEntries();
    unawaited(history.refresh());
    final old = oldRoot.endsWith('/') ? oldRoot : '$oldRoot/';
    for (final e in resources.clips) {
      final p = e.path;
      if (p != null && p.startsWith(old)) e.path = '${d.root}/${p.substring(old.length)}';
    }
    notifyListeners();
  }

  /// Loads the pins saved in the data dir back as ended, pinned entries (oldest last).
  Future<void> _restorePins() async {
    final p = port;
    if (p == null) return;
    final paths = pinnedPaths(data);
    for (final path in paths.reversed) {
      final r = await p.loadPin(path);
      if (_disposed) return;
      if (r == null) continue;
      DateTime at;
      try {
        at = pinTime(path) ?? File(path).statSync().modified;
      } catch (_) {
        at = DateTime.now();
      }
      resources.addRestored(path: path, copy: r.copy, kind: r.kind, title: pinTitle(path), at: at);
    }
  }

  final HubClient? hub;

  /// Hold-to-talk speech recognition (iOS); null where there is no voice button.
  final VoiceInput? voice;
  final String? hubError;
  /// The data root; mutable so a relocation can swap it.
  DataDir data;
  final UiPrefs prefs;
  final SessionPort? port;
  final UnlockStore unlockStore;
  final Set<Object> _unlockSeen = {};
  final Map<Object, int> _lockEpoch = {};
  /// Devices the user locked on purpose (seen going unlocked -> locked): no unlock on reconnect.
  final Set<String> _manualLock = {};

  /// Per device: the 5 s check after a password was sent. Present = an unlock is in flight.
  final Map<String, Timer> _unlockBusy = {};
  final Set<String> _unlockRejected = {};
  /// Devices whose saved password was typed by itself and no unlocked report has come since.
  /// Survives session end and reconnect; while set, the saved password is not typed again (§6.6).
  final Set<String> _autoUnconfirmed = {};
  final StreamController<String> _unlockAsks = StreamController<String>.broadcast();

  /// Device ids that want the password dialog (the current session is locked and nothing could unlock it).
  Stream<String> get unlockAsks => _unlockAsks.stream;

  /// A session went away: the device's unlock check dies with it unless another session still carries it.
  void _releaseUnlockBusy(SessionRecord r) {
    final others = _records.values.any((x) =>
        x != r && x.id == r.id && _countsForUnlock(x.app) && x.phase == Phase.live && !x.ending);
    if (!others) {
      _unlockBusy.remove(r.id)?.cancel();
      _unlockRejected.remove(r.id);
    }
  }

  /// Secondary screens share the main desktop's lock state; terminals never report it.
  bool _countsForUnlock(String app) => !isTermApp(app) && !isDesktopScreen(app);

  /// Terminal sessions' port; null where the GUI has no native port (no terminals there).
  final TermSessionPort? termPort;

  /// Where calls for session [sid] go: the terminal port for its own sessions, else the native one.
  SessionPort? portOf(Object sid) => termPort?.owns(sid) == true ? termPort : port;

  /// [rs]'s current pane, when it is a terminal session.
  TermPane? termPaneOf(RemoteSession rs) {
    final tp = termPort, w = rs.currentWindow;
    if (tp == null || w == null || !tp.owns(rs.sid)) return null;
    return tp.pane(rs.sid, w);
  }

  /// My app profiles (`apps.json` in `shared/`) and the built-in ones; swapped by [relocate].
  late AppProfileStore profiles;
  final void Function(String line) _log;
  final Map<Object, List<int>> _sentHidden = {};
  final Map<Object, int> _loggedHidden = {};

  /// Clipboard entries and transfers of every session.
  final ResourcesState resources;

  /// Favourites and projects, loaded from `workspace.json` in `shared/`.
  late Workspace workspace;

  /// The double-click interval the runner reported (`init`), for counting clicks (R14).
  final Duration doubleClick;
  StreamSubscription<SessionEvent>? _portSub, _termSub;

  /// Embedded sessions by hub sid.
  final Map<Object, RemoteSession> remote = {};

  // 长语音先让 AI 整理: one per session, keyed by sid like [remote]; a reconnect's swap moves it ([_dropOld]).
  final Map<Object, VoiceTidy> _tidies = {};

  late final _tidyHeld = TidyHeld(() => '${data.localDir}/tidy-held');

  /// [sid]'s tidy, made on first use. One asked for a session that is gone (a last build of its layer) is not
  /// kept: it could never begin, and nothing would end it.
  VoiceTidy tidyOf(Object sid) {
    final t = _tidies[sid];
    if (t != null) return t;
    final made = _makeTidy(sid);
    if (!_disposed && remote.containsKey(sid)) _tidies[sid] = made;
    return made;
  }

  String? _keyOfSid(Object sid) {
    for (final r in _records.values) {
      if (r.sid == sid || r.lastSid == sid) return r.key;
    }
    return null;
  }

  // A tidy of a session that is not on show tells the top bar (its card is not seen).
  void _tidyAside(Object sid, String what) {
    final rs = remote[sid];
    if (rs == null || identical(rs, currentRemote)) return;
    hint = '${rs.appName}：$what';
    notifyListeners();
  }

  /// How long a done tidy's send waits for a click on 编辑.
  @visibleForTesting
  Duration tidySettle = const Duration(milliseconds: 1500);

  /// How long a burst of the AI's words takes to come out; zero: at once.
  @visibleForTesting
  Duration tidyRevealMax = const Duration(milliseconds: 600);

  VoiceTidy _makeTidy(Object sid) => VoiceTidy(
        sid: sid,
        settle: tidySettle,
        revealMax: tidyRevealMax,
        endpoint: () => llm,
        api: llmApi,
        allowed: (s) => prefs.voiceAiTidy && llm.configured && !(remote[s]?.secureFocus ?? true),
        think: () => prefs.voiceAiThink,
        mode: (s) {
          for (final r in _records.values) {
            if (r.sid == s || r.lastSid == s) {
              return prefs.voiceTidyMode[tidyModeKey(r.app, r.id)] ?? defaultTidyMode(r.app, r.appName);
            }
          }
          return TidyMode.prompt;
        },
        setMode: (s, m) {
          for (final r in _records.values) {
            if (r.sid == s || r.lastSid == s) {
              prefs.voiceTidyMode[tidyModeKey(r.app, r.id)] = m;
              _save();
              notifyListeners();
              return;
            }
          }
        },
        learn: (s, items) {
          if (remote[s]?.secureFocus ?? true) return;
          unawaited(_learnItems(items));
        },
        // The rules as they are now, not as they were when the tidy was made (spec D9).
        fromVocabulary: (heard, observed) => voiceRules.fromVocabulary(heard, observed),
        send: (s, text, voice) {
          final rs = remote[s], p = portOf(s);
          if (rs == null || p == null) {
            if (rs != null) {
              unawaited(rs.composer.keep(text));
              if (voice.ai != null) {
                rs.composer.pendingAi = voice.ai;
              } else if (voice.heard != null) {
                // Sent from the panel later, it still learns (D8); not from a password field (D7).
                rs.composer.pendingHeard = rs.secureFocus ? null : voice.heard;
              }
            }
            return voiceBlocked;
          }
          final hint = sendVoice(state: this, session: rs, port: p, text: text, voice: voice);
          if (hint == null && voice.ai != null) _tidyAside(s, '已用 AI 整理并发出');
          return hint;
        },
        edit: (s, text, ai) {
          final c = remote[s]?.composer;
          if (c == null) return;
          // The AI's text over the original: one ⌘Z gives the original back (§8.2) — the fixed words, as 还原
          // does, not the heard ones [VoiceAi.original] keeps for learning (spec D6).
          unawaited(c.keep(text, undo: ai == null ? null : (tidyIfAny(s)?.original ?? ai.original)));
          if (ai != null) {
            c.pendingAi = ai;
          } else if (tidyIfAny(s) case final t?) {
            c.pendingHeard = VoiceHeard(heard: t.heard, fixed: text); // the fixed words, without the AI (D8)
          }
          c.open = true;
          if (ai != null) _tidyAside(s, 'AI 整理好了，放在写作面板里');
        },
        keep: (s, text) {
          final c = remote[s]?.composer;
          if (c != null) unawaited(c.keep(text));
        },
        log: (l) => _log('rapp: $l'),
        held: (s, original) {
          final k = _keyOfSid(s);
          if (k != null) _tidyHeld.set(k, original);
        },
      );

  /// [sid]'s tidy if one was made.
  VoiceTidy? tidyIfAny(Object sid) => _tidies[sid];

  // The session [sid] goes for good: its tidy stops and hands back the original it was waiting with,
  // for the caller to keep where the session's text goes (review 2026-11-20 #1, #2).
  String? _endTidy(Object sid) {
    final t = _tidies.remove(sid);
    if (t == null) return null;
    final original = t.end();
    t.dispose();
    return original;
  }

  // [text] (if any) into the draft of [sid], a session that stays.
  void _keepIn(Object? sid, String? text) {
    final c = sid == null ? null : remote[sid]?.composer;
    if (text != null && c != null) unawaited(c.keep(text));
  }

  /// Embedded sessions by `id/app`, in the order they were first opened. A record outlives its
  /// link: a disconnected one stays here, with its last frame, until the user ends it.
  final Map<String, SessionRecord> _records = {};
  final Map<String, List<RemoteDisplay>> _desktopDisplays = {};
  final Map<String, Set<String>> _hintedScreens = {};
  final Map<SessionRecord, Future<AppList>> _displayRequests = {};
  Timer? _desktopTimer;
  int _seq = 0;
  // Hub closed first: waiting up to 1 s for the runner's reason.
  final Map<Object, _Waiting> _waiting = {};
  // Sids closed on the hub without ever being shown; their hub `closed` is ignored.
  final Set<Object> _quiet = {};
  // Keys ended by 「全部结束」 whose end comes later: their 「已结束」 would hide the summary (K13).
  final Set<String> _batchEnded = {};
  // The current start of each hub sid. The hub counts sids from 1 again after a restart, so global
  // resources tell sessions apart by start, never by sid (S6-4b): port events are translated here
  // on the way in, and port calls get the hub sid back ([_hubSid]).
  final Map<Object, _Start> _starts = {};

  Object? _startOf(Object? sid) => sid == null ? null : _starts[sid];
  static Object _hubSid(Object start) => start is _Start ? start.sid : start;

  bool get embeds => port != null;

  SessionRecord? recordFor(String key) => _records[key];
  SessionRecord? get currentRecord => currentKey == null ? null : _records[currentKey];
  bool get currentDisconnected => currentRecord?.phase == Phase.disconnected;

  /// The current record is reconnecting: its stage still shows the old session's last frame.
  bool get currentReconnecting => currentRecord?.lastSid != null && !currentDisconnected;

  /// What the stage shows of [r]: the last picture while it reconnects, else its own session.
  RemoteSession? _stageRemote(SessionRecord r) {
    final sid = r.lastSid ?? r.sid;
    return sid == null ? null : remote[sid];
  }

  RemoteSession? get currentRemote {
    final r = currentRecord;
    return r == null ? null : _stageRemote(r);
  }

  SessionRecord? _recordOfSid(Object sid) {
    for (final r in _records.values) {
      if (r.sid == sid) return r;
    }
    return null;
  }

  SessionRecord? _recordOfLastSid(Object sid) {
    for (final r in _records.values) {
      if (r.lastSid == sid) return r;
    }
    return null;
  }

  /// Whether the runner or the hub may hear of [sid] (R12).
  /// Fails closed: a sid no record claims, or one it only keeps for its last frame, is not heard.
  /// The old session of a move is still live: it is the one on the stage until the swap.
  bool _liveSid(Object sid) {
    final r = _recordOfSid(sid);
    if (r != null) return r.phase == Phase.live;
    final m = _recordOfLastSid(sid);
    return m != null && m.phase == Phase.live && _reroutes.containsKey(m);
  }

  bool _hubHas(Object sid) => hub != null && hub!.sessions.any((s) => s.sid == sid);

  /// Whether [r] is live and the hub still has its session: the only case that talks to either.
  bool _reachable(SessionRecord r) => r.phase == Phase.live && r.sid != null && _hubHas(r.sid!);

  /// Bytes per second over all live embedded sessions (R24).
  int get totalBytesPerSecond {
    var n = 0;
    for (final r in _records.values) {
      if (r.phase == Phase.live && r.sid != null) n += remote[r.sid]?.bytesPerSecond ?? 0;
    }
    return n;
  }

  int get disconnectedCount => _records.values.where((r) => r.phase == Phase.disconnected).length;

  PanelTab? panel;
  Corner? corner;
  String? _lastKey;
  Grouping grouping = Grouping.device;
  String? currentKey;
  String _hint = '';

  /// The top bar's line about what just happened; '' when there is nothing to say.
  String get hint => _hint;

  /// Every line the hint showed this run, newest first, at most [hintHistoryMax]. Setting the
  /// line it already shows adds nothing; a line that only appends to the shown one (`a；b`)
  /// replaces its record; the same line after a clear is a new record.
  set hint(String v) {
    final was = _hint;
    _hint = v;
    if (v.isEmpty || v == was) return;
    if (was.isNotEmpty && v.startsWith('$was；') && hintHistory.firstOrNull?.text == was) {
      hintHistory[0] = HintRecord(v, hintHistory[0].at);
      return;
    }
    _queue(HintRecord(v, _now()));
  }

  void _queue(HintRecord r) {
    hintHistory.insert(0, r);
    if (hintHistory.length > hintHistoryMax) hintHistory.removeLast();
  }

  static const hintHistoryMax = 50;

  /// The status queue: every line the hint showed this run and every program status change, newest first,
  /// at most [hintHistoryMax].
  final List<HintRecord> hintHistory = [];

  /// The last program status seen per text terminal (`device\nterm`): its state, and the ask's seq while blocked.
  final Map<String, (String, int)> _psSeen = {};

  /// Devices whose terminal list was read once: what that first list says is the starting point, not news.
  final Set<String> _psDevices = {};

  /// Queues each change of a text terminal's program status: a new state, or a new ask. A progress number alone
  /// is not a change. A dropped device's list is stale and is skipped.
  void _trackPrograms() {
    final lists = hub?.termLists;
    if (lists == null) return;
    for (final e in lists.entries) {
      final device = e.key;
      if (_offlineSince.containsKey(device)) continue;
      final first = _psDevices.add(device);
      final live = <String>{};
      for (final r in e.value.terms) {
        final ps = r.ps;
        final k = '$device\n${r.id}';
        if (r.dead || ps == null) continue;
        live.add(k);
        final now = (ps.state, ps.state == 'blocked' ? ps.seq : 0);
        final was = _psSeen[k];
        _psSeen[k] = now;
        if (first || was == now) continue;
        final title = termDisplayName(r.shown, r.host);
        _queue(HintRecord('$title @ ${deviceName(device)}：${programWord(ps)}', _now(),
            device: device, app: r.id, title: title, lamp: programLamp(ps)));
      }
      _psSeen.removeWhere((k, _) => k.startsWith('$device\n') && !live.contains(k));
    }
  }

  /// A tap on a queued line about a session: that session, opened if it is not, and the list closes.
  void goToQueued(HintRecord r) {
    if (!r.goes) return;
    corner = null;
    openOrSwitch(r.device!, r.app!, r.title ?? r.app!);
    notifyListeners();
  }

  /// A tap on a 需要你 row: a blocked terminal opens (or comes up), a dropped session comes on stage
  /// (its reconnect is there), a dropped device shows its panel.
  void goToNeed(NeedItem n) {
    switch (n.kind) {
      case NeedKind.terminal:
        if (!hubUsable) return;
        corner = null;
        openOrSwitch(n.device!, n.target, n.title!);
        notifyListeners();
      case NeedKind.session:
        corner = null;
        select(n.target);
      case NeedKind.device:
        showDevice(n.target);
    }
  }
  final Map<String, DeviceProbe> probes = {};
  String? deviceTab;

  final Map<String, SessionEntry> _pending = {};
  late List<SessionEntry> _entries;
  String? _lastError;
  final Map<String, String> _appNames = {};
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    // The session's menus belong to the session they were opened on; so does a marking.
    if (currentKey != _lastKey) {
      _lastKey = currentKey;
      if (corner != null && corner != Corner.needs && corner != Corner.hints) corner = null;
      markingInput = null;
      _followCurrentKey();
    }
    if (embeds) _entries = _mapEntries();
    // The session list has nothing to show once the last session is gone.
    if (corner == Corner.sessions && _entries.isEmpty) corner = null;
    _trackAttention();
    // Focus never stays on a session that is no longer current (mid-move, the old one is on the stage).
    if (pictureFocused != null && (currentRemote?.sid ?? current?.sid) != pictureFocused) {
      appLatch.releaseAll(); // the old session's modifiers go up while its row still has its sid
      _blur();
    }
    _focusNewTerm();
    _raiseStagedSession();
    _syncPolicy();
    _syncDesktopTimer();
    // Every change of the current session or of detach state ends in a notify.
    _applyFps();
    super.notifyListeners();
  }

  // ---- overview ----
  /// The stage shows the overview wall instead of the current session's picture.
  bool overview = false;

  /// The 日志 screen fills the stage (reached from 访问记录's 更多); no session is on stage meanwhile.
  bool logs = false;

  void openLogs() {
    logs = true;
    panel = null;
    _blur();
    notifyListeners();
  }

  void closeLogs() {
    if (!logs) return;
    logs = false;
    notifyListeners();
  }

  /// 全景 (⌃⌘O). With 日志 open it closes them and ends on 全景, whichever screen they were opened from.
  void toggleOverview() {
    overview = logs || !overview;
    logs = false;
    if (overview) _blur();
    notifyListeners();
  }

  /// How many windows (tabs) [key]'s session has; 0 for an unknown or unstarted one.
  int windowsOf(String key) {
    final r = _records[key];
    final rs = r == null ? null : _stageRemote(r);
    return rs?.tabs.tabs.length ?? 0;
  }

  /// Ctrl+Enter: the panel opens with the caret; from the picture the caret comes back to the
  /// editor; from the editor the keys go to the picture (the panel stays). A frozen picture takes
  /// no keys: the caret stays in the editor (offline-freeze spec).
  void composerKey() {
    final rs = currentRemote;
    if (overview || logs || rs == null || !rs.composerAllowed) return; // no panel in the overview to take the caret
    final c = rs.composer;
    if (!c.open) {
      c.open = true;
      c.wantFocus();
    } else if (!c.editorFocused) {
      c.wantFocus();
    } else if (!sendBlocked(rs.sid)) {
      c.releaseFocus();
      if (!rs.detached) focusPicture(rs.sid);
    }
  }

  // ---- picture focus (R15, R24) ----
  /// Native blur arrives after the frame that requested it. Let Picture retry its focus guard.
  void composerFocusChanged(RemoteSession session, bool focused) {
    session.composer.editorFocused = focused;
    if (focused) {
      blurPicture();
    } else if (pictureFocused == session.sid) {
      notifyListeners();
    }
  }

  /// Bumped when the terminal stage of [termFocusSid] should take the keyboard; the stage follows it.
  int termFocusTick = 0;
  Object? termFocusSid;

  // The live terminal last put on the stage: a different one (opened, switched to, reconnected) takes the keys.
  Object? _stagedTerm;

  void _wantTermFocus(Object sid) {
    termFocusSid = sid;
    termFocusTick++;
  }

  void _focusNewTerm() {
    final r = currentRecord, rs = currentRemote;
    final live = r != null && r.phase == Phase.live && r.lastSid == null;
    final sid = live && rs != null && termPort?.owns(rs.sid) == true ? rs.sid : null;
    if (sid == _stagedTerm) return;
    _stagedTerm = sid;
    if (sid != null) _wantTermFocus(sid);
  }

  /// The session whose picture has keyboard focus: its keys go to A (the runner routes them).
  Object? pictureFocused;

  /// The app key row's sticky modifiers (iPad spec §8.3): one for the stage, released whenever the keys move to
  /// another session. [ModifierLatch.releaseAll] is also what going to the background calls.
  final appLatch = ModifierLatch();

  /// A press on [sid]'s picture: keys go to A from now on.
  void focusPicture(Object sid) {
    if (overview || logs || !_liveSid(sid)) return;
    if (termPort?.owns(sid) == true) {
      // A terminal's keys are the stage's own (its Focus), not the runner's.
      _wantTermFocus(sid);
      notifyListeners();
      return;
    }
    panelHolds = null;
    if (pictureFocused == sid) return;
    if (pictureFocused != null) appLatch.releaseAll(); // the keys move to another session
    pictureFocused = sid;
    _sendFocus(sid);
    notifyListeners();
  }

  /// The session whose writing panel took the keys from its picture by a press on it (or by taking
  /// the caret): while that panel is open the picture does not take them back by itself.
  Object? panelHolds;

  /// A press on [rs]'s writing panel, or its editor taking the caret: keys stay with the panel.
  void holdForPanel(RemoteSession rs) {
    panelHolds = rs.sid;
    blurPicture();
  }

  /// The 语音快捷键 row is recording a key: the picture must not take the keys back meanwhile.
  bool voiceHotkeyRecording = false;

  /// What the runner was last told about [pictureFocused]'s compose (type-to-compose).
  bool _composeSent = false;

  /// A letter on [sid]'s picture opens the writing panel: an app window on the stage whose panel is
  /// allowed (no `noComposer` rule) and whose app has `typeToCompose` on, until a letter-opened panel is closed unused
  /// ([RemoteSession.composeArmed]). Never rApp's own terminal.
  bool _composeFor(Object sid) {
    final rs = remote[sid];
    if (rs == null || rs.detached || termPort?.owns(sid) == true) return false;
    return rs.composerAllowed && rs.profile.typeToCompose && rs.composeArmed;
  }

  /// What the runner was last told about [pictureFocused]'s voice.
  bool _voiceSent = false;

  /// Hold-to-talk on [sid]'s picture (macOS, Linux): an app window on the stage. The text area open or not, as a
  /// mouse hold on 语音 (and iOS): its editor taking the keys blurs the picture, which keeps the gate off them.
  bool _voiceFor(Object sid) {
    if ((defaultTargetPlatform != TargetPlatform.macOS && defaultTargetPlatform != TargetPlatform.linux) || voice == null) return false;
    final rs = remote[sid];
    if (rs == null || rs.detached || termPort?.owns(sid) == true) return false;
    return rs.composerAllowed;
  }

  void _sendFocus(Object sid) {
    _composeSent = _composeFor(sid);
    _voiceSent = _voiceFor(sid);
    portOf(sid)?.pictureFocus(sid, compose: _composeSent, voice: _voiceSent);
  }

  /// A session changed (profile, current tab): the focused picture's compose is sent again if it moved.
  void _syncCompose() {
    final sid = pictureFocused;
    if (sid == null || (_composeFor(sid) == _composeSent && _voiceFor(sid) == _voiceSent)) return;
    _sendFocus(sid);
  }

  /// ⌘V / Ctrl+Shift+V on [rs]'s terminal stage (K4): one line of clipboard text goes in as a paste (no Return);
  /// text with line breaks opens the writing panel, which pastes it by its own rules and takes the caret. With the
  /// writing panel off for this session ([RemoteSession.composerAllowed]) there is no panel to open, so text with
  /// line breaks goes in as one paste too.
  /// [TermPasted.sent] when the text went to the terminal itself (input, as a key is: H3, K6);
  /// [TermPasted.note] says why a paste did not go in.
  Future<TermPasted> termPaste(RemoteSession rs) async {
    final tp = termPort;
    if (tp == null || !tp.owns(rs.sid)) return const TermPasted();
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      return const TermPasted(); // no clipboard to read: nothing to paste
    }
    if (text == null || text.isEmpty) return const TermPasted();
    // A drop during the clipboard read: nothing goes out after it.
    if (sendBlocked(rs.sid)) return const TermPasted();
    if (!rs.composerAllowed || (!text.contains('\n') && !text.contains('\r'))) {
      final why = await tp.paste(rs.sid, text);
      return why == null ? const TermPasted(sent: true) : TermPasted(note: why);
    }
    final c = rs.composer;
    c.open = true;
    c.requestPaste();
    c.wantFocus();
    return const TermPasted();
  }

  /// A press outside the picture (top bar, overlays): keys leave A for now. The picture takes them
  /// back once nothing else wants them (no text field, dialog or open menu): see `Picture`.
  void blurPicture() {
    if (_blur()) notifyListeners();
  }

  bool _blur() {
    if (pictureFocused == null) return false;
    pictureFocused = null;
    port?.pictureFocus(null);
    return true;
  }

  // ---- stage size (Ruling P2) ----
  Size? _lastStage;
  RemoteSession? _syncedRs;

  /// The stage is [s] big now. Remembered, and given to the current session's resize policy.
  void stageSize(Size s) {
    _lastStage = s;
    // Frozen (offline): A never hears of it; the next session gets the latest size.
    if (currentRecord?.frozen != true) currentRemote?.policy.stage(s);
  }

  /// A tab was picked on the current session.
  void selectWindow(int id) {
    currentRemote?.selectWindow(id);
    notifyListeners();
  }

  RemoteWindow? _windowOf(RemoteSession rs) {
    for (final w in rs.windows) {
      if (w.id == rs.currentWindow) return w;
    }
    return null;
  }

  Object? _raisedStageSid;

  /// Switching the local stage must also activate A's app. picture_focus only
  /// routes B's keyboard; waiting for a click leaves wheel/trackpad input over
  /// whichever app was previously on top. Do this as soon as its table arrives,
  /// once per stage entry, not on every frame or focus-region update.
  void _raiseStagedSession() {
    final rs = currentRemote;
    final w = rs == null ? null : _windowOf(rs);
    if (overview || rs == null || rs.detached || !_liveSid(rs.sid) ||
        isTermApp(rs.appId) || termPort?.owns(rs.sid) == true || w == null) {
      _raisedStageSid = null;
      return;
    }
    if (_raisedStageSid == rs.sid) return;
    _raisedStageSid = rs.sid;
    portOf(rs.sid)?.selectWindow(rs.sid, w.id);
  }

  /// A session that became current gets the stage size; its policy always knows the current window.
  void _syncPolicy() {
    final rs = currentRemote;
    if (rs == null) {
      _syncedRs = null;
      return;
    }
    if (!identical(rs, _syncedRs)) {
      _syncedRs = rs;
      final s = _lastStage;
      if (s != null) rs.policy.stage(s);
    }
    // Detached, the stage is not A's window: nothing is judged until it is back (then at once).
    rs.policy.current(rs.detached ? null : _windowOf(rs));
  }

  // ---- off-stage frame rate (R6) ----
  /// `set_stream`'s `pinned`: A keeps to the choice even on a poor network (automatic saving off,
  /// spec 2026-11-14-rapp-network-status §6.1). A manual pick is the ceiling either way.
  bool get _pinned => !prefs.autoSaveTraffic;

  /// The (mode, fps, density, pinned, focus) last sent per started session, so nothing is sent twice.
  final Map<Object, (String, int, String, bool, bool)> _sentFps = {};

  /// Under 「智能」 A is asked for the focus region: not for a desktop session, and not for an app
  /// whose profile turned the focus pane off.
  bool _wantsFocus(RemoteSession rs, SessionRecord r) => rs.choice.smart && !isDesktopApp(r.app) && rs.profile.focusPane;

  /// Whether the main window can be seen: false when it is minimized, hidden, fully covered or on
  /// another Space (macOS), or minimized (Linux). Its stage session then pauses too.
  bool get mainVisible => _mainVisible;
  bool _mainVisible = true;
  set mainVisible(bool v) {
    if (v == _mainVisible) return;
    _mainVisible = v;
    _applyFps();
  }

  /// Sends each started session's effective rate when it differs from the last one sent: the
  /// chosen rate when it can be seen, 0 (paused) otherwise. `session.choice` is never changed.
  void _applyFps() {
    final p = port;
    if (p == null) return;
    _sentFps.removeWhere((sid, _) => !remote.containsKey(sid));
    // In overview no picture is on stage: every session runs at its off-stage rate (C4).
    final onStage = overview || logs || !_mainVisible ? null : currentRecord;
    for (final rs in remote.values) {
      final last = _sentFps[rs.sid];
      if (last == null) continue; // not started yet: its start carries the rate
      final r = _recordOfSid(rs.sid);
      if (r == null || !_reachable(r)) continue; // a dead sid never reaches the runner (R12)
      final c = rs.choice;
      final shown = rs.detached ? rs.windowVisible : onStage != null && identical(r, onStage);
      final fps = effectiveFps(c, shown: shown, sawFrame: rs.sawFrame);
      // Pinned when the global traffic preference pins it. For a non-desktop session a
      // manual pick is only a ceiling (not a pin); desktop screens, however, share a
      // manual choice across siblings, so there a manual pin does pin the stream.
      // 「智能」 always saves traffic itself: never pinned, a desktop's manual pick included.
      final pin = !c.smart && (_pinned || (isDesktopApp(r.app) && rs.streamPinned));
      final focus = _wantsFocus(rs, r);
      rs.focusWanted = focus;
      final now = (c.mode, fps, c.density, pin, focus);
      if (now == last) continue;
      _sentFps[rs.sid] = now;
      portOf(rs.sid)!.setStream(rs.sid, c.mode, fps, c.density, pinned: pin, focus: focus);
    }
  }

  // ---- detach (R20, R21) ----
  /// Moves the current session from the stage into native windows; the runner answers with a
  /// `DetachedEvent`. The same sid and hub session throughout: nothing is reopened.
  final Set<Object> _detaching = {};
  bool isDetaching(Object sid) => _detaching.contains(sid);

  Future<void> detach() async {
    final rs = currentRemote;
    if (rs == null || rs.detached || rs.tabs.tabs.isEmpty || !_liveSid(rs.sid)) return;
    await _detachSession(rs);
  }

  Future<void> _detachSession(RemoteSession rs) async {
    if (!_detaching.add(rs.sid)) return;
    rs.composer.handoff(true);
    try {
      final inline = portOf(rs.sid)?.supportsInlineNativeComposer == true;
      final text = await rs.composer.readDraft(inline: inline);
      if (identical(remote[rs.sid], rs) && _liveSid(rs.sid) && !rs.detached) {
        await portOf(rs.sid)?.detach(rs.sid, text: text, blocks: inline ? rs.composer.nativeBlocks : List.of(rs.composer.blocks));
      } else {
        rs.composer.handoff(false);
      }
    } catch (e) {
      rs.composer.handoff(false);
      hint = '分离没成功：$e';
      notifyListeners();
    } finally {
      _detaching.remove(rs.sid);
    }
  }

  /// Puts the current session back on the stage.
  void attach() {
    final rs = currentRemote;
    if (rs == null || !_liveSid(rs.sid)) return;
    portOf(rs.sid)?.attach(rs.sid);
  }

  /// ⌃⌘D and the stream menu's 「分离成独立窗口」/「放回主窗口」.
  void toggleDetach() {
    final rs = currentRemote;
    if (rs == null) return;
    rs.detached ? attach() : detach();
  }

  /// Whether [toggleDetach] does anything now (the menu greys its item otherwise).
  bool get canToggleDetach {
    final rs = currentRemote;
    return rs != null && portOf(rs.sid)?.supportsDetach == true && _liveSid(rs.sid) && (rs.detached || rs.tabs.tabs.isNotEmpty);
  }

  // ---- hub state ----
  bool get hubUsable => hub != null && hub!.alive;

  String? get hubProblem {
    if (hub == null) return hubError ?? 'rapp-hub 不可用';
    if (!hub!.alive) return 'rapp-hub 已退出 — 重启 rApp 以恢复';
    return null;
  }

  // ---- panel ----
  void togglePanel([PanelTab tab = PanelTab.sessions]) {
    panel = panel == tab ? null : tab;
    notifyListeners();
  }

  /// Opens the panel on [tab]; already on it, it stays.
  void showPanel(PanelTab tab) {
    if (panel == tab) return;
    panel = tab;
    notifyListeners();
  }

  /// The project the projects tab should scroll to; the tab clears it once it has.
  String? focusProject;

  /// Opens the projects tab on [id] (from the overview).
  void showProject(String id) {
    panel = PanelTab.projects;
    focusProject = id;
    notifyListeners();
  }

  void closePanel() {
    if (panel == null) return;
    panel = null;
    notifyListeners();
  }

  // ---- corners and needs ----
  void showCorner(Corner c) {
    if (corner == c) return;
    corner = c;
    notifyListeners();
  }

  void toggleCorner(Corner c) {
    corner = corner == c ? null : c;
    notifyListeners();
  }

  void closeCorner() {
    if (corner == null) return;
    corner = null;
    notifyListeners();
  }

  /// Devices that were seen online; only these count as dropped when they go offline.
  final Set<String> _seenOnline = {};

  /// Dropped devices and when (`_seq`) they dropped. A manual probe never touches it (R16).
  final Map<String, int> _offlineSince = {};

  /// When (`_seq`) each blocked-terminal ask (device, session, ps.seq) was first seen; only orders [needs].
  final Map<String, int> _termNeedSeq = {};

  /// Everything waiting for the person, newest first. Handled things leave on their own.
  List<NeedItem> get needs {
    final seen = <String>{};
    final out = <NeedItem>[
      for (final r in _records.values)
        if (r.phase == Phase.disconnected)
          NeedItem(NeedKind.session, r.key, '${r.appName} @ ${deviceName(r.id)} 已断开：${disconnectWord(r.reason)}', r.seq,
              reconnectWord: reconnectLabel(r.reason)),
      for (final h in hub?.hosts ?? const <HubHost>[])
        if (_seenOnline.contains(h.id) && _offlineSince.containsKey(h.id))
          NeedItem(NeedKind.device, h.id, '${deviceName(h.id)} 离线', _offlineSince[h.id]!),
      // A device that dropped keeps its last list; its terminals cannot be opened, so they are not asks.
      for (final e in hub?.termLists.entries ?? const <MapEntry<String, TermList>>[])
        if (!_offlineSince.containsKey(e.key))
         for (final r in e.value.terms)
          if (!r.dead && r.ps?.state == 'blocked')
            () {
              final key = '${e.key}\n${r.id}\n${r.ps!.seq}';
              seen.add(key);
              final title = termDisplayName(r.shown, r.host);
              return NeedItem(NeedKind.terminal, r.id, '$title @ ${deviceName(e.key)}：${termAskWord(r.ps!)}',
                  _termNeedSeq.putIfAbsent(key, () => ++_seq),
                  device: e.key, title: title);
            }(),
    ];
    _termNeedSeq.removeWhere((k, _) => !seen.contains(k));
    out.sort((a, b) => b.seq.compareTo(a.seq));
    return out;
  }

  int get needCount => needs.length;

  /// The result of a probe or a presence event, for the lamp and the needs.
  void _setOnline(String id, bool online, {AppList? apps, String? error}) {
    final old = probes[id];
    if (online) {
      _seenOnline.add(id);
      _offlineSince.remove(id);
      probes[id] = DeviceProbe(Lamp.active, '在线', apps: apps ?? old?.apps);
    } else {
      _offlineSince.putIfAbsent(id, () => ++_seq);
      probes[id] = DeviceProbe(Lamp.offline, '离线', apps: apps ?? old?.apps, error: error ?? old?.error);
    }
  }

  /// 「查看」 on a dropped device: the device panel on it, with a fresh probe.
  void showDevice(String id) {
    panel = PanelTab.devices;
    deviceTab = id;
    corner = null;
    notifyListeners();
    probe(id);
  }

  // ---- sessions ----
  List<SessionGroup> get groups => groupSessions(_entries, grouping, projects: projects, first: currentProject);

  int get sessionCount => _entries.length;

  /// The session rows in order (what the panel and the overview show).
  List<SessionEntry> get entries => List.unmodifiable(_entries);

  SessionEntry? get current {
    final r = currentRecord;
    if (r != null) return _entryOf(r);
    for (final e in _entries) {
      if (e.key == currentKey) return e;
    }
    return null;
  }

  void setGrouping(Grouping g) {
    grouping = g;
    notifyListeners();
  }

  void select(String key) {
    currentKey = key;
    panel = null;
    overview = false;
    logs = false;
    notifyListeners();
  }

  /// The keys [step] may stop on: the current project's members, the open sessions in no project
  /// ([freeZone]), or null (any session).
  List<String>? get _stepWithin {
    if (freeZone) return freeZoneKeys;
    final p = currentProject == null ? null : _project(currentProject!);
    return p == null ? null : projectKeys(p);
  }

  /// The open sessions that belong to no project, in list order.
  List<String> get freeZoneKeys {
    final inProject = {for (final p in projects) ...projectKeys(p)};
    return [for (final e in _entries) if (!inProject.contains(e.key)) e.key];
  }

  /// How many open sessions [step] walks through.
  int get steppableCount {
    final within = _stepWithin;
    return within == null ? sessionCount : _entries.where((e) => within.contains(e.key)).length;
  }

  void step(int delta) {
    final k = stepKey(groups, currentKey, delta, within: _stepWithin);
    if (k == null) return;
    currentKey = k;
    notifyListeners();
  }

  String deviceName(String id) {
    for (final h in hub?.hosts ?? const <HubHost>[]) {
      if (h.id == id) return h.name.isEmpty ? h.id : h.name;
    }
    return id;
  }

  String appName(String id, String app) {
    final name = _appNames['$id/$app'] ?? app;
    if (!isTermApp(app)) return name;
    return termName(id, app) ?? name;
  }

  /// A text terminal's current name on [device], from the device's terms list; null when it is not listed (the
  /// session ended, or the list has not come yet).
  String? termName(String device, String term) =>
      hub?.termLists[device]?.terms.where((r) => r.id == term).firstOrNull?.shown;

  /// What a favourite or project member is called: `CLI · <name>` for a text terminal, whose name is the list's
  /// current one, else the one stored with it.
  String labelOf(AppRef a) => isTermApp(a.bundle) ? termTitle(termName(a.device, a.bundle) ?? a.name) : a.name;

  /// A text terminal's program status from its live row on [device]; null when the app is no terminal, the row is
  /// gone or dead, or the device dropped (its last list is stale).
  TermPs? _termPs(String device, String app) {
    if (!isTermApp(app) || _offlineSince.containsKey(device)) return null;
    final r = hub?.termLists[device]?.terms.where((r) => r.id == app).firstOrNull;
    return r == null || r.dead ? null : r.ps;
  }

  /// A text terminal on [device] whose live row says its program waits for the person.
  bool _termBlocked(String device, String app) => _termPs(device, app)?.state == 'blocked';

  SessionEntry _entryOf(SessionRecord r) {
    final sid = r.sid;
    final rs = sid == null ? null : remote[sid];
    // A terminal's name is the device's current one; the last one seen stays when the row is gone.
    final tn = isTermApp(r.app) ? termName(r.id, r.app) : null;
    if (tn != null) r.appName = tn;
    return SessionEntry(
      sid: sid,
      id: r.id,
      app: r.app,
      appName: r.app == 'desktop:' ? _desktopName(r.id) : r.appName,
      device: deviceName(r.id),
      path: r.path,
      lamp: r.phase != Phase.disconnected && _termBlocked(r.id, r.app) ? Lamp.waiting : recordLamp(r, rs),
      bytesPerSecond: r.phase == Phase.live ? rs?.bytesPerSecond : null,
      reason: r.phase == Phase.disconnected ? disconnectWord(r.reason) : null,
      takenOver: r.phase == Phase.disconnected && takenOver(r.reason),
      ps: r.phase == Phase.disconnected ? null : _termPs(r.id, r.app),
    );
  }

  List<SessionEntry> _mapEntries() {
    if (embeds) return [for (final r in _records.values) if (!isDesktopScreen(r.app)) _entryOf(r)];
    final h = hub;
    final out = <SessionEntry>[];
    final seen = <String>{};
    if (h != null) {
      for (final s in h.sessions) {
        if (remote[s.sid]?.endReason != null || _quiet.contains(s.sid)) continue;
        final e = SessionEntry(
          sid: s.sid,
          id: s.id,
          app: s.app,
          appName: appName(s.id, s.app),
          device: deviceName(s.id),
          path: s.path,
          lamp: _termBlocked(s.id, s.app) ? Lamp.waiting : Lamp.active,
          ps: _termPs(s.id, s.app),
        );
        if (seen.add(e.key)) out.add(e);
      }
    }
    for (final e in _pending.values) {
      if (seen.add(e.key)) out.add(e);
    }
    return out;
  }

  void _onHub() {
    final back = <String>{};
    for (final p in hub!.takePresence()) {
      if (p.online) back.add(p.id);
      if (probes[p.id]?.lamp == Lamp.connecting) continue;
      _setOnline(p.id, p.online, error: p.error);
    }
    _trackPrograms();
    if (!hub!.alive) _watching.clear();
    final level = hub!.net?.level;
    final netBack = _netLevel == NetLevel.down && level != NetLevel.down;
    _netLevel = level;
    if (embeds) {
      for (final id in back) {
        _peerBack(id);
      }
      if (netBack) _netBack();
    }
    // The labels read `hub.hostPaths`; this notify redraws them.
    final paths = hub!.takePaths();
    if (embeds) {
      for (final p in paths) {
        _pathChanged(p.id, p.path);
      }
      _onHubEmbedded();
      return;
    }
    // Sessions run by rapp-client (no port) are not moved: their next reconnect takes the new link.
    final old = _entries;
    final oldGroups = groups;
    _entries = _mapEntries();
    final newKeys = {for (final e in _entries) e.key};

    final h = hub!;
    if (h.alive) {
      for (final e in old) {
        if (e.sid == null || newKeys.contains(e.key)) continue;
        if (e.key == currentKey) {
          currentKey = _nextAfterEnd(oldGroups, e.key, newKeys.contains);
        }
        final hubReason = h.closeReasons.remove(e.sid);
        if (_quiet.remove(e.sid)) continue;
        if (_batchEnded.remove(e.key)) continue; // 全部结束 already said so (K13)
        hint = endedHint(e.appName, hubReason);
      }
    } else if (currentKey != null && !newKeys.contains(currentKey)) {
      currentKey = null;
    }

    if (h.lastError != _lastError) {
      _lastError = h.lastError;
      if (_lastError != null) hint = disconnectWord(_lastError!);
    }
    notifyListeners();
  }

  /// The hub's session list changed: a live record whose sid is gone waits up to 1 s for the
  /// runner's `DisconnectedEvent` (its reason is better), then disconnects with the hub's own.
  void _onHubEmbedded() {
    final h = hub!;
    if (!h.alive) {
      for (final r in _records.values) {
        _stopRetry(r);
      }
    }
    for (final r in _records.values.toList()) {
      final sid = r.sid;
      if (r.phase != Phase.live || sid == null || _hubHas(sid) || _waiting.containsKey(sid)) continue;
      final hubReason = h.closeReasons.remove(sid);
      _waiting[sid] = _Waiting(r.appName, Timer(const Duration(seconds: 1), () {
        _waiting.remove(sid);
        if (r.sid != sid || r.phase != Phase.live) return;
        r.ending ? _finishEnding(r) : _disconnect(r, hubReason ?? 'rapp-hub exited');
        notifyListeners();
      }));
    }
    // A sid nobody shows any more (ended, or closed quietly): its `closed` is not news. The old sid
    // of a move keeps its reason: a failed move goes back to it (`_rerouteFailed`).
    for (final sid in h.closeReasons.keys.toList()) {
      if (_recordOfSid(sid) == null && !_reroutes.keys.any((r) => r.lastSid == sid)) h.closeReasons.remove(sid);
    }
    _quiet.removeWhere((sid) => !_hubHas(sid));
    if (h.lastError != _lastError) {
      _lastError = h.lastError;
      if (_lastError != null) hint = disconnectWord(_lastError!);
    }
    notifyListeners();
  }

  void _nativeAction(RemoteSession rs, String action) {
    if (action == 'zoom+' || action == 'zoom-' || action == 'zoom0') {
      zoomKey(action == 'zoom+' ? ZoomKey.bigger : action == 'zoom-' ? ZoomKey.smaller : ZoomKey.reset);
    } else if (action == 'compose') {
      rs.composer.openByLetter();
      rs.prepareInput();
    } else if (action == 'open') {
      rs.composer.open = true;
      rs.prepareInput();
    } else if (action == 'close') {
      rs.composer.collapse();
    } else if (action == 'up' || action == 'down') {
      // The event's text is in the draft already; the native window gets what the step puts in.
      rs.composer.arrow(action == 'up', show: (t) => portOf(rs.sid)?.nativeComposerDraft(rs.sid, t));
    }
  }

  Future<void> _submitNative(RemoteSession rs, ComposerDraftEvent event) async {
    final port = portOf(rs.sid);
    if (sendBlocked(rs.sid) || !_liveSid(rs.sid)) {
      port?.nativeComposerSubmitted(rs.sid, taken: false);
      return;
    }
    if (port == null) return;
    if (event.retry) {
      if (rs.composer.failed.isEmpty) {
        port.nativeComposerSubmitted(rs.sid, taken: false);
        return;
      }
      final pieces = rs.composer.retry(rs.composer.failed.first);
      if (pieces != null) {
        port.nativeComposerSubmitted(rs.sid, retry: true);
        rs.prepareInput();
        port.composerSend(rs.sid, pieces);
      }
      return;
    }
    switch (await rs.composer.submit()) {
      case SubmitPieces(:final pieces):
        if (!identical(remote[rs.sid], rs)) return;
        port.nativeComposerSubmitted(rs.sid);
        // Sent from a record ↑ brought back: the text being written comes back into the window.
        if (rs.composer.draft.isNotEmpty) port.nativeComposerDraft(rs.sid, rs.composer.draft);
        if (!_liveSid(rs.sid) || sendBlocked(rs.sid)) {
          rs.composer.done(0, '连接已断开，内容尚未发送');
          return;
        }
        rs.prepareInput();
        port.composerSend(rs.sid, pieces);
      case SubmitReturn():
        port.nativeComposerSubmitted(rs.sid, taken: false);
        if (_liveSid(rs.sid) && !sendBlocked(rs.sid)) rs.pressReturn();
      case SubmitNothing():
        port.nativeComposerSubmitted(rs.sid, taken: false);
        break;
    }
  }

  void _applyPortEvent(RemoteSession rs, SessionEvent e) {
    // Allocate marks in the shared model before handing an insertion to the native editor.
    final text = e is ComposerInsertEvent ? rs.composer.plainText(e.insert.text ?? '') : null;
    rs.apply(e); // a first frame or a visibility change re-applies the rates in notifyListeners
    if (e is ComposerInsertEvent && portOf(rs.sid)?.supportsInlineNativeComposer == true) {
      final ids = e.insert.blocks.map((b) => b.n).toSet();
      portOf(rs.sid)?.nativeComposerInsert(rs.sid, text,
          rs.composer.nativeBlocks.where((b) => ids.contains(b.n)).toList());
    }
  }

  void _onPortEvent(SessionEvent e) {
    if (e is LatchUsedEvent || e is KeyTypedEvent) return; // the key bar's (it listens for its own session)
    if (e is VoiceKeyEvent) {
      voiceKey(e.sid, e.phase);
      return;
    }
    final rs = remote[e.sid];
    if (rs == null) return;
    final r = _recordOfSid(e.sid);
    if (r == null) {
      final moving = _recordOfLastSid(e.sid);
      // A reconnect keeps the old native editor visible until the first new frame.
      // Local edits still belong to that draft; they must never be sent to a dead link.
      if (moving?.frozen == true && (e is ComposerDraftEvent || e is ComposerInsertEvent || e is ComposerStateEvent)) {
        _applyPortEvent(rs, e);
        if (e is ComposerDraftEvent && e.action != null) _nativeAction(rs, e.action!);
        notifyListeners();
        return;
      }
      if (moving != null && _reroutes.containsKey(moving) && e is! ClosedEvent && e is! DisconnectedEvent) {
        // The old session of a move is still on the stage: its windows keep up until the swap.
        if (e is InputBlockedEvent) {
          _inputFeedback(moving, e.by);
          return;
        }
        _applyPortEvent(rs, e);
        if (e is WindowsEvent) _syncHidden(rs);
        final start = _starts[e.sid];
        if (start != null && e is ClipsEvent) {
          resources.addClips(moving.key, start, _sourceOf(moving), e.clips);
        } else if (start != null && e is TransferProgressEvent) {
          resources.transfer(moving.key, start, _sourceOf(moving), e);
        } else if (e is DetachedEvent) {
          // Still the hub's session until the swap, which carries the state over to the new one.
          if (_hubHas(e.sid)) hub!.note(e.sid, e.detached ? 'detach' : 'attach', rs.tabs.tabs.length);
          if (e.detached && pictureFocused == e.sid) _blur();
        }
        notifyListeners();
        return;
      }
      // The old sid of a reconnect: only its end matters, and only to forget it.
      final holder = e is ClosedEvent ? _recordOfLastSid(e.sid) : null;
      if (holder != null) {
        holder.lastSid = null; // the runner closed it itself: nothing left to close or restore
        holder.frozen = false; // nothing frozen is left to swap out
        _dropOld(e.sid, holder.sid);
        final start = _starts.remove(e.sid);
        if (start != null) resources.linkDown(start); // what it was still sending ends 没传完
        // A move whose old session went (A gave its window to the new one): the new one is all
        // there is, so the move is done.
        _rerouteEnd(holder, true);
        notifyListeners();
      }
      return;
    }
    // The runner saw nothing arrive for a while: the hub probes the relay now (§5.1).
    if (e is StalledEvent && e.on && r.phase == Phase.live && hubUsable) hub!.netSuspect();
    if (e is ClosedEvent) {
      if (r.phase == Phase.disconnected) return; // ended by us already, or by nobody's business
      _waiting.remove(e.sid)?.timer.cancel();
      final name = r.appName;
      final batch = _batchEnded.contains(r.key); // 全部结束 already said so (K13)
      _endRecord(r);
      if (!batch && !isDesktopScreen(r.app)) hint = endedHint(name, e.reason);
      notifyListeners();
      return;
    }
    if (e is InputBlockedEvent) {
      _inputFeedback(r, e.by);
      return;
    }
    if (e is HostNoticeActionEvent) {
      _nativeNoticeAction(r, e);
      return;
    }
    if (e is CoveredEvent) {
      final name = e.name.isEmpty ? e.bundle : e.name;
      _notify(r, HostNotice.covered(coveredText(name), coverId: e.id, dismissable: e.dismissable,
          desktop: !isDesktopApp(r.app)));
      notifyListeners();
      return;
    }
    if (e is AppOpenedEvent) {
      // The desktop session shows it already; A sends these for app sessions only.
      if (!isDesktopApp(r.app) && e.bundle.isNotEmpty) {
        final name = e.name.isEmpty ? e.bundle : e.name;
        _notify(r, HostNotice.opened(openedText(name), bundle: e.bundle, name: name));
        notifyListeners();
      }
      return;
    }
    final wasLocked = rs.screenLocked;
    _applyPortEvent(rs, e);
    if (e is ComposerDraftEvent && e.action != null) _nativeAction(rs, e.action!);
    if (e is ComposerDraftEvent && (e.send || e.retry)) unawaited(_submitNative(rs, e));
    if (e is ScreenLockedEvent) {
      if (wasLocked != e.locked) {
        _lockEpoch[e.sid] = (_lockEpoch[e.sid] ?? 0) + 1;
        if (wasLocked == false && e.locked) _manualLock.add(r.id);
        if (!e.locked) {
          _manualLock.remove(r.id);
          _unlockBusy.remove(r.id)?.cancel();
          _unlockRejected.remove(r.id);
        }
      }
      if (!e.locked) _autoUnconfirmed.remove(r.id);
      if (_unlockSeen.add(e.sid) && _countsForUnlock(r.app) && e.locked &&
          !_manualLock.contains(r.id) && !_unlockBusy.containsKey(r.id)) {
        final start = _starts[e.sid];
        if (start != null) unawaited(_autoUnlock(r, start, _lockEpoch[e.sid]!));
      }
    }
    if (e is ScreenLockedEvent && wasLocked != e.locked) {
      if (r.app == 'desktop:') {
        for (final child in _records.values) {
          if (child.id == r.id && isDesktopScreen(child.app) && child.phase == Phase.live && !child.ending) {
            port!.setBanner(child.sid!, e.locked ? childLockText : '');
          }
        }
      } else if (isDesktopScreen(r.app)) {
        port!.setBanner(e.sid, e.locked ? childLockText : '');
      }
    }
    if (e is WindowsEvent) _syncHidden(rs);
    final start = _starts[e.sid];
    if (start != null && e is ClipsEvent) {
      resources.addClips(r.key, start, _sourceOf(r), e.clips);
    } else if (start != null && e is TransferProgressEvent) {
      resources.transfer(r.key, start, _sourceOf(r), e);
    }
    if (e is DisconnectedEvent && r.phase != Phase.disconnected) {
      if (r.ending) {
        _finishEnding(r);
      } else {
        _disconnect(r, e.reason);
      }
    } else if (e is DetachedEvent) {
      _syncHidden(rs);
      if (e.detached) _syncNotice(r);
      // The hub logs one line per move (R10); keys typed on the stage no longer go to it.
      if (_reachable(r)) hub!.note(e.sid, e.detached ? 'detach' : 'attach', rs.tabs.tabs.length);
      if (e.detached && pictureFocused == e.sid) _blur();
    } else if (e is WindowsEvent) {
      _swapIfReady(r);
    }
    notifyListeners();
  }

  Timer? _blockedTimer;

  /// Each record's latest host notice (by record key: a reconnect keeps it), and its expiry.
  final _notices = <String, ({HostNotice notice, Timer timer, int epoch})>{};

  /// The notice for what is on show, if any.
  HostNotice? get hostNotice => currentKey == null ? null : _notices[currentKey]?.notice;

  int _noticeEpoch = 0;

  void _notify(SessionRecord r, HostNotice n) {
    _notices.remove(r.key)?.timer.cancel();
    final epoch = ++_noticeEpoch;
    late final Timer t;
    t = Timer(hostNoticeFor, () {
      if (_disposed || !identical(_notices[r.key]?.timer, t)) return;
      _clearHostNotice(r.key);
      notifyListeners();
    });
    _notices[r.key] = (notice: n, timer: t, epoch: epoch);
    _syncNotice(r);
  }

  void _syncNotice(SessionRecord r) {
    final entry = _notices[r.key], sid = r.sid;
    if (entry == null || sid == null) return;
    final n = entry.notice;
    portOf(sid)?.nativeHostNotice(sid, epoch: entry.epoch, text: n.text, actions: [
      if (n.dismissable && n.coverId != null) {'id': 'dismiss', 'label': '关掉它'},
      if (n.desktop) {'id': 'desktop', 'label': '在桌面会话里处理'},
      if (n.bundle != null) {'id': 'open', 'label': '打开'},
      {'id': 'close', 'label': '关闭提示'},
    ]);
  }

  void _clearHostNotice(String key) {
    final entry = _notices.remove(key);
    entry?.timer.cancel();
    final sid = _records[key]?.sid;
    if (entry != null && sid != null) {
      portOf(sid)?.nativeHostNotice(sid, epoch: entry.epoch, text: '', actions: const []);
    }
  }

  void _nativeNoticeAction(SessionRecord r, HostNoticeActionEvent e) {
    final entry = _notices[r.key];
    if (entry == null || entry.epoch != e.epoch || r.phase != Phase.live || r.ending) return;
    final n = entry.notice;
    switch (e.action) {
      case 'dismiss':
        if (!n.dismissable || n.coverId == null) return;
        portOf(e.sid)?.dismissCover(e.sid, n.coverId!);
      case 'desktop':
        if (!n.desktop) return;
        unawaited(openOrSwitch(r.id, 'desktop:', '桌面'));
      case 'open':
        if (n.bundle == null) return;
        unawaited(openOrSwitch(r.id, n.bundle!, n.name!));
      case 'close':
        break;
      default:
        return;
    }
    _clearHostNotice(r.key);
    notifyListeners();
  }

  /// The notice on show goes (its ×, or after one of its buttons).
  void closeHostNotice() {
    final k = currentKey;
    if (k == null) return;
    _clearHostNotice(k);
    notifyListeners();
  }

  /// 「在桌面会话里处理」: the desktop session of the device on show opens, or comes forward.
  void noticeDesktop() {
    final r = currentRecord;
    if (r == null) return;
    closeHostNotice();
    unawaited(openOrSwitch(r.id, 'desktop:', '桌面'));
  }

  /// 「关掉它」: A closes the cover (A itself refuses anything not safe to close).
  void noticeDismiss() {
    final r = currentRecord;
    final id = hostNotice?.coverId;
    final sid = r?.sid;
    if (r == null || id == null || sid == null || r.phase != Phase.live) return;
    portOf(sid)?.dismissCover(sid, id);
    closeHostNotice();
  }

  /// 「打开」: the app A just opened, as a session of its own.
  void noticeOpen() {
    final r = currentRecord;
    final n = hostNotice;
    if (r == null || n == null || n.bundle == null) return;
    closeHostNotice();
    unawaited(openOrSwitch(r.id, n.bundle!, n.name!));
  }

  void _inputFeedback(SessionRecord r, String by) {
    const prefix = 'unlock-failed: ';
    if (by.startsWith(prefix)) {
      // Keep the timer: an unconfirmed automatic attempt must still disable
      // auto entry. Its timeout must not overwrite the host's specific reason.
      if (_unlockBusy.containsKey(r.id)) _unlockRejected.add(r.id);
      if (currentRecord?.id == r.id) {
        hint = '无法解锁：${by.substring(prefix.length)}';
        notifyListeners();
      }
    } else if (r.key == currentKey) {
      _showBlocked(by);
    }
  }

  /// 「远端正在被 X 操作」 for [blockedHintFor], only while it is still the hint.
  void _showBlocked(String by) {
    final text = inputBlockedHint(by);
    hint = text;
    _blockedTimer?.cancel();
    _blockedTimer = Timer(blockedHintFor, () {
      if (_disposed || hint != text) return;
      hint = '';
      notifyListeners();
    });
    notifyListeners();
  }

  /// [sid] is what a frozen record keeps on the stage: its writing panel sends nothing (offline-freeze).
  bool sendBlocked(Object sid) => _records.values.any((r) => r.frozen && (r.lastSid ?? r.sid) == sid);

  String _sourceOf(SessionRecord r) => '${r.appName} @ ${deviceName(r.id)}';

  /// The link of [r] ended with [raw] (the runner's or the hub's words): the record stays, with its
  /// last frame, until the user reconnects or ends it. [retry] false: no automatic try is planned.
  /// Callers notify.
  void _disconnect(SessionRecord r, String raw,
      {bool hint = false, String? hintText, bool failedOpen = false, bool retry = true}) {
    if (isDesktopScreen(r.app)) {
      if (r.sid != null) port?.close(r.sid!);
      _endRecord(r);
      return;
    }
    if (r.app == 'desktop:') _endDesktopChildren(r.id);
    final x = _reroutes[r];
    if (x != null && x.fresh != null && x.fresh == r.sid && r.lastSid != null) {
      // The new session of a move went before it took the stage: the old one carries on.
      _rerouteFailed(r);
      return;
    }
    _rerouteEnd(r, false);
    if (r.lastSid != null) {
      // A reconnect that never reached the stage: its new sid goes, the old picture stays.
      final fresh = r.sid;
      if (fresh != null) {
        final start = _starts.remove(fresh);
        if (start != null) resources.linkDown(start);
        _keepIn(r.lastSid, _endTidy(fresh));
        remote.remove(fresh)?.dispose();
        _sentFps.remove(fresh);
        _waiting.remove(fresh)?.timer.cancel();
        portOf(fresh)?.close(fresh);
      }
      r.sid = r.lastSid;
      r.lastSid = null;
    }
    _batchEnded.remove(r.key);
    final sid = r.sid;
    final start = _startOf(sid);
    if (start != null) resources.linkDown(start);
    final rs = sid == null ? null : remote[sid];
    r.phase = Phase.disconnected;
    r.reason = r.userDisconnect ? 'user' : raw;
    // Frozen only over something on show: a first open that failed has no picture to keep.
    r.frozen = autoReconnects(r.reason) && rs != null;
    if (r.frozen) {
      r.frozeFor = r.reason;
      rs?.policy.cancel();
    }
    r.seq = ++_seq;
    if (rs != null) {
      r.choice = rs.choice;
      r.pinned = rs.streamPinned;
      r.window = rs.currentWindow;
      rs.bytesPerSecond = 0;
      if (sid != null) portOf(sid)?.freeze(sid, r.reason ?? raw);
      rs.linkDown(); // the runner may have said nothing (hub-first): same cleanup as its word
    }
    if (sid != null) {
      _sentFps.remove(sid);
      _waiting.remove(sid)?.timer.cancel();
      if (pictureFocused == sid) _blur();
    }
    final auto = retry && _planRetry(r);
    // A failed open that starts waiting still says why once; later automatic tries stay quiet.
    if (hint && (!auto || (failedOpen && r.retry?.$1 == 0))) this.hint = hintText ?? '${r.appName} 已断开：${disconnectWord(r.reason)}';
  }

  /// Per-record timers of the automatic reconnect (the record's `retry` says the rest).
  final Map<String, Timer> _retryTimers = {};

  /// After [r] went down: schedules the next automatic try when it is due. True: it did.
  /// A failed open (the first one, or a manual reconnect) for a network reason waits too (§5.3.7).
  bool _planRetry(SessionRecord r) {
    if (backgrounded) {
      // The iPad app is in the background (spec §9): nothing reconnects until it comes back, which
      // tries again whatever still waits.
      _retryTimers.remove(r.key)?.cancel();
      return false;
    }
    final cur = r.retry;
    final int attempt;
    if (cur != null) {
      if (stopsAutoReconnect(r.reason)) {
        _stopRetry(r);
        return false;
      }
      attempt = cur.$1 + 1;
    } else if (autoReconnects(r.reason)) {
      attempt = 0;
    } else {
      return false;
    }
    _retryTimers.remove(r.key)?.cancel();
    // An offline host: no timer, the hub watches for it (`presence online` reconnects). A relayed
    // session while the link to the relay is down: no timer, the link coming back reconnects.
    if (waitsForPeer(r) || _held(r)) {
      r.retry = (attempt, DateTime.now());
      _syncWatch(r.id);
      return true;
    }
    final wait = Duration(seconds: attempt == 0 ? 1 : math.min(1 << attempt, 15));
    r.retry = (attempt, DateTime.now().add(wait));
    _retryTimers[r.key] = Timer(wait, () {
      _retryTimers.remove(r.key);
      if (_disposed || _records[r.key] != r || r.retry == null) return;
      if (r.phase != Phase.disconnected || !hubUsable) {
        r.retry = null;
        notifyListeners();
        return;
      }
      if (_held(r)) {
        notifyListeners(); // the wait word changes; the link coming back reconnects
        return;
      }
      reconnect(r.key, auto: true);
    });
    _syncWatch(r.id);
    return true;
  }

  /// Cancels [r]'s automatic reconnect, if any. Callers notify.
  void _stopRetry(SessionRecord r) {
    _retryTimers.remove(r.key)?.cancel();
    r.retry = null;
    _syncWatch(r.id);
  }

  /// The level of the link to the relay last seen (`HubClient.net`), to see it come back.
  NetLevel? _netLevel;

  /// The link to the relay is down (the network marker's 断开).
  bool get netDown => hub?.net?.level == NetLevel.down;

  /// [r] goes (or went) through the relay: its path says so, or its failure was the relay's word.
  bool relayed(SessionRecord r) {
    if (r.path == 'relay') return true;
    final w = disconnectWord(r.reason);
    return w == '对方离线' || w == '中继连不上';
  }

  /// What [r]'s automatic retry waits for, for the disconnected stage (`waitWord`).
  String? waitWordOf(SessionRecord r) => waitWord(r, relayed: relayed(r), net: hub?.net?.level);

  /// [r] waits for its host to come online (an automatic retry after 对方离线).
  bool waitsForPeer(SessionRecord r) => r.retry != null && disconnectWord(r.reason) == '对方离线';

  /// [r]'s automatic retry waits for the link to the relay.
  bool _held(SessionRecord r) => relayed(r) && netDown;

  /// Hosts the hub was asked to watch (`{"cmd":"watch"}`).
  final Set<String> _watching = {};

  /// Tells the hub to watch host [id] while a record of it waits for it, and to stop after.
  void _syncWatch(String id) {
    final h = hub;
    if (h == null || !h.alive) {
      _watching.clear();
      return;
    }
    final want = _records.values.any((r) => r.id == id && r.phase == Phase.disconnected && waitsForPeer(r));
    if (want == _watching.contains(id)) return;
    want ? _watching.add(id) : _watching.remove(id);
    h.watch(id, want);
  }

  /// Host [id] came online: its records waiting for it reconnect, one every 200 ms. The hub's
  /// watch ended with that answer.
  void _peerBack(String id) {
    _watching.remove(id);
    _retryEach([
      for (final r in _records.values)
        if (r.id == id && r.phase == Phase.disconnected && waitsForPeer(r)) r,
    ]);
  }

  /// The link to the relay is back: relayed records waiting on it reconnect, one every 200 ms.
  /// Those waiting for an offline host keep waiting for it.
  void _netBack() {
    _retryEach([
      for (final r in _records.values)
        if (r.phase == Phase.disconnected && r.retry != null && relayed(r) && !waitsForPeer(r)) r,
    ]);
  }

  /// Reconnects [rs] automatically, the first at once, each next one 200 ms later, so they do not
  /// all ask the relay in the same instant.
  void _retryEach(List<SessionRecord> rs) {
    for (final (i, r) in rs.indexed) {
      _retryTimers.remove(r.key)?.cancel();
      _retryTimers[r.key] = Timer(Duration(milliseconds: 200 * i), () {
        _retryTimers.remove(r.key);
        if (_disposed || _records[r.key] != r || r.retry == null) return;
        if (r.phase != Phase.disconnected || !hubUsable) return;
        reconnect(r.key, auto: true);
      });
    }
  }

  /// A live relayed session of host [id] whose far segment (relay to the host) is weak.
  bool peerWeak(String id) {
    for (final r in _records.values) {
      if (r.id != id || r.phase != Phase.live || r.path != 'relay') continue;
      final rs = r.sid == null ? null : remote[r.sid];
      if (rs == null) continue;
      final seg = segments(path: r.path, wholeMs: rs.rttMs, net: hub?.net);
      if (seg.peer != null && seg.peer! >= weakRttMs) return true;
    }
    return false;
  }

  /// 「停止」 on the disconnected stage or the offline bar.
  void stopReconnect(String key) {
    final r = _records[key];
    if (r == null || r.retry == null) return;
    _stopRetry(r);
    r.stopped = r.phase != Phase.disconnected; // a try in flight finishes by [_stopTry]
    notifyListeners();
  }

  void stopReconnectCurrent() {
    final k = currentKey;
    if (k != null) stopReconnect(k);
  }

  /// The try in flight of [r] finishes after 「停止」: a frozen record stays frozen under its bar, with
  /// its network words, 「重连」 and no new try (offline-freeze spec); any other is the user's own
  /// disconnect. Callers notify.
  void _stopTry(SessionRecord r) {
    r.stopped = false;
    r.frozen ? _disconnect(r, r.frozeFor ?? 'connection closed', retry: false) : _disconnect(r, 'user');
  }

  /// [r] was being ended and its link went away before the runner's `ClosedEvent`: that finishes
  /// the end; it never turns 已断开 (S5-5b). Callers notify.
  void _finishEnding(SessionRecord r) {
    final batch = _batchEnded.contains(r.key); // 全部结束 already said so (K13)
    _endRecord(r);
    if (!batch && !isDesktopScreen(r.app)) hint = '已结束 ${r.appName}';
  }

  /// Takes [r] off the list and steps to the next session if it was current. Callers set the hint.
  void _endRecord(SessionRecord r) {
    _notices.remove(r.key)?.timer.cancel();
    if (r.app == 'desktop:') {
      _endDesktopChildren(r.id);
      _desktopDisplays.remove(r.id);
      _hintedScreens.remove(r.id);
    }
    _rerouteEnd(r, false);
    _batchEnded.remove(r.key);
    _stopRetry(r);
    final oldGroups = groups;
    final old = r.lastSid;
    if (old != null) portOf(old)?.close(old); // reconnected but not swapped yet: the old session is still open
    // Before a swap the old session is the one on show, the one written in. A waiting tidy's
    // original goes after the editor's text is read (an editor makes a keep asynchronous).
    final originals = [
      for (final sid in [r.sid, old])
        if (sid != null) ?_endTidy(sid),
    ];
    final shown = remote[old] ?? remote[r.sid];
    unawaited(recorder.sessionEnded(shown, _metaOf(r, shown),
        record: shown?.recordsInput ?? profiles.resolve(r.app).recordInput, extra: originals));
    _releaseUnlockBusy(r);
    for (final sid in [r.sid, old]) {
      if (sid == null) continue;
      remote.remove(sid)?.dispose();
      _unlockSeen.remove(sid);
      _lockEpoch.remove(sid);
      _sentFps.remove(sid);
      _waiting.remove(sid)?.timer.cancel();
    }
    resources.sessionEnded(r.key, {
      for (final sid in [r.sid, old])
        if (sid != null) ?_starts.remove(sid),
    });
    _records.remove(r.key);
    _entries = _mapEntries();
    if (currentKey == r.key) {
      currentKey = isDesktopScreen(r.app) && _records.containsKey('${r.id}/desktop:')
          ? '${r.id}/desktop:'
          : _nextAfterEnd(oldGroups, r.key, _records.containsKey);
    }
  }

  /// The old session [old] of a reconnect goes for good and [fresh] stands for the window now:
  /// what was written in the old composer carries over (text only).
  void _dropOld(Object old, Object? fresh) {
    final gone = remote.remove(old);
    if (gone == null) return;
    final to = fresh == null ? null : remote[fresh];
    final tidy = _tidies.remove(old);
    if (tidy != null) {
      if (to != null) {
        _tidies.remove(fresh)?.dispose();
        _tidies[fresh!] = tidy..moveTo(fresh);
      } else {
        // No successor yet (the old end came before the new open): into the old draft, which the
        // record keeps for the next open (review 2026-11-20 #1).
        final original = tidy.end();
        tidy.dispose();
        if (original != null) gone.composer.keepNow(original);
      }
    }
    final moved = to?.composer.adoptFrom(gone.composer);
    to?.adoptZoom(gone);
    recorder.detach(gone, to: to, moved: moved);
    gone.dispose();
  }

  /// A reconnect's first window with a picture: the new session takes the stage, the old one goes.
  void _swapIfReady(SessionRecord r) {
    final old = r.lastSid;
    final fresh = r.sid;
    if (old == null || fresh == null) return;
    final rs = remote[fresh];
    // A terminal has no picture: its first window table is what it shows.
    final shows = termPort?.owns(fresh) == true ? rs?.windows.isNotEmpty : rs?.windows.any((w) => w.hasPicture);
    if (rs == null || shows != true) return;
    final detached = remote[old]?.detached ?? false;
    // A frozen stage keeps its writing panel: open (and focused) before, open (and focused) after.
    final oldComposer = remote[old]?.composer;
    final keepOpen = r.frozen && oldComposer?.open == true;
    final keepFocus = keepOpen && oldComposer?.editorFocused == true;
    portOf(old)?.close(old);
    _dropOld(old, fresh);
    if (keepOpen) {
      rs.composer.open = true;
      if (keepFocus) rs.composer.wantFocus();
    }
    final start = _starts.remove(old);
    if (start != null) resources.linkDown(start); // what it was still sending ends 没传完
    // A frozen terminal's stage element is reused: it keeps its focus, so the fresh sid is not newly staged.
    if (r.frozen && termPort?.owns(fresh) == true && identical(r, currentRecord)) _stagedTerm = fresh;
    r.lastSid = null;
    r.frozen = false;
    if (_reroutes.containsKey(r)) {
      if (pictureFocused == old) {
        // A move: the keys typed into the old picture go on into the new one.
        pictureFocused = fresh;
        _sendFocus(fresh);
      }
      // A move keeps the session where the user put it: off the stage stays off.
      if (detached && portOf(fresh)?.supportsDetach == true) unawaited(_detachSession(rs));
    }
    _rerouteEnd(r, true);
  }

  /// Opens (or reopens, [reconnect]) the hub session of [r] and starts the runner on it.
  /// [quiet]: no 「已打开」 hint at the end (failures still say why).
  /// [reroute]: a move of the live [r] onto the hub's new link ([reroute] the method). The old session
  /// stays the record's own until the new one has opened; then it is [SessionRecord.lastSid], on the
  /// stage until [_swapIfReady]. Failing, it stays on its route and nothing is said.
  Future<void> _connect(SessionRecord r, {bool reconnect = false, bool quiet = false, bool reroute = false}) async {
    final x = reroute ? _reroutes[r] : null;
    final old = r.sid;
    final term = isTermApp(r.app);
    if (term && termPort == null) {
      // No terminal port here: nothing is opened, the record fails like a failed open.
      _disconnect(r, noTermPortWord, hint: true, failedOpen: true);
      notifyListeners();
      return;
    }
    final epoch = _backgroundEpoch;
    final HubSession s;
    try {
      s = await hub!.open(r.id, r.app, embed: true, reconnect: reconnect);
    } catch (e) {
      if (!reroute && epoch != _backgroundEpoch) return; // the background already settled the record
      if (reroute) {
        if (_reroutes[r] == x) _rerouteFailed(r);
        notifyListeners();
        return;
      }
      if (r.ending) return;
      if (r.stopped) {
        _stopTry(r);
        notifyListeners();
        return;
      }
      final missing = missingFromError('$e');
      _disconnect(r, '$e',
          hint: true, hintText: missing == null ? null : remoteHint(deviceName(r.id), missing), failedOpen: true);
      notifyListeners();
      return;
    }
    if (!reroute && epoch != _backgroundEpoch) {
      // Opened from before the app went to the background (spec §9): the background disconnected the
      // record meanwhile, and coming back opens anew. This session is not wanted, and it never starts.
      _quiet.add(s.sid);
      hub!.close(s.sid, reason: 'background');
      return;
    }
    if (r.ending || (reroute && (_reroutes[r] != x || !_movable(r) || r.sid != old))) {
      // Ended while it was connecting (R14), or a move that was dropped or timed out meanwhile:
      // the session that just opened is not wanted.
      _quiet.add(s.sid);
      hub!.close(s.sid);
      if (reroute && _reroutes[r] == x) _rerouteEnd(r, false);
      return;
    }
    if (r.stopped) {
      // 「停止」 came while it was opening: the new link is closed quietly, the record stays disconnected.
      _quiet.add(s.sid);
      hub!.close(s.sid);
      _stopTry(r);
      notifyListeners();
      return;
    }
    if (x != null) {
      r.lastSid = old;
      x.fresh = s.sid;
      x.path = s.path; // the label follows at the swap: until then the stage shows the old route
    } else {
      r.path = s.path;
    }
    r.sid = s.sid;
    _starts[s.sid] = _Start(s.sid);
    _releaseUnlockBusy(r);
    _unlockSeen.remove(s.sid);
    _lockEpoch.remove(s.sid);
    final rs = RemoteSession(s.sid, r.appName, onResize: (w, a, b) {
          if (_liveSid(s.sid)) portOf(s.sid)!.resize(s.sid, w, a, b);
        },
        onSelect: (w) {
          if (_liveSid(s.sid)) portOf(s.sid)!.selectWindow(s.sid, w);
        },
        onStream: (choice) => _streamChanged(r, choice),
        onDropBlock: (n) => portOf(s.sid)!.composerDropBlock(s.sid, n),
        appId: r.app,
        onReturn: () {
          if (_liveSid(s.sid)) portOf(s.sid)!.key(s.sid, returnKeyCode, 0);
        },
        onSelectInput: (id) {
          if (_liveSid(s.sid)) portOf(s.sid)!.selectInput(s.sid, id);
        },
        onClick: (w, at) {
          if (!_liveSid(s.sid)) return;
          portOf(s.sid)!.mouse(s.sid, w, 'down', 'left', at.dx, at.dy, 1);
          portOf(s.sid)!.mouse(s.sid, w, 'up', 'left', at.dx, at.dy, 1);
        },
        onView: (w, rect, z) {
          if (_liveSid(s.sid)) portOf(s.sid)!.setView(s.sid, w, rect, z);
        },
        onComposeKey: () => tidyIfAny(s.sid)?.closed(),
        followNewTabs: !term);
    rs.composer.onAiSent = (ai, text) => _offerEditLearns(rs.sid, ai.original, editLearns(ai.original, ai.result, text));
    // Without the AI: what the user changed in the device's fixed words, against what was heard (spec D8).
    rs.composer.onHeardSent = (h, text) => _offerEditLearns(rs.sid, h.heard, editLearns(h.heard, h.fixed, text));
    final prof = profiles.resolve(r.app);
    rs.setProfile(prof);
    // Wired before any swap's adoptFrom; a reconnect's old session hands its text over itself.
    recorder.attach(rs, () => _metaOf(r, rs), restore: r.lastSid == null);
    // A tidy that was waiting when the app last went: its original comes back once.
    if (r.lastSid == null) {
      final back = _tidyHeld.take(r.key);
      if (back != null) rs.composer.keepNow(back);
    }
    rs.composer.recall = () => [for (final e in recallOf(rs)) e.text];
    if (prof.name != null) _log('rapp: app 配置「${prof.name}」');
    rs.choice = r.choice;
    rs.streamPinned = r.pinned;
    rs.preferWindow(r.window);
    remote[s.sid] = rs;
    rs.addListener(_syncCompose);
    rs.composer.addListener(_syncCompose); // the panel opening or closing moves [_voiceFor]
    r.phase = Phase.live;
    if (r.lastSid == null) r.frozen = false; // no old picture to swap out: nothing stays frozen
    final c = r.choice;
    try {
      final p = s.port, tk = s.token;
      if (p == null || tk == null) throw 'rapp-hub 没有给出嵌入端口';
      await (term ? termPort! : port!).start(StartArgs(s.sid, p, tk, c.mode, c.fps, c.density));
    } catch (e) {
      if (r.sid != s.sid) return; // it was dropped while starting: that already settled the record
      if (x != null && _reroutes[r] == x && !r.ending && _records[r.key] == r) {
        _rerouteFailed(r);
        notifyListeners();
        return;
      }
      final original = _endTidy(s.sid);
      if (original != null) remote[s.sid]?.composer.keepNow(original); // the record's draft keeps it
      remote.remove(s.sid)?.dispose();
      _starts.remove(s.sid);
      _quiet.add(s.sid);
      hub!.close(s.sid);
      r.sid = null;
      if (r.ending || _records[r.key] != r) {
        // Ended while starting (M-6): the record goes, it never comes back as disconnected.
        if (_records[r.key] == r) _endRecord(r);
        notifyListeners();
        return;
      }
      if (r.stopped) {
        _stopTry(r);
      } else {
        _disconnect(r, '$e', hint: true, failedOpen: true);
      }
      notifyListeners();
      return;
    }
    if (r.sid != s.sid || r.phase != Phase.live || r.ending) return;
    if (r.stopped) {
      if (r.frozen) {
        // 「停止」 came while it was starting over a frozen stage: the new link goes quietly, the bar stays.
        _quiet.add(s.sid);
        hub!.close(s.sid);
        _stopTry(r);
      } else {
        // 「停止」 came while it was starting: close the link as the user's own disconnect.
        r.stopped = false;
        r.userDisconnect = true;
        hub!.close(s.sid, reason: 'user');
      }
      notifyListeners();
      return;
    }
    r.retry = null;
    _syncWatch(r.id);
    // start carries no pin: with automatic saving off, the first set_stream says so.
    _sentFps[s.sid] = (c.mode, c.fps, c.density, false, false);
    if (_pinned || _wantsFocus(rs, r)) _applyFps();
    if (!reconnect && !quiet) hint = '已打开 ${r.appName} @ ${deviceName(r.id)}';
    if (isDesktopScreen(r.app)) {
      final main = _records['${r.id}/desktop:'];
      if (remote[main?.sid]?.screenLocked == true) port!.setBanner(s.sid, childLockText);
    }
    notifyListeners();
    if (r.app == 'desktop:') unawaited(_refreshDesktop(r));
  }

  /// What an input record says of [r]'s session [rs] now (no window without one).
  SessionMeta _metaOf(SessionRecord r, RemoteSession? rs) {
    final w = rs?.currentWindow;
    return SessionMeta(
      key: r.key,
      hostId: r.id,
      hostName: deviceName(r.id),
      appId: r.app,
      appName: r.appName,
      run: r.run,
      windowId: w,
      windowTitle: w == null ? null : rs!.windows.where((x) => x.id == w).firstOrNull?.title,
      projects: [for (final p in projectsOf(r.key)) p.name],
    );
  }

  /// Opens the disconnected session [key] again, in the same place with the same choices.
  /// [auto]: the automatic retry's own try (it keeps the `retry` state); a manual one cancels it.
  Future<void> reconnect(String key, {bool auto = false}) async {
    final r = _records[key];
    if (r == null || r.phase != Phase.disconnected || !hubUsable || backgrounded) return;
    if (!auto) _stopRetry(r);
    r.stopped = false;
    r.lastSid = r.sid;
    r.sid = null;
    r.phase = Phase.connecting;
    r.userDisconnect = false;
    r.reason = null;
    notifyListeners();
    await _connect(r, reconnect: true);
  }

  void reconnectCurrent() {
    final r = currentRecord;
    if (r != null) reconnect(r.key);
  }

  // ---- the iPad app in the background (iPad spec §9) ----
  /// The app is in the background: every session was frozen on its last frame and closed, nothing
  /// reconnects until [enterForeground].
  bool backgrounded = false;

  /// Bumped by each [enterBackground]: an open asked before it is not wanted when it answers.
  int _backgroundEpoch = 0;

  /// How long [enterBackground] waits for the hub to drop the closed sessions.
  static const backgroundCloseWait = Duration(seconds: 4);

  /// A live session is on the stage (not 全景, not in the background): the screen stays awake and the
  /// edge gestures are held (spec §9.5).
  bool get stageLive => !backgrounded && !overview && !logs && currentRecord?.phase == Phase.live;

  /// The app went to the background (spec §9.1). Held modifiers are let go, presence pauses, and each
  /// live or connecting session freezes on its last frame and is closed with reason `background`; then
  /// it waits until the hub dropped them, at most [backgroundCloseWait]. [begin] and [end] bracket it
  /// (the system's background time); their failures are not this one's.
  Future<void> enterBackground({Future<void> Function()? begin, Future<void> Function()? end}) async {
    if (backgrounded) return;
    backgrounded = true;
    final epoch = ++_backgroundEpoch;
    try {
      await begin?.call();
    } catch (_) {}
    try {
      // Shown again while the background time was being asked for: nothing closes (`end` still runs).
      if (!backgrounded || epoch != _backgroundEpoch) return;
      // The ups go out over the sessions while they are still open.
      appLatch.releaseAll();
      final h = hub;
      h?.pausePresence(true);
      for (final t in _retryTimers.values) {
        t.cancel();
      }
      _retryTimers.clear();
      for (final r in _reroutes.keys.toList()) {
        _rerouteFailed(r); // the old session of a move is the one that freezes below
      }
      final closing = <Object>{};
      for (final r in _records.values.toList()) {
        if (_records[r.key] != r || r.ending || r.phase == Phase.disconnected) continue;
        final sids = {?r.sid, ?r.lastSid};
        _disconnect(r, 'background', retry: false);
        _stopRetry(r);
        for (final sid in sids) {
          if (!_hubHas(sid)) continue;
          _quiet.add(sid);
          closing.add(sid);
          h!.close(sid, reason: 'background');
        }
      }
      notifyListeners();
      if (h != null && closing.isNotEmpty) await _hubDropped(h, closing);
    } finally {
      try {
        await end?.call();
      } catch (_) {}
    }
  }

  /// Completes once the hub lists none of [sids] (or it is gone), at most [backgroundCloseWait].
  Future<void> _hubDropped(HubClient h, Set<Object> sids) async {
    bool gone() => !h.alive || !h.sessions.any((s) => sids.contains(s.sid));
    if (gone()) return;
    final done = Completer<void>();
    void check() {
      if (gone() && !done.isCompleted) done.complete();
    }
    h.addListener(check);
    try {
      await done.future.timeout(backgroundCloseWait, onTimeout: () {});
    } finally {
      h.removeListener(check);
    }
  }

  /// The app is back (spec §9.2): the hub checks its network, presence resumes, and the sessions the
  /// background closed reconnect, the selected one first, each next one [stagger] later. Those that
  /// were waiting for an automatic try before go on waiting.
  Future<void> enterForeground({Duration stagger = const Duration(milliseconds: 300)}) async {
    if (!backgrounded) return;
    backgrounded = false;
    final h = hub;
    // iOS took the hub's socket while the app was away: a new one, and every device asked again.
    h?.netChanged();
    h?.pausePresence(false);
    bool closedByBackground(SessionRecord r) => r.phase == Phase.disconnected && r.reason == 'background';
    final cur = currentRecord;
    final list = [
      if (cur != null && closedByBackground(cur)) cur,
      for (final r in _records.values)
        if (r != cur && closedByBackground(r)) r,
    ];
    for (final (i, r) in list.indexed) {
      if (i == 0) {
        unawaited(reconnect(r.key, auto: true));
        continue;
      }
      _retryTimers.remove(r.key)?.cancel();
      _retryTimers[r.key] = Timer(stagger * i, () {
        _retryTimers.remove(r.key);
        if (_disposed || backgrounded || _records[r.key] != r || !closedByBackground(r)) return;
        reconnect(r.key, auto: true);
      });
    }
    // Automatic tries the background held back start over.
    for (final r in _records.values.toList()) {
      if (r.phase != Phase.disconnected || r.retry == null || list.contains(r)) continue;
      if (!_retryTimers.containsKey(r.key)) _planRetry(r);
    }
    notifyListeners();
  }

  /// The network changed under the app (iOS `pathChanged`: Wi-Fi to another Wi-Fi, to cellular, back
  /// after a loss): the hub starts over on a new socket.
  void netChanged() => hub?.netChanged();

  /// The system is short of memory (iOS): frozen sessions off the stage let go of their pictures.
  /// The one on the stage keeps its last frame (spec §9.1).
  void memoryWarning() {
    final cur = currentRecord;
    for (final r in _records.values) {
      if (!r.frozen || r == cur || r.phase != Phase.disconnected) continue;
      final sid = r.sid;
      if (sid != null) portOf(sid)?.dropTextures(sid);
    }
  }

  // ---- moving to a new route (UX spec §3) ----
  /// Moves in flight, by record.
  final Map<SessionRecord, _Reroute> _reroutes = {};

  /// The latest path the hub gave per host whose sessions are still to be moved.
  final Map<String, String> _moveTo = {};

  /// Hosts with a round of moves running: one at a time per host.
  final Set<String> _moving = {};

  /// [r] is still the user's live session: not ended, disconnected or gone.
  /// A terminal never moves: its reopen would wait for a picture it never shows ([_swapIfReady]).
  bool _movable(SessionRecord r) =>
      !isTermApp(r.app) &&
      _records[r.key] == r && r.phase == Phase.live && !r.ending && !r.userDisconnect && r.sid != null;

  /// Reopens the live embedded session [key] over the hub's current link (`reconnect: true`). Its
  /// old session stays on the stage, and gets the input, until the new one shows a window with a
  /// picture; then the old one is closed. True once swapped; false when it failed (the open or the
  /// start, or no picture within [rerouteTimeout]) — the old session then carries on, nothing said —
  /// or when the session was ended, disconnected or removed meanwhile (it is not brought back).
  Future<bool> reroute(String key) async {
    final r = _records[key];
    if (!embeds || !hubUsable || r == null || !_movable(r) || r.lastSid != null || _reroutes.containsKey(r)) {
      return false;
    }
    final x = _reroutes[r] = _Reroute();
    x.timer = Timer(rerouteTimeout, () {
      if (_reroutes[r] != x) return;
      _rerouteFailed(r);
      notifyListeners();
    });
    unawaited(_connect(r, reconnect: true, reroute: true));
    return x.done.future;
  }

  /// The move of [r] is over: [ok] it took the stage (its path becomes the record's).
  void _rerouteEnd(SessionRecord r, bool ok) {
    final x = _reroutes.remove(r);
    if (x == null) return;
    x.timer?.cancel();
    final p = x.path;
    if (ok && p != null) r.path = p;
    x.done.complete(ok);
  }

  /// The move of [r] did not make it: its new session (if any) goes quietly, the old one stays.
  void _rerouteFailed(SessionRecord r) {
    final x = _reroutes[r];
    if (x == null) return;
    final fresh = x.fresh, old = r.lastSid;
    if (fresh != null && r.sid == fresh && old != null) {
      final start = _starts.remove(fresh);
      if (start != null) resources.linkDown(start);
      _keepIn(old, _endTidy(fresh));
      remote.remove(fresh)?.dispose();
      _sentFps.remove(fresh);
      _waiting.remove(fresh)?.timer.cancel();
      _quiet.add(fresh);
      if (_hubHas(fresh)) hub!.close(fresh);
      portOf(fresh)?.close(fresh);
      r.sid = old;
      r.lastSid = null;
    }
    _rerouteEnd(r, false);
    // The old session may have ended meanwhile (its `closed` was not the record's then): down now.
    final sid = r.sid;
    if (sid != null && r.phase == Phase.live && !r.ending && !_hubHas(sid) && !_waiting.containsKey(sid)) {
      _disconnect(r, hub?.closeReasons.remove(sid) ?? 'connection closed');
    }
  }

  /// The hub cached a new link to [id] on [path]: its live sessions follow, one round at a time.
  void _pathChanged(String id, String path) {
    _moveTo[id] = path;
    if (_moving.add(id)) unawaited(_moveHost(id));
  }

  /// Rounds of moves for [id], each toward the latest path, in record order, each session at most
  /// once a round. A session that fails stops the round; toward the LAN the hub is told, so it
  /// waits before trying the LAN again (and says `path lan` again after). A newer path stops the
  /// round too: the next one goes by it. A reopen that lands elsewhere (the link moved again) is
  /// done: only a new `path` event starts another round.
  Future<void> _moveHost(String id) async {
    try {
      for (var path = _moveTo.remove(id); path != null && !_disposed; path = _moveTo.remove(id)) {
        for (final r in [for (final r in _records.values) if (r.id == id) r]) {
          if (_disposed || !hubUsable) return;
          if (_moveTo.containsKey(id)) break; // a newer path came: the rest go by it, next round
          if (!_movable(r) || r.lastSid != null || _reroutes.containsKey(r) || r.path == path) continue;
          // No window with a picture (minimised, or none yet): its reopen could never show one, so it
          // would time out and stop the round. It is skipped, not failed: its next reconnect takes the
          // hub's link as it is then.
          if (!(remote[r.sid]?.windows.any((w) => w.hasPicture) ?? false)) continue;
          if (await reroute(r.key)) continue;
          if (_disposed) return;
          if (!_movable(r)) continue; // ended, disconnected or removed meanwhile: skipped, not failed
          if (path == 'lan') hub!.routeFailed(id);
          break;
        }
      }
    } finally {
      _moving.remove(id);
    }
  }

  /// 「断开连接」: closes the link, keeps the session in the list.
  void disconnectCurrent() {
    final r = currentRecord;
    if (r == null || !_reachable(r)) return;
    r.userDisconnect = true;
    _stopRetry(r);
    // Mid-move: the new session goes first, so it is the old one that is closed and kept.
    if (_reroutes.containsKey(r)) {
      _rerouteFailed(r);
      if (!_reachable(r)) {
        notifyListeners();
        return;
      }
    }
    hub!.close(r.sid!, reason: 'user');
    notifyListeners();
  }

  Future<void> openOrSwitch(String id, String app, String appName) =>
      app == termsEntry ? _openTerms(id) : _open(id, app, appName);

  /// What the 终端 entry on [id] opens now: it follows the device's 打开方式 (spec §2.2).
  TermsTarget _termsTargetOf(String id) => termsTarget(
      mode: prefs.termOpenFor(id),
      list: hub?.termLists[id] ?? TermList(id),
      apps: probes[id]?.apps?.apps ?? const [],
      graphical: probes[id]?.apps?.capabilities?['graphical'] != false &&
          probes[id]?.apps?.capabilities?['applications'] != false);

  /// The key of the session [m] opens; null for a 终端 entry that opens a new text terminal.
  String? _openedKey(Member m) {
    if (m.app.bundle != termsEntry) return m.key;
    final id = m.app.device;
    return switch (_termsTargetOf(id)) {
      OpenTerm(:final app) => '$id/$app',
      OpenPixels(:final bundle) => '$id/$bundle',
      NewText() || NoTerminal() => null,
    };
  }

  /// The 终端 entry; [select] and [quiet] as for [_open].
  Future<void> _openTerms(String id, {bool select = true, bool quiet = false}) async {
    if (!hubUsable) return;
    switch (_termsTargetOf(id)) {
      case OpenTerm(:final app, :final name):
        return _open(id, app, name, select: select, quiet: quiet);
      case OpenPixels(:final bundle, :final name):
        return _open(id, bundle, name, select: select, quiet: quiet);
      case NoTerminal():
        hint = '这台设备没有可用的终端窗口，请在设备上安装终端并登录桌面后重试';
        notifyListeners();
      case NewText(:final shell):
        try {
          await openText(id, shell: shell);
        } catch (e) {
          hint = '$e';
          notifyListeners();
        }
    }
  }

  /// Opens a text terminal window on [id], then switches to it without waiting for the session to connect; a
  /// refusal is thrown with the hub's words.
  Future<void> openText(String id, {String? shell}) async {
    if (!hubUsable) return;
    final launchers = hub?.termLists[id]?.hosts.where((h) => h.host == null).firstOrNull?.launchers ?? const <String>[];
    if (launchers.isEmpty) throw StateError('这台设备没有可用的终端窗口');
    final app = prefs.termAppFor(id, launchers);
    final term = await hub!.openTerm(id, shell: shell, app: app);
    try {
      await hub?.terms(id);
    } catch (_) {}
    final row = hub?.termLists[id]?.terms.where((r) => r.id == term).firstOrNull;
    final shown = row == null ? '已结束' : termDisplayName(row.shown, row.host);
    unawaited(openOrSwitch(id, term, shown));
  }

  /// Renames text terminal [term] of device [device]; an invalid name or the device's refusal is thrown.
  Future<void> renameTerm(String device, String term, String name) async {
    final clean = cleanTermName(name);
    if (clean == null) throw const FormatException('名字不能为空，不能有控制字符，最长 64 个字符');
    await hub!.renameTerm(device, term, clean);
  }

  /// Opens [app] on [id], or switches to it if it is open. [select]: it becomes current and the
  /// panel closes; [quiet]: no 「已打开」 hint (failures still say why).
  Future<void> _open(String id, String app, String appName, {bool select = true, bool quiet = false}) async {
    if (!hubUsable) return;
    final key = '$id/$app';
    _batchEnded.remove(key);
    if (embeds) return _openEmbedded(id, app, appName, select: select, quiet: quiet);
    for (final e in _entries) {
      if (e.key == key && e.sid != null) {
        final rs = remote[e.sid];
        if (rs != null) {
          if (rs.detached) portOf(e.sid!)?.raiseDetached(e.sid!);
        } else {
          hub!.focus(e.sid!);
        }
        if (select) {
          currentKey = key;
          panel = null;
          overview = false;
          logs = false;
        }
        hint = '已切到 $appName';
        notifyListeners();
        return;
      }
    }
    if (_pending.containsKey(key)) return;
    _appNames[key] = appName;
    _pending[key] = SessionEntry(
      sid: null,
      id: id,
      app: app,
      appName: appName,
      device: deviceName(id),
      path: '',
      lamp: Lamp.connecting,
    );
    _entries = _mapEntries();
    final before = currentKey;
    if (select) {
      currentKey = key;
      panel = null;
      overview = false;
      logs = false;
    }
    notifyListeners();
    try {
      await hub!.open(id, app);
      _pending.remove(key);
      if (!quiet) hint = '已打开 $appName @ ${deviceName(id)}';
      // Opened while current: the leave or the remembered position waited for this.
      if (currentKey == key) _followCurrentKey();
    } catch (e) {
      _pending.remove(key);
      final missing = missingFromError('$e');
      hint = missing == null ? disconnectWord('$e') : remoteHint(deviceName(id), missing);
      _entries = _mapEntries();
      // Back to what was current before, if it is still open. Not selected by this open (全部打开
      // stopped on it): nothing to go back to that is known.
      if (currentKey == key) {
        currentKey = select && _entries.any((e) => e.key == before) ? before : null;
      }
    }
    _entries = _mapEntries();
    notifyListeners();
  }

  Map<String, Object> _nativeComposerStyle = const {};
  void setNativeComposerStyle(Map<String, Object> style) {
    if (mapEquals(style, _nativeComposerStyle)) return;
    _nativeComposerStyle = Map.unmodifiable(style);
    for (final rs in remote.values) { _syncHidden(rs); }
  }

  /// Sends native editor style and the hidden window set (D9: no titles in logs).
  void _syncHidden(RemoteSession rs) {
    portOf(rs.sid)?.nativeComposerOptions(rs.sid, allowed: rs.composerAllowed,
        compose: rs.composerAllowed && rs.profile.typeToCompose && rs.composeArmed, scale: composerScale, style: _nativeComposerStyle);
    final ids = rs.hiddenIds.toList()..sort();
    final last = _sentHidden[rs.sid] ?? const <int>[];
    if (!listEquals(ids, last)) {
      _sentHidden[rs.sid] = ids;
      if (_liveSid(rs.sid)) portOf(rs.sid)?.setHidden(rs.sid, ids);
    }
    final n = rs.hidden.length;
    if (n != (_loggedHidden[rs.sid] ?? 0)) {
      _loggedHidden[rs.sid] = n;
      if (n > 0) _log('rapp: app 配置「${rs.profile.name ?? rs.appName}」：隐藏 $n 个窗口');
    }
  }

  void _onProfiles() {
    for (final rs in remote.values) {
      rs.setProfile(profiles.resolve(rs.appId));
      _syncHidden(rs);
    }
    _applyFps(); // focusPane may have changed
    if (profiles.problem == appsSaveProblem) hint = appsSaveProblem;
    notifyListeners();
  }

  RemoteWindow? _windowById(RemoteSession rs, int window) => rs.windows.where((w) => w.id == window).firstOrNull;

  bool isMainWindow(int window) => currentRemote?.isMain(window) ?? false;

  /// The × on a child tab or a popup: a titled window closes (its close button on A), a sheet or
  /// popover gets an Esc (they have none).
  void closeWindow(int window) {
    final rs = currentRemote;
    final w = rs == null ? null : _windowById(rs, window);
    if (rs == null || w == null || !_liveSid(rs.sid)) return;
    if (w.decorated) {
      portOf(rs.sid)!.closeWindow(rs.sid, window);
    } else {
      portOf(rs.sid)!.key(rs.sid, escKeyCode, 0);
    }
  }

  /// The session whose next picture click marks its app's input box (not sent to A).
  Object? markingInput;

  /// 「标记输入区」: the main window becomes the tab, the next click on it is the mark.
  void markInput() {
    final rs = currentRemote;
    if (rs == null) return;
    final m = rs.windows.where((w) => rs.isMain(w.id)).firstOrNull;
    if (m != null && rs.currentWindow != m.id) rs.selectWindow(m.id);
    markingInput = rs.sid;
    hint = '点一下 ${rs.appName} 主窗口里的输入框（点画面外取消）';
    notifyListeners();
  }

  void cancelMarkInput() {
    if (markingInput == null) return;
    markingInput = null;
    hint = '';
    notifyListeners();
  }

  /// The marking click landed at [p], in A points of a content area of [size] (below the title bar).
  void markInputAt(Offset p, Size size) {
    final rs = currentRemote;
    if (rs == null || markingInput != rs.sid) return;
    markingInput = null;
    profiles.setInputPoint(rs.appId, rs.appName, InputPoint.at(p, size));
    hint = '已标记输入区：发送前会先点它';
  }

  /// The writing panel of [rs] was dragged to [p] (null: back to the default); kept for its app.
  /// A session of an unknown app has nowhere to keep it.
  void placeComposer(RemoteSession rs, InputPoint? p) {
    if (termPort?.owns(rs.sid) == true) {
      prefs.termComposerAt = p;
      _save();
      notifyListeners();
      return;
    }
    if (rs.appId.isEmpty) return;
    profiles.setComposerAt(rs.appId, rs.appName, p);
  }

  /// Where the writing panel of [rs] stands: one shared place for every text terminal, the app's own otherwise.
  InputPoint? composerAtOf(RemoteSession rs) =>
      termPort?.owns(rs.sid) == true ? prefs.termComposerAt : rs.profile.composerAt;

  /// The ＋ menu's 「直接回车且隐藏」 for [rs]'s app; a session without an app id has no profile to keep it in.
  void setAfterSend(RemoteSession rs, AfterSend a) {
    if (rs.appId.isEmpty) return;
    profiles.setAfterSend(rs.appId, rs.appName, a);
  }

  void clearInputMark() {
    final rs = currentRemote;
    if (rs == null) return;
    profiles.setInputPoint(rs.appId, rs.appName, null);
    hint = '已清除输入区标记';
    notifyListeners();
  }

  /// Hides windows like [window] (kind and title) for this app; null for the main window (R8)
  /// or without a current session. The result undoes it.
  VoidCallback? hideLike(int window) {
    final rs = currentRemote;
    final w = rs == null ? null : _windowById(rs, window);
    if (rs == null || w == null || rs.isMain(window)) return null;
    final snap = profiles.snapshot();
    profiles.addRule(rs.appId, rs.appName, WindowRule(kind: w.kind, title: w.title, action: RuleAction.hide));
    return () => profiles.restore(snap);
  }

  /// No composer on windows like [window]; null without a current session.
  VoidCallback? noComposerLike(int window) {
    final rs = currentRemote;
    final w = rs == null ? null : _windowById(rs, window);
    if (rs == null || w == null) return null;
    final snap = profiles.snapshot();
    profiles.addRule(rs.appId, rs.appName,
        WindowRule(kind: w.kind, title: w.title, child: !rs.isMain(window), action: RuleAction.noComposer));
    return () => profiles.restore(snap);
  }

  void showHiddenOnce(int window) {
    final rs = currentRemote;
    if (rs == null) return;
    rs.showOnce(window);
    _syncHidden(rs);
    notifyListeners();
  }

  void unhide(int window) {
    final rs = currentRemote;
    final w = rs == null ? null : _windowById(rs, window);
    if (rs == null || w == null) return;
    if (profiles.removeHideRule(rs.appId, w, isMain: rs.isMain(window))) {
      hint = '不再隐藏这类窗口';
      notifyListeners();
    }
  }

  void rememberStream() {
    final rs = currentRemote;
    if (rs == null) return;
    profiles.rememberStream(rs.appId, rs.appName, rs.choice);
    hint = '已记为 ${profiles.resolve(rs.appId).name ?? rs.appName} 的默认';
    notifyListeners();
  }

  Future<void> _openEmbedded(String id, String app, String appName, {bool select = true, bool quiet = false}) async {
    final key = '$id/$app';
    _appNames[key] = appName;
    final r = _records[key];
    if (select) {
      currentKey = key;
      panel = null;
      overview = false;
      logs = false;
    }
    if (r == null) {
      final fresh = SessionRecord(id, app, appName, '');
      fresh.choice = profiles.resolve(app).stream;
      if (isDesktopScreen(app)) {
        final main = _records['$id/desktop:'];
        final rs = remote[main?.sid];
        if (rs != null) {
          fresh.choice = rs.choice;
          fresh.pinned = rs.streamPinned;
        }
      }
      _records[key] = fresh;
      notifyListeners();
      await _connect(fresh, quiet: quiet);
    } else if (r.phase == Phase.disconnected) {
      await reconnect(key);
    } else {
      final rs = _stageRemote(r);
      // A terminal is never detached: it has no windows of its own to raise.
      if (rs != null && rs.detached && !isTermApp(r.app)) portOf(rs.sid)!.raiseDetached(rs.sid);
      if (!quiet) hint = '已切到 $appName';
      notifyListeners();
      if (r.app == 'desktop:' && !r.ending && r.phase == Phase.live) {
        await _refreshDesktop(r);
      }
    }
  }

  /// For the tray and Dock menus: when [key] is a live detached session, raises its own windows and
  /// says true; the current session stays as it is. Otherwise nothing is sent and it says false.
  bool raiseIfDetached(String key) {
    final e = _entries.where((e) => e.key == key).firstOrNull;
    final sid = e?.sid;
    if (e == null || sid == null || isTermApp(e.app) || e.lamp == Lamp.disconnected) return false;
    final rs = remote[sid];
    if (rs == null || !rs.detached) return false;
    portOf(sid)!.raiseDetached(sid);
    return true;
  }

  /// 「切到窗口」: raises the session's own windows (a detached embedded session's, or S1's client).
  void focusCurrent() {
    if (embeds) {
      // The runner's own windows: raised with or without the hub.
      final rs = currentRemote;
      if (rs != null && rs.detached && !currentDisconnected) portOf(rs.sid)!.raiseDetached(rs.sid);
      return;
    }
    final c = current;
    if (c?.sid == null) return;
    if (!hubUsable) return;
    hub!.focus(c!.sid!);
  }

  void endCurrent() {
    if (currentKey != null) endSession(currentKey!);
  }

  /// Ends the session [key]; false when there is nothing it can end (no session, or an S1 one
  /// still opening). [quiet]: no 「正在结束」/「已结束」 hint.
  bool endSession(String key, {bool quiet = false}) {
    if (embeds) return _endEmbedded(key, quiet: quiet);
    if (!hubUsable) return false;
    final c = entryFor(key);
    if (c?.sid == null) return false;
    if (remote.containsKey(c!.sid)) {
      portOf(c.sid!)!.close(c.sid!);
    } else {
      hub!.close(c.sid!);
    }
    if (!quiet) hint = '正在结束 ${c.appName}';
    notifyListeners();
    return true;
  }

  bool _endEmbedded(String key, {bool quiet = false}) {
    final r = _records[key];
    if (r == null || r.ending) return false;
    if (r.app == 'desktop:') _endDesktopChildren(r.id);
    quiet = quiet || isDesktopScreen(r.app);
    final String said;
    switch (r.phase) {
      case Phase.live:
        // The runner closes the session and answers with `ClosedEvent`; a start still in flight
        // that then fails ends the record instead of disconnecting it (M-6). A move is over: the
        // new session's end takes the old one with it (`_endRecord`), nothing goes back.
        _rerouteEnd(r, false);
        r.ending = true;
        portOf(r.sid!)!.close(r.sid!);
        said = '正在结束 ${r.appName}';
      case Phase.disconnected:
        // Nothing is running on the link; its last picture goes with the record.
        final sid = r.sid;
        if (sid != null) portOf(sid)!.close(sid);
        _endRecord(r);
        said = '已结束 ${r.appName}';
      case Phase.connecting:
        // Connecting (first open or reconnect): the record and any old picture go now; the new
        // session is closed quietly when it opens, and a failed open is not news (R14).
        r.ending = true;
        _endRecord(r);
        said = '已结束 ${r.appName}';
    }
    if (!quiet) hint = said;
    notifyListeners();
    return true;
  }

  // ---- system password ----
  bool _canUnlock(SessionRecord r, _Start start, int epoch) =>
      !_disposed && _records[r.key] == r && r.phase == Phase.live && !r.ending &&
      r.sid == start.sid && identical(_starts[start.sid], start) &&
      _lockEpoch[start.sid] == epoch && remote[start.sid]?.screenLocked == true;

  Future<void> _autoUnlock(SessionRecord r, _Start start, int epoch) async {
    UnlockCredential? saved;
    var failed = false;
    if (unlockStore.supported) {
      try {
        saved = await unlockStore.read(r.id);
      } catch (_) {
        failed = true;
      }
    }
    if (!_canUnlock(r, start, epoch) || _unlockBusy.containsKey(r.id) || _manualLock.contains(r.id)) return;
    if (saved != null && saved.auto) {
      if (!_autoUnconfirmed.contains(r.id)) {
        _sendUnlock(r, start, epoch, saved.password, auto: true);
        return;
      }
      // The last attempt never came back unlocked (its session went away first): don't type it again.
      _autoUnconfirmed.remove(r.id);
      unawaited(_autoFailed(r.id, saved.password));
      return;
    }
    if (failed) {
      hint = '无法读取钥匙串；请手动输入系统密码';
      notifyListeners();
    }
    if (r.key == currentKey) _unlockAsks.add(r.id);
  }

  /// The session to type the password through: the current one when it is this device's, else any locked one.
  SessionRecord? _unlockTarget(String device) {
    bool usable(SessionRecord x) =>
        x.id == device && _countsForUnlock(x.app) && x.phase == Phase.live && !x.ending && _starts[x.sid] != null;
    final cur = currentRecord;
    if (cur != null && usable(cur)) return cur;
    final mine = _records.values.where(usable).toList();
    for (final x in mine) {
      if (remote[x.sid]?.screenLocked == true) return x;
    }
    // None locked: still answer with that session's lock state ("not locked" / "checking").
    return mine.isEmpty ? null : mine.first;
  }

  Future<void> unlock(String device, String password, {required bool remember, required bool auto}) async {
    if (_disposed) return;
    final r = _unlockTarget(device);
    final start = r == null ? null : _starts[r.sid];
    if (r == null || start == null) {
      hint = '请先打开这台电脑上的 app 或桌面';
    } else if (remote[r.sid]?.screenLocked != true) {
      hint = remote[r.sid]?.screenLocked == false ? 'A 没有锁屏，没有输入密码' : '正在确认远程电脑的锁屏状态';
    } else if (utf8.encode(password).length > 1024) {
      hint = '密码过长（最多 1024 字节）';
    } else {
      _autoUnconfirmed.remove(device);
      _sendUnlock(r, start, _lockEpoch[r.sid]!, password);
      try {
        if (unlockStore.supported) {
          if (remember) {
            await unlockStore.save(device, password, auto: auto);
          } else {
            await unlockStore.forget(device);
          }
        }
      } catch (_) {
        if (_disposed) return;
        hint = remember ? '密码已发送，但未能保存到钥匙串' : '密码已发送，但未能从钥匙串删除原密码';
      }
    }
    notifyListeners();
  }

  void _sendUnlock(SessionRecord r, _Start start, int epoch, String password, {bool auto = false}) {
    if (!_canUnlock(r, start, epoch)) return;
    port!.unlock(start.sid, password);
    final device = r.id;
    if (auto) _autoUnconfirmed.add(device);
    _unlockBusy.remove(device)?.cancel();
    _unlockRejected.remove(device);
    _unlockBusy[device] = Timer(const Duration(seconds: 5), () {
      _unlockBusy.remove(device);
      final rejected = _unlockRejected.remove(device);
      final live = _canUnlock(r, start, epoch);
      // Any unlocked report cancels this timer, so a pending auto attempt here did not work,
      // even when the session it went through is gone.
      if (auto && _autoUnconfirmed.remove(device)) unawaited(_autoFailed(device, password));
      if (!live || rejected) return;
      hint = '尚未确认解锁，请检查远端锁屏状态或系统密码';
      notifyListeners();
    });
  }

  /// A saved password did not work: stop trying it by itself, and ask the user once
  /// (when the device's current session is locked).
  Future<void> _autoFailed(String device, String password) async {
    try {
      await unlockStore.save(device, password, auto: false);
    } catch (_) {}
    if (_disposed) return;
    final cur = currentRecord;
    if (cur?.id == device && remote[cur!.sid]?.screenLocked == true) _unlockAsks.add(device);
  }

  void _streamChanged(SessionRecord source, StreamChoice choice) {
    if (isDesktopApp(source.app)) {
      final pinned = remote[source.sid]?.streamPinned ?? source.pinned;
      for (final r in _records.values) {
        if (r.id != source.id || !isDesktopApp(r.app)) continue;
        r.choice = choice;
        r.pinned = pinned;
        final rs = remote[r.sid];
        if (rs != null) {
          rs.choice = choice;
          rs.streamPinned = pinned;
        }
      }
    }
    _applyFps();
  }

  // ---- desktop screens ----
  String _desktopName(String device) {
    final n = _desktopDisplays[device]?.length ?? 0;
    return n > 1 ? '桌面（$n 块屏）' : '桌面';
  }

  List<RemoteDisplay> desktopScreens(String device) => List.unmodifiable(_desktopDisplays[device] ?? const []);

  /// The screens the top bar's window menu switches between: the current desktop's, when A has
  /// more than one. Each screen is its own session; the menu is where the user picks one.
  List<RemoteDisplay> get currentScreens {
    final r = currentRecord;
    if (r == null || !isDesktopApp(r.app)) return const [];
    final screens = desktopScreens(r.id);
    return screens.length > 1 ? screens : const [];
  }

  /// Which of [currentScreens] is on the stage: `desktop:` is the main screen, `desktop:<id>` that one.
  int? get currentScreenIndex {
    final r = currentRecord;
    if (r == null) return null;
    final screens = currentScreens;
    final i = isDesktopScreen(r.app)
        ? screens.indexWhere((d) => !d.main && r.app == 'desktop:${d.id}')
        : screens.indexWhere((d) => d.main);
    return i < 0 ? null : i;
  }

  void openScreen(String device, String displayId) {
    final main = _records['$device/desktop:'];
    if (main == null || main.ending || main.phase != Phase.live) return;
    final screens = desktopScreens(device);
    final i = screens.indexWhere((d) => d.id == displayId);
    if (i < 0) return;
    final d = screens[i];
    unawaited(_openEmbedded(device, d.main ? 'desktop:' : 'desktop:${d.id}',
        d.main ? '桌面' : '桌面 · 屏幕 ${i + 1}', quiet: true));
  }

  LockBanner? get lockBanner {
    final r = currentRecord;
    // Terminals never report lock state, so every session that gets here can take the password.
    if (r == null || r.phase != Phase.live || r.ending || remote[r.sid]?.screenLocked != true) return null;
    return const LockBanner(desktopLockText, '输入系统密码');
  }

  void _endDesktopChildren(String device) {
    for (final child in _records.values.where((r) => r.id == device && isDesktopScreen(r.app)).toList()) {
      _endEmbedded(child.key, quiet: true);
    }
  }

  void _syncDesktopTimer() {
    final live = _records.values.any((r) => r.app == 'desktop:' && r.phase == Phase.live && !r.ending);
    if (!live) {
      _desktopTimer?.cancel();
      _desktopTimer = null;
    } else {
      _desktopTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
        for (final r in _records.values.toList()) {
          if (r.app == 'desktop:' && r.phase == Phase.live && !r.ending) {
            unawaited(_refreshDesktop(r));
          }
        }
      });
    }
  }

  Future<void> _refreshDesktop(SessionRecord r) async {
    if (!hubUsable || r.ending || r.phase != Phase.live) return;
    final sid = r.sid;
    final request = _displayRequests.putIfAbsent(r, () => hub!.apps(r.id));
    try {
      final apps = await request;
      if (_disposed || _records[r.key] != r || r.sid != sid || r.ending || r.phase != Phase.live) return;
      final screens = [for (final app in apps.apps) if (app.app == 'desktop:') ...app.displays];
      final before = _desktopDisplays[r.id];
      final ids = screens.map((d) => d.id).toSet();
      for (final child in _records.values.where((x) => x.id == r.id && isDesktopScreen(x.app)).toList()) {
        if (!screens.any((d) => !d.main && child.app == 'desktop:${d.id}')) _endEmbedded(child.key, quiet: true);
      }
      final hinted = _hintedScreens.putIfAbsent(r.id, () => {});
      hinted.removeWhere((id) => !ids.contains(id));
      if (before != null) {
        final oldIds = before.map((d) => d.id).toSet();
        for (final d in screens) {
          if (!oldIds.contains(d.id) && hinted.add(d.id)) hint = screenAddedHint;
        }
      }
      _desktopDisplays[r.id] = screens;
      _entries = _mapEntries();
      notifyListeners();
    } catch (_) {
      // A failed probe must not look like all displays were unplugged. Retry on the next tick.
    } finally {
      if (identical(_displayRequests[r], request)) _displayRequests.remove(r);
    }
  }

  // ---- devices ----
  Future<void> probe(String id) async {
    if (!hubUsable) return;
    probes[id] = DeviceProbe(Lamp.connecting, lampWord(Lamp.connecting),
        apps: probes[id]?.apps);
    notifyListeners();
    try {
      final apps = await hub!.apps(id);
      for (final a in apps.apps) {
        _appNames['$id/${a.app}'] = a.name;
      }
      _setOnline(id, true, apps: apps);
      unawaited(hub!.terms(id).then((_) {}, onError: (_) {}));
    } catch (e) {
      _setOnline(id, false, error: '$e');
    }
    _entries = _mapEntries();
    notifyListeners();
  }

  /// Loads the saved devices from the hub, then probes each one.
  Future<void> refreshDevices() async {
    if (!hubUsable) return;
    try {
      await hub!.refreshHosts();
    } catch (e) {
      hint = disconnectWord('$e');
    }
    _entries = _mapEntries();
    notifyListeners();
    probeAll();
  }

  void probeAll() {
    for (final h in hub?.hosts ?? const <HubHost>[]) {
      if (probes[h.id]?.lamp == Lamp.connecting) continue;
      probe(h.id);
    }
  }

  void selectDevice(String? id) {
    deviceTab = id;
    notifyListeners();
  }

  Future<void> removeDevice(String id) async {
    if (!hubUsable) return;
    try {
      await hub!.removeHost(id);
      probes.remove(id);
      _seenOnline.remove(id);
      _offlineSince.remove(id);
      if (deviceTab == id) deviceTab = null;
      if (workspace.favorites.any((f) => f.device == id)) {
        workspace.favorites.removeWhere((f) => f.device == id);
        _saveWorkspace();
      }
    } catch (e) {
      hint = disconnectWord('$e');
    }
    _entries = _mapEntries();
    notifyListeners();
  }

  /// Remote devices whose last probe found them up.
  int get remoteOnline => probes.values.where((p) => p.lamp == Lamp.active).length;

  /// Devices online, 本机 included: this rApp runs on it, so it is always up.
  int get onlineDevices => 1 + remoteOnline;

  /// Every device, 本机 and the added ones: as many as the overview's device wall has columns.
  int get deviceCount => 1 + (hub?.hosts.length ?? 0);

  /// This machine has a relay set (from the service status): hosts go by bare ID and may be forced onto it.
  bool get relaySet => _relaySet;
  bool _relaySet = false;

  void setRelaySet(bool v) {
    if (v == _relaySet) return;
    _relaySet = v;
    notifyListeners();
  }

  /// The path of [id]'s link: the hub's latest word, else what the last probe said.
  String? pathOf(String id) => hub?.hostPaths[id] ?? probes[id]?.apps?.path;

  bool forcedRelay(String id) => hub?.hosts.any((h) => h.id == id && h.forcedRelay) ?? false;

  /// Forces [id] onto the relay, or back to automatic. A failure goes to the hint.
  Future<void> setRoute(String id, bool forced) async {
    if (!hubUsable) return;
    try {
      await hub!.setRoute(id, forced ? 'relay' : 'auto');
    } catch (e) {
      hint = disconnectWord('$e');
    }
    notifyListeners();
  }

  // ---- prefs ----
  void setTheme(RappTheme t) {
    prefs.theme = t;
    _save();
  }

  /// 设备在前 / 项目在前: the tab order and the overview's rows. The current grouping stays; the
  /// preference only decides the default at startup (§8).
  void setFirst(FirstLayer f) {
    prefs.first = f;
    _save();
  }

  void setStartFullscreen(bool v) {
    prefs.startFullscreen = v;
    _save();
  }

  /// 「网络差时自动省流量」: saved, and every live session told at once.
  void setAutoSaveTraffic(bool v) {
    prefs.autoSaveTraffic = v;
    _applyFps();
    _save();
  }

  /// The side panel's 全局设置 folded or open: saved.
  void setSettingsFolded(bool v) {
    prefs.settingsFolded = v;
    _save();
  }

  /// 「记下写作面板发出去的话」: saved.
  void setInputHistory(bool v) {
    prefs.inputHistory = v;
    _save();
    notifyListeners();
  }

  /// 「实体键盘用内置输入法」 (iOS): saved; the built-in input method follows (`RimeGlue` listens here).
  void setRimeEnabled(bool v) {
    prefs.rimeEnabled = v;
    _save();
  }

  /// 词库 (iOS): `'bundled'` or `'user'`; saved, and followed like [setRimeEnabled].
  void setRimeDictionary(String d) {
    prefs.rimeDictionary = d;
    _save();
  }

  /// The writing panel's zoom step (0 is the default), for every panel. Its own notifier: the panel follows
  /// it without rebuilding on every other change here.
  late final ValueNotifier<int> composerZoom = ValueNotifier(prefs.composerZoom.clamp(0, composerZoomMax));

  /// The writing panel's size factor (1.0 is the default and the smallest).
  double get composerScale => composerZoomScales[composerZoom.value];

  /// The 「大小」 slider: step [z]; saved.
  void setComposerZoom(int z) {
    z = z.clamp(0, composerZoomMax);
    if (z == composerZoom.value) return;
    composerZoom.value = z;
    prefs.composerZoom = z;
    for (final rs in remote.values) { if (rs.detached) _syncHidden(rs); }
    _save();
  }

  /// The edge the iOS stage's button stack stands on. Its own notifier, like [composerZoom].
  late final ValueNotifier<StageSide> stageSide = ValueNotifier(prefs.stageButtonsSide);

  void setStageSide(StageSide s) {
    if (s == stageSide.value) return;
    stageSide.value = s;
    prefs.stageButtonsSide = s;
    _save();
  }

  /// ⌘= / ⌘- / ⌘0 (Ctrl elsewhere) in the panel.
  void zoomKey(ZoomKey k) => setComposerZoom(switch (k) {
        ZoomKey.bigger => composerZoom.value + 1,
        ZoomKey.smaller => composerZoom.value - 1,
        ZoomKey.reset => 0,
      });

  /// 按键区's ⋯: the second row open or closed; saved.
  void setKeyBarMore(bool v) {
    prefs.keyBarMore = v;
    _save();
  }

  /// 打字后自动收起: the pref, or on everywhere but iOS when unset.
  bool get quickAutoHide => prefs.quickAutoHide ?? defaultTargetPlatform != TargetPlatform.iOS;

  void setQuickAutoHide(bool v) {
    prefs.quickAutoHide = v;
    _save();
    notifyListeners();
  }

  /// 快捷区 folded or shown for the terminal kind ([term]) or for other apps; saved.
  void setQuickHidden({required bool term, required bool hidden}) {
    if (term) {
      prefs.quickHiddenTerm = hidden;
    } else {
      prefs.quickHiddenApp = hidden;
    }
    _save();
    notifyListeners();
  }

  /// 显示常用语条: the 常用语 strip over the key bar on or off; saved.
  void setPhraseStrip(bool v) {
    prefs.phraseStrip = v;
    _save();
  }

  /// 常用语 replaced (edited, reordered, deleted, 恢复默认); saved.
  void setPhrases(List<Phrase> v) {
    prefs.phrases = List.of(v);
    _save();
  }

  /// 加到常用语: [text] at the end unless a phrase already has it. False when it was there (or blank).
  bool addPhrase(String text) {
    if (text.trim().isEmpty || prefs.phrases.any((p) => p.text == text)) return false;
    setPhrases([...prefs.phrases, Phrase(text)]);
    return true;
  }

  /// 「跟着我的窗口」: the host's terminal window follows this console on or off; saved.
  void setTermFit(bool v) {
    prefs.termFit = v;
    _save();
  }

  /// 「长语音先让 AI 整理」 on or off; saved.
  void setVoiceAiTidy(bool v) {
    prefs.voiceAiTidy = v;
    _save();
  }

  /// 恢复默认: forgets every per-app 整理用途 the user chose.
  void resetVoiceTidyModes() {
    if (prefs.voiceTidyMode.isEmpty) return;
    prefs.voiceTidyMode.clear();
    _save();
    notifyListeners();
  }

  /// 「AI 整理时先思考」 on or off; saved. The next tidy reads it.
  void setVoiceAiThink(bool v) {
    prefs.voiceAiThink = v;
    _save();
  }

  /// 「打开方式」 of [device]'s 终端 entry (`text` or `pixels`); saved.
  void setTermOpen(String device, String mode) {
    prefs.termOpen[device] = mode;
    _save();
  }

  /// The 终端 app a new text terminal on [device] opens in; saved.
  void setTermApp(String device, String app) {
    prefs.termApp[device] = app;
    _save();
  }

  final _voiceKeys = StreamController<(Object, VoiceKeyPhase)>.broadcast();
  final _voiceEnds = StreamController<Object>.broadcast();

  /// The hotkey's phases on app pictures (macOS), for the stage's voice button to follow.
  Stream<(Object, VoiceKeyPhase)> get voiceKeys => _voiceKeys.stream;

  /// The sid whose 按住说话 button is held with the mouse, if any: its terminal stage swallows every key meanwhile,
  /// since the hold (not the pane) takes Esc, Tab and the letters (R19).
  Object? voiceMouseHold;

  void voiceKey(Object sid, VoiceKeyPhase p) => _voiceKeys.add((sid, p));

  /// Voice input on terminal stages ended (the term gate listens); app pictures tell native instead.
  Stream<Object> get voiceEnds => _voiceEnds.stream;

  void voiceEnd(Object sid) {
    if (termPort?.owns(sid) == true) {
      _voiceEnds.add(sid);
    } else {
      portOf(sid)?.voiceEnd(sid);
    }
  }

  void setVoiceHotkey(VoiceHotkey h) {
    prefs.voiceHotkey = h;
    port?.setVoiceHotkey(h);
    _save(); // notifies
  }

  void voiceLanguageHintDone() {
    prefs.voiceLanguageHintShown = true;
    _save();
  }

  /// The LLM gateway (全局设置 → LLM 接入点), `local/llm.json`; reread by [relocate].
  LlmEndpoint llm;
  final LlmApi llmApi;

  /// Saves a changed endpoint; an unchanged one writes nothing.
  void setLlm(LlmEndpoint e) {
    if (_disposed || e == llm) return;
    llm = e;
    _forgetHotwords();
    try {
      e.save(data.localDir);
    } catch (x) {
      hint = 'LLM 接入点没有保存：${_fsReason(x)}';
    }
    notifyListeners();
  }

  // The gateway's hotwords (GET /v1/hotwords) for the speech recogniser: asked for at start, on a new endpoint,
  // and at a recording once 10 minutes old. Never waited for: a recording takes the list as it is.
  static const _hotwordsAge = Duration(minutes: 10);
  List<String> _hotwords = const [];
  DateTime? _hotwordsAt;
  LlmEndpoint? _hotwordsAsking;

  /// The words the next recording should expect; asks the gateway again in the background when the list is old.
  List<String> voiceHotwords() {
    _refreshHotwords();
    _refreshRules();
    return _hotwords;
  }

  Future<void> _learnItems(List<LearnItem> items) async {
    final e = llm;
    final learned = <LearnItem>[];
    for (final item in items) {
      if (await llmApi.learn(e, item)) {
        learned.add(item);
      } else {
        _log('rapp: voice learn failed');
      }
    }
    if (learned.isEmpty || _disposed) return;
    if (e == llm) _learnRules(e, learned);
    _forgetHotwords();
  }

  /// What the gateway was taught; null when it cannot be asked.
  Future<List<LearnedEntry>?> voiceLearned() => llmApi.learned(llm);

  /// Takes one taught correction back; the hotwords are asked again after. True only when the gateway did.
  Future<bool> forgetLearned(String id) async {
    final ok = await llmApi.forget(llm, id);
    if (ok && !_disposed) _forgetHotwords();
    return ok;
  }

  void _forgetHotwords() {
    _hotwords = const [];
    _hotwordsAt = null;
    _refreshHotwords();
    _forgetRules();
  }

  // On-device voice fixing (spec D4, D7, D10, D18): the gateway's rules (GET /v1/vocabulary/rules), kept in
  // `local/voice-rules.json` and asked for at the hotwords' times. Only a 200 changes them; a 304 moves fetchedAt;
  // a failure keeps the copy. A copy of another endpoint is not used: no rules until this one answers.
  VoiceRules _voiceRules = VoiceRules.empty;
  List<FixRule>? _voiceRulesFrom; // what [_voiceRules] was compiled from
  VoiceRulesCopy? _rulesCopy;
  DateTime? _rulesAt;
  bool _rulesAsking = false, _rulesLoading = false;
  String? _rulesLoadDir;
  // Bumped when the rules asked for may be out of date (a new endpoint, a lesson, a forget): an answer to an
  // older ask is dropped and asked again.
  int _rulesGen = 0;

  /// The rules on-device fixing applies now; empty with no endpoint, or none from it yet.
  VoiceRules get voiceRules => _voiceRules;

  /// [text] through [voiceRules]; a password field (or a session that is gone) gets it back unchanged (D7).
  FixResult voiceFix(Object sid, String text) =>
      (remote[sid]?.secureFocus ?? true) ? FixResult(text, const []) : _voiceRules.fix(text);

  // What a sent edit teaches, offered in the session's tidy. Not from a password field; and a fix of the formal
  // vocabulary put back in [heard] is not offered to keep: that is changed in note.md (spec D9).
  void _offerEditLearns(Object sid, String heard, List<LearnItem> items) {
    if (remote[sid]?.secureFocus ?? true) return;
    final keep = [
      for (final i in items)
        if (i.action != LearnAction.preserve || !voiceRules.fromVocabulary(heard, i.observed)) i,
    ];
    if (keep.isNotEmpty) tidyOf(sid).offerLearn(keep);
  }

  /// One line for the log (counts and milliseconds only, never words: D20).
  void voiceLog(String line) => _log(line);

  // Reads the copy of the current data dir, then asks the gateway (with the copy's etag when it is this one's).
  void _loadRules() {
    final dir = data.localDir;
    _rulesLoadDir = dir;
    _rulesLoading = true;
    _rulesCopy = null;
    _rulesGen++;
    _useRules();
    VoiceRulesCopy.load(dir).then((c) {
      if (_disposed || _rulesLoadDir != dir) return;
      _rulesLoading = false;
      _rulesCopy ??= c; // a lesson learned meanwhile made one already
      _useRules();
      _refreshRules();
    });
  }

  void _useRules() {
    final c = _rulesCopy;
    final from = c != null && llm.configured && c.isFor(llm) ? c.rules : null;
    if (identical(from, _voiceRulesFrom)) return;
    _voiceRulesFrom = from;
    _voiceRules = from == null ? VoiceRules.empty : VoiceRules.compile(from);
  }

  void _keepRules(VoiceRulesCopy c) {
    _rulesCopy = c;
    _useRules();
    c.save(data.localDir).catchError((Object x) => _log('rapp: voice rules not saved: ${_fsReason(x)}'));
  }

  void _forgetRules() {
    _rulesAt = null;
    _rulesGen++;
    _useRules();
    _refreshRules();
  }

  void _refreshRules() {
    final e = llm;
    if (_disposed || !e.configured || _rulesAsking || _rulesLoading) return;
    final at = _rulesAt;
    if (at != null && _now().difference(at) < _hotwordsAge) return;
    unawaited(_askRules(e));
  }

  Future<void> _askRules(LlmEndpoint e) async {
    _rulesAsking = true;
    final gen = _rulesGen;
    final c = _rulesCopy;
    final mine = c != null && c.isFor(e) ? c : null;
    RulesReply? r;
    try {
      r = await llmApi.rules(e, etag: mine == null || mine.etag.isEmpty ? null : mine.etag);
    } catch (_) {
      r = null; // a fake's throw: rules never throws
    } finally {
      _rulesAsking = false;
    }
    if (_disposed) return;
    if (gen != _rulesGen) return _refreshRules();
    if (r == null) return; // asked again at the next recording
    final now = _now();
    if (r.unchanged) {
      if (mine == null) return;
      _rulesAt = now;
      _keepRules(VoiceRulesCopy(endpoint: mine.endpoint, fetchedAt: now, etag: mine.etag, rules: mine.rules));
      return;
    }
    _rulesAt = now;
    _keepRules(VoiceRulesCopy(endpoint: e.base!, fetchedAt: now, etag: r.etag, rules: r.rules));
    _log('rapp: voice rules ${r.rules.length}');
  }

  // What was just taught applies at once (D10): each lesson goes into the copy over the rule of the same observed,
  // as learned. The copy is then no longer the gateway's list, so its etag goes; the gateway is asked after.
  void _learnRules(LlmEndpoint e, List<LearnItem> items) {
    final c = _rulesCopy;
    final base = c != null && c.isFor(e) ? c : null;
    final keys = {for (final i in items) fixRuleKey(i.observed)};
    _keepRules(VoiceRulesCopy(
      endpoint: base?.endpoint ?? e.base!,
      fetchedAt: base?.fetchedAt ?? _now(),
      etag: '',
      rules: [
        for (final r in base?.rules ?? const <FixRule>[])
          if (!keys.contains(fixRuleKey(r.observed))) r,
        for (final i in items)
          i.action == LearnAction.replace
              ? FixRule.replace(i.observed, i.output!, FixSource.learned)
              : FixRule.preserve(i.observed, FixSource.learned),
      ],
    ));
  }

  void _refreshHotwords() {
    final e = llm;
    if (_disposed || !e.configured || _hotwordsAsking == e) return;
    final at = _hotwordsAt;
    if (at != null && _now().difference(at) < _hotwordsAge) return;
    _hotwordsAsking = e;
    llmApi.hotwords(e).then((w) {
      if (_hotwordsAsking == e) _hotwordsAsking = null;
      if (_disposed || e != llm) return;
      _hotwords = w;
      // An empty answer (a failure, an old gateway) is asked again at the next recording.
      _hotwordsAt = w.isEmpty ? null : _now();
    });
  }

  /// [prefs] changed outside a setter here (iOS 本机's 屏幕常亮): save them.
  void savePrefs() => _save();

  void _save() {
    try {
      final dir = data.prefsDir();
      if (dir != null) prefs.save(dir); // no device id yet: keep defaults, write nothing (R22)
    } catch (e) {
      hint = '偏好没有保存：${_fsReason(e)}';
    }
    notifyListeners();
  }

  String _fsReason(Object e) => e is FileSystemException ? (e.osError?.message ?? e.message) : "$e";

  // ---- favourites ----
  List<AppRef> get favorites => workspace.favorites;

  bool isFavorite(String device, String bundle) => workspace.favorites.any((f) => f.key == '$device/$bundle');

  /// Adds the app to the end of the favourites, or removes it. [name] is kept as shown now.
  void toggleFavorite(String device, String bundle, String name) {
    if (isDesktopScreen(bundle)) return;
    final key = '$device/$bundle';
    final i = workspace.favorites.indexWhere((f) => f.key == key);
    if (i >= 0) {
      workspace.favorites.removeAt(i);
    } else {
      workspace.favorites.add(AppRef(device, bundle, oneLine(name)));
    }
    _saveWorkspace();
  }

  /// Favourites with no session (pending or open), in favourite order.
  List<AppRef> get idleFavorites {
    final open = {for (final e in _entries) e.key};
    return [
      for (final f in workspace.favorites)
        if (!open.contains(f.key)) f,
    ];
  }

  // ---- projects ----
  List<Project> get projects => workspace.projects;

  Project? _project(String id) {
    for (final p in workspace.projects) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Adds an empty project at the end; null (and nothing changes) when the name is empty.
  Project? createProject(String name) {
    final n = oneLine(name);
    if (n.isEmpty) return null;
    final p = Project(newProjectId(), n);
    workspace.projects.add(p);
    _saveWorkspace();
    return p;
  }

  /// An empty name keeps the old one.
  void renameProject(String id, String name) {
    final p = _project(id);
    final n = oneLine(name);
    if (p == null || n.isEmpty) return;
    p.name = n;
    _saveWorkspace();
  }

  /// The app an open session is, as a project member.
  static AppRef appRefOf(SessionEntry e) => AppRef(e.id, e.app, oneLine(e.appName));

  /// Whether there is anything open to save as a project.
  bool get canSaveOpenAsProject => _entries.isNotEmpty;

  /// Every open session becomes a member (list order, no notes), and it becomes the current
  /// project. Null, with nothing changed, for an empty name or when nothing is open.
  /// The stage stays on the current session.
  Project? saveOpenAsProject(String name) {
    final n = oneLine(name);
    if (_entries.isEmpty || n.isEmpty) return null;
    final p = Project(newProjectId(), n, [for (final e in _entries) Member(appRefOf(e))]);
    workspace.projects.add(p);
    _saveWorkspace();
    final k = currentKey;
    if (k != null && p.members.any((m) => m.key == k)) positions.of(p.id).last = k;
    switchProject(p.id);
    return p;
  }

  void togglePinned(String projectId) {
    final p = _project(projectId);
    if (p == null) return;
    p.pinned = !p.pinned;
    _saveWorkspace();
  }

  static const undoFor = Duration(seconds: 5);
  Timer? _undoTimer;
  ({Project project, int index, ProjectPosition? position})? _undo;

  /// The deleted project's name while it can still be undone; null otherwise.
  String? get undoableDelete => _undo?.project.name;

  /// Ends no session. The project can be brought back for [undoFor].
  void deleteProject(String id) {
    final i = workspace.projects.indexWhere((p) => p.id == id);
    if (i >= 0) {
      _undo = (project: workspace.projects[i], index: i, position: positions.byProject[id]);
      _undoTimer?.cancel();
      _undoTimer = Timer(undoFor, () {
        _undoTimer = null;
        _undo = null;
        notifyListeners();
      });
    }
    workspace.projects.removeWhere((p) => p.id == id);
    if (currentProject == id) {
      currentProject = null;
      _setCue('');
    }
    if (previousProject == id) previousProject = null;
    // No project left: everything is 自由区, so there is nothing to narrow to.
    if (workspace.projects.isEmpty) freeZone = false;
    if (positions.byProject.remove(id) != null) _savePositions();
    _saveWorkspace();
  }

  /// Puts the last deleted project back where it was (members, notes, pin, where it was left); its
  /// current/previous status is not restored.
  void undoDelete() {
    final u = _undo;
    if (u == null) return;
    _undoTimer?.cancel();
    _undoTimer = null;
    _undo = null;
    workspace.projects.insert(math.min(u.index, workspace.projects.length), u.project);
    if (u.position != null) {
      positions.byProject[u.project.id] = u.position!;
      _savePositions();
    }
    _saveWorkspace();
  }

  /// False when the project already has this app on this device.
  bool addMember(String projectId, AppRef app) {
    final p = _project(projectId);
    if (p == null || p.members.any((m) => m.key == app.key)) return false;
    p.members.add(Member(AppRef(app.device, app.bundle, oneLine(app.name))));
    _saveWorkspace();
    return true;
  }

  void removeMember(String projectId, String key) {
    final p = _project(projectId);
    if (p == null) return;
    p.members.removeWhere((m) => m.key == key);
    _saveWorkspace();
  }

  void setTask(String projectId, String key, String task) {
    final p = _project(projectId);
    if (p == null) return;
    for (final m in p.members) {
      if (m.key == key) m.task = oneLine(task);
    }
    _saveWorkspace();
  }

  // ---- current project (§6) ----
  final DateTime Function() _now;

  /// Where each project was left (`local/project_positions.json`).
  final ProjectPositions positions;

  /// The current project's id; null when there is none (全部, or [freeZone]).
  String? currentProject;

  /// 自由区 (Free Zone): the sessions in no project, as if they were one: like a city's unplanned
  /// zone, where work grows freely before it settles into a project. Never with a [currentProject].
  bool freeZone = false;
  static const freeZoneLabel = '自由区';
  static const allLabel = '全部';
  String? previousProject;

  /// The cue on coming back to a project; empty when none shows.
  String cue = '';
  static const cueFor = Duration(seconds: 5);
  Timer? _cueTimer;

  /// A new last session inside the current project is written this long after it changes.
  static const positionsSaveDelay = Duration(seconds: 1);

  /// After [relocate]: the new root's positions, and no current or previous project the new
  /// workspace lacks (§14 case 1).
  void _reloadProjectState() {
    positions.byProject
      ..clear()
      ..addAll(ProjectPositions.load(data.localDir).byProject);
    final ids = {for (final p in workspace.projects) p.id};
    positions.dropExcept(ids);
    if (!ids.contains(currentProject)) {
      currentProject = null;
      _setCue('');
    }
    if (!ids.contains(previousProject)) previousProject = null;
  }

  /// Since when each session's lamp has been 等你 or 已断开.
  final Map<String, DateTime> _attentionSince = {};

  void _trackAttention() {
    final now = <String>{};
    for (final e in _entries) {
      if (e.lamp == Lamp.waiting || e.lamp == Lamp.disconnected) {
        now.add(e.key);
        _attentionSince.putIfAbsent(e.key, _now);
      }
    }
    _attentionSince.removeWhere((k, _) => !now.contains(k));
  }

  /// A new current session inside the current project is remembered as its last one; one outside
  /// it leaves the project. No session (it ended) keeps the project. One outside it that is still
  /// opening leaves only once the open succeeds ([_open] calls this again), so a failed open keeps
  /// the project. Embedded opens have no pending entry: their record is on stage at once and stays
  /// there when the open fails (it retries), so they leave at once.
  void _followCurrentKey() {
    final id = currentProject, k = currentKey;
    // A session in a project takes 自由区 back to 全部.
    if (freeZone && k != null && !_pending.containsKey(k) && projects.any((p) => p.members.any((m) => m.key == k))) {
      freeZone = false;
      return;
    }
    if (id == null || k == null) return;
    final p = _project(id);
    if (p != null && p.members.any((m) => m.key == k)) {
      final pos = positions.of(id);
      if (pos.last == k) return;
      pos.last = k;
      _positionsTimer?.cancel();
      _positionsTimer = Timer(positionsSaveDelay, _savePositions);
    } else if (!_pending.containsKey(k)) {
      _leave();
    }
  }

  /// The session after [gone] (current, just ended) in [oldGroups], if [stillOpen]; null when none.
  /// With a current project, only its members take part, so a session ending never leaves it.
  String? _nextAfterEnd(List<SessionGroup> oldGroups, String gone, bool Function(String key) stillOpen) {
    final p = currentProject == null ? null : _project(currentProject!);
    final keys = freeZone ? [for (final g in oldGroups) for (final e in g.entries) if (!_inAnyProject(e.key)) e.key] : (p == null ? null : projectKeys(p));
    final within = keys == null ? null : [for (final k in keys) if (k == gone || stillOpen(k)) k];
    final next = stepKey(oldGroups, gone, 1, within: within);
    return next != null && next != gone && stillOpen(next) ? next : null;
  }

  bool _inAnyProject(String key) => projects.any((p) => p.members.any((m) => m.key == key));

  /// Records where the current project was left; it becomes the previous one. No notify.
  void _leave() {
    final id = currentProject;
    if (id == null) return;
    final pos = positions.of(id);
    pos.leftAt = _now();
    final k = currentKey, p = _project(id);
    if (k != null && p != null && p.members.any((m) => m.key == k)) pos.last = k;
    previousProject = id;
    currentProject = null;
    _setCue('');
    _savePositions();
  }

  void _setCue(String c) {
    _cueTimer?.cancel();
    _cueTimer = null;
    cue = c;
    if (c.isEmpty) return;
    _cueTimer = Timer(cueFor, () {
      _cueTimer = null;
      cue = '';
      notifyListeners();
    });
  }

  Timer? _positionsTimer;

  /// Writes a position save that is still waiting for [positionsSaveDelay].
  void _flushPositions() {
    if (_positionsTimer != null) _savePositions();
  }

  /// Also stands for a waiting save.
  void _savePositions() {
    _positionsTimer?.cancel();
    _positionsTimer = null;
    try {
      positions.save(data.localDir);
    } on FileSystemException catch (e) {
      _log('rapp: 项目位置没有保存：${e.message}');
    }
  }

  /// 切到 project [id]: grouped by project, it stops on the session last used there (§6.1) and
  /// shows the cue (§6.2). Opens nothing.
  void switchProject(String id) {
    final p = _project(id);
    if (p == null) return;
    final back = currentProject != id;
    if (currentProject != null && back) _leave();
    freeZone = false;
    if (previousProject == id) previousProject = null;
    final pos = positions.of(id);
    currentProject = id;
    grouping = Grouping.project;
    currentKey = resumeKey(p, pos.last, (k) => entryFor(k) != null);
    panel = null;
    overview = false;
    logs = false;
    if (back) {
      final leftAt = pos.leftAt;
      var needs = 0, disconnected = 0;
      for (final m in p.members) {
        final since = _attentionSince[m.key];
        if (leftAt == null || since == null || !since.isAfter(leftAt)) continue;
        final l = entryFor(m.key)?.lamp;
        if (l == Lamp.waiting) needs++;
        if (l == Lamp.disconnected) disconnected++;
      }
      _setCue(returnCue(leftAt: leftAt, now: _now(), needs: needs, disconnected: disconnected) ?? '');
    }
    // A leave is recorded only when it is seen; one that is missed (a quit) then gives no cue,
    // rather than one counted from an older leave.
    pos.leftAt = null;
    if (currentKey != null) pos.last = currentKey;
    _savePositions();
    notifyListeners();
  }

  /// 上一个项目; nothing when there is none.
  void backToPreviousProject() {
    final id = previousProject;
    if (id != null) switchProject(id);
  }

  /// 全部: back to no current project, every session.
  void leaveProject() {
    if (currentProject == null && !freeZone) return;
    _leave();
    freeZone = false;
    notifyListeners();
  }

  /// 自由区: the sessions in no project, grouped by project so they sit together; it stops on the
  /// current session if it is one of them, else the first. Opens nothing.
  void switchFreeZone() {
    if (freeZone) return;
    _leave();
    freeZone = true;
    grouping = Grouping.project;
    final keys = freeZoneKeys;
    if (!keys.contains(currentKey)) currentKey = keys.firstOrNull;
    panel = null;
    overview = false;
    logs = false;
    notifyListeners();
  }

  SessionEntry? entryFor(String key) {
    for (final e in _entries) {
      if (e.key == key) return e;
    }
    return null;
  }

  /// Not in the hub's device table, or its probe says offline.
  bool deviceOffline(String id) => !(hub?.hosts.any((h) => h.id == id) ?? false) || probes[id]?.lamp == Lamp.offline;

  Lamp memberLamp(Member m) => entryFor(m.key)?.lamp ?? Lamp.notOpened;

  String memberStatus(Member m) {
    final e = entryFor(m.key);
    if (e == null) return deviceOffline(m.app.device) ? '未打开，设备离线' : lampWord(Lamp.notOpened);
    if (e.lamp == Lamp.disconnected) return '已断开：${e.reason ?? ''}';
    return lampWord(e.lamp);
  }

  /// 「全部打开」: every member that is not open (or is disconnected) opens at once, members on an
  /// offline device are skipped, and it stops on the first member not skipped (K11). One hint.
  /// On a project that is not the current one, it first switches to it.
  void openAll(String projectId) {
    final p = _project(projectId);
    if (!hubUsable || p == null) return;
    if (currentProject != projectId) switchProject(projectId);
    final plan = planOpenAll(p, lampOf: (k) => entryFor(k)?.lamp, offline: deviceOffline);
    // Before the opens: the 终端 entry's key is the session it opens, which they may change.
    final first = p.members.where((m) => m.key == plan.first).map(_openedKey).firstOrNull;
    for (final m in plan.open) {
      // Not awaited: each open has its record or pending entry before its first await, so a
      // second 「全部打开」 right after sees them connecting. The 终端 entry opens what tapping it opens.
      unawaited(m.app.bundle == termsEntry
          ? _openTerms(m.app.device, select: false, quiet: true)
          : _open(m.app.device, m.app.bundle, m.app.name, select: false, quiet: true));
    }
    hint = openAllHint(p, plan, deviceName);
    if (first != null) {
      currentKey = first;
      panel = null;
      overview = false;
      logs = false;
    }
    notifyListeners();
  }

  /// 「全部结束」: ends every member's session, including ones shared with another project; one
  /// hint with the count (K12, K13). The panel stays.
  void endAll(String projectId) {
    final p = _project(projectId);
    if (p == null) return;
    var ended = 0, shared = 0;
    for (final m in p.members) {
      final key = m.key;
      if (entryFor(key) == null) continue;
      // Ends later (the runner's `ClosedEvent`, the hub's `closed`): that end says nothing.
      final later = !embeds || _records[key]?.phase == Phase.live;
      if (!endSession(key, quiet: true)) continue;
      ended++;
      if (later) _batchEnded.add(key);
      if (projectsOf(key).length > 1) shared++;
    }
    hint = endAllHint(p.name, ended, shared);
    notifyListeners();
  }

  /// Apps of online devices (device order), then favourites not already listed; minus the project's members.
  List<AppRef> addableApps(String projectId) {
    final have = {for (final m in _project(projectId)?.members ?? const <Member>[]) m.key};
    final out = <AppRef>[];
    final seen = <String>{};
    void add(AppRef a) {
      if (!have.contains(a.key) && seen.add(a.key)) out.add(a);
    }

    for (final h in hub?.hosts ?? const []) {
      final p = probes[h.id];
      if (p?.lamp != Lamp.active) continue;
      for (final a in p!.apps?.apps ?? const <HubApp>[]) {
        add(AppRef(h.id, a.app, a.name));
      }
    }
    workspace.favorites.forEach(add);
    return out;
  }

  /// Projects that have this app, in project order.
  List<Project> projectsOf(String key) => [
        for (final p in workspace.projects)
          if (p.members.any((m) => m.key == key)) p,
      ];

  void _saveWorkspace() {
    try {
      saveWorkspace(data.sharedDir, workspace);
    } catch (e) {
      hint = '项目和常用没有保存：${_fsReason(e)}';
    }
    notifyListeners();
  }

  // ---- global resources ----

  /// Why [e] cannot be copied to this Mac now (the word on the grey button), or null if it can.
  String? copyBlockedWord(ClipEntry e) {
    if (e.copy != null) return null;
    if (e.kind == ClipKind.unsupported) return '不支持';
    final r = _records[e.key];
    final now = _startOf(r?.sid);
    if (e.ended || r == null || (r.phase == Phase.disconnected && now == e.sid)) return '远端已断开，复制不到';
    if (r.phase != Phase.live || now != e.sid) return '重连前的，复制不到';
    return null;
  }

  bool canCopy(ClipEntry e) => copyBlockedWord(e) == null;

  /// Whether 「插入」 may pick [e] into its session's composer: only an entry of the start that is
  /// live now. A pinned entry of an ended start has a copy here, but its clip number on A is gone
  /// (or, after a hub restart, names another clip of a new session with the same sid: C4).
  bool canInsert(ClipEntry e) {
    final r = _records[e.key];
    return !e.ended && e.kind != ClipKind.unsupported && r != null && r.phase == Phase.live && _startOf(r.sid) == e.sid;
  }

  bool canPin(ClipEntry e) => !e.pinning && !e.pinned && (e.copy != null || canCopy(e));

  Future<void> copyLocal(ClipEntry e) async {
    final p = port;
    if (p == null) return;
    final copy = e.copy;
    if (copy != null) {
      final ok = await p.copyLocal(copy);
      if (_disposed || ok) return;
      hint = '本机副本不在了';
      notifyListeners();
    } else if (canCopy(e)) {
      final sid = _hubSid(e.sid);
      portOf(sid)!.clipPick(sid, e.clip, false);
    }
  }

  Future<void> togglePin(ClipEntry e) async {
    final p = port;
    if (p == null) return;
    if (e.pinned) {
      final path = e.path;
      if (path != null) deletePin(path);
      e.path = null;
      final copy = resources.unpin(e.seq, sessionEnded: e.ended);
      if (copy != null) p.dropCopy(copy);
      return;
    }
    if (!canPin(e)) return;
    resources.beginPin(e.seq);
    final sid = _hubSid(e.sid);
    final r = await portOf(sid)!.fetchClip(sid, e.clip);
    if (_disposed) return;
    if (resources.entry(e.seq) == null) {
      final copy = r.copy;
      if (copy != null) p.dropCopy(copy); // the entry went while we waited
      return;
    }
    final copy = r.copy;
    if (copy != null) {
      resources.pinned(e.seq, copy);
      final path = await p.savePin(copy,
          textDir: data.clipboardDir, fileDir: data.filesClipboardDir, stem: pinStem(e.at, e.title, e.kind));
      if (_disposed) return;
      if (path != null) {
        final now = resources.entry(e.seq);
        if (now == null || !now.pinned) {
          deletePin(path); // unpinned or gone while the file was being written
        } else {
          now.path = path;
          _hintFirstPin();
        }
      }
    } else {
      resources.pinFailed(e.seq);
      hint = pinFailureHint(r.error);
      notifyListeners();
    }
  }

  void _hintFirstPin() {
    final marker = File('${data.localDir}/$pinHintMarker');
    try {
      if (marker.existsSync()) return;
      marker.createSync(recursive: true);
    } catch (_) {
      return;
    }
    hint = pinHint;
    notifyListeners();
  }

  /// The hint for a failed pin; the runner's English "unknown clip" never reaches the user.
  static String pinFailureHint(String? reason) =>
      reason == 'unknown clip' ? '这条太旧了，远端已不保留' : '固定没成功：$reason';

  void cancelTransfer(TransferRow t) {
    final sid = _hubSid(t.sid);
    if (_starts[sid] == t.sid) portOf(sid)?.cancelTransfer(sid, id: t.id); // never a new start's same id
  }

  Future<void> reveal(TransferRow t) async {
    final path = t.path;
    final p = port;
    if (p == null || path == null) return;
    final ok = await p.reveal(path);
    if (_disposed || ok) return;
    hint = '文件不在了：${t.name}';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _tidies.values) {
      t.dispose();
    }
    _tidies.clear();
    voice?.dispose();
    _voiceKeys.close();
    _voiceEnds.close();
    composerZoom.dispose();
    stageSide.dispose();
    appLatch.dispose();
    resources.removeListener(notifyListeners);
    resources.dispose();
    hub?.removeListener(_onHub);
    profiles.removeListener(_onProfiles);
    _portSub?.cancel();
    _termSub?.cancel();
    _writtenSub?.cancel();
    history.dispose();
    _blockedTimer?.cancel();
    for (final n in _notices.values) {
      n.timer.cancel();
    }
    _desktopTimer?.cancel();
    _cueTimer?.cancel();
    _undoTimer?.cancel();
    _flushPositions();
    for (final t in _unlockBusy.values) {
      t.cancel();
    }
    _unlockBusy.clear();
    _unlockRejected.clear();
    unawaited(_unlockAsks.close());
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
    for (final w in _waiting.values) {
      w.timer.cancel();
    }
    for (final r in _reroutes.keys.toList()) {
      _rerouteEnd(r, false);
    }
    for (final r in remote.values) {
      r.dispose();
    }
    super.dispose();
  }
}

/// How long a moved session's new route has to show a picture before the move counts as failed.
const rerouteTimeout = Duration(seconds: 15);

/// One move of a record onto the hub's new link ([MainState.reroute]).
class _Reroute {
  final done = Completer<bool>();
  Timer? timer;

  /// The new session, once it opened, and the path it opened on.
  Object? fresh;
  String? path;
}

class _Waiting {
  _Waiting(this.appName, this.timer);
  final String appName;
  final Timer timer;
}

/// How long the blocked-input hint stays (R14).
const blockedHintFor = Duration(seconds: 1);

/// 「远端正在被 X 操作」 (same words as the host's notice); an unnamed device is 「另一台设备」.
String inputBlockedHint(String by) => by.isEmpty ? '远端正在被另一台设备操作' : '远端正在被 $by 操作';

/// One start of a hub session in this launch; equal only to itself.
class _Start {
  _Start(this.sid);
  final Object sid;
}

/// "stdin closed" (ended from rApp) and "quit" (its window was closed) are
/// the user's own doing; any other client exit reason is unexpected.
String endedHint(String appName, String? reason) {
  const prefix = 'rapp-client: ';
  final why = reason != null && reason.startsWith(prefix) ? reason.substring(prefix.length) : reason;
  if (takenOver(why)) return '$appName：${disconnectWord(why)}';
  if (why == null || why == 'stdin closed' || why == 'quit') return '已结束 $appName';
  if (why.startsWith('host says: ') && why.endsWith(' quit')) return '$appName 已结束：远端关闭了 app';
  if (why == 'connection closed') return '$appName 意外结束：连接断了';
  if (why == 'GUI did not connect') return '$appName 意外结束：本机没有接上会话';
  return '$appName 意外结束：$why';
}

/// What a paste on a terminal stage did ([MainState.termPaste]).
class TermPasted {
  const TermPasted({this.sent = false, this.note});

  /// The clipboard text went to the terminal.
  final bool sent;

  /// Why the paste did not go in, to show on the stage.
  final String? note;
}
