# host-core: where the Swift host went

`rapp-host-core` is the platform-free half of the Windows host (spec §5.3, §6). The Swift
host under `Sources/rapp-host/` and the shared rules under `Sources/RappCore/` are the
reference: when the two disagree, Swift is right and host-core is fixed.

`tests/porting.rs` holds this file to the sources:

- `swift_digests_are_current`: every file in part 3 still has its digest, and no file was
  added to or removed from the two directories. A failure names the file. Then check
  host-core against the change, and update the row and the digest here.
- `every_row_names_a_real_test`: every `file::test_name` in part 1 is a real `fn` in
  `rust/host-core/tests/` or `rust/testkit/tests/`.
- `every_swift_host_line_is_mapped`: the ranges in part 1 cover every line of every file in
  `Sources/rapp-host/`.

A row with no test is allowed only when its third column says "platform:" (phase D tests it
on the real platform) or "not on Windows".

## 1. `Sources/rapp-host/` mapping

| Swift | What it does | host-core | Test |
|---|---|---|---|
| `Sources/rapp-host/AppStateWatcher.swift:1-17` | Reads the target app's version for state-rule packs. | `session::hints` `start_app_state` (version from platform: `TargetOps::version`) | `state_rules::rule_pack`, `host_session::state_rules_report` |
| `Sources/rapp-host/AppStateWatcher.swift:18-52` | The watcher: one engine per session, its thread and limits. | `session::hints` `AppState::new`, `run` | `host_session::state_rules_report` |
| `Sources/rapp-host/AppStateWatcher.swift:53-88` | `setRules`: decodes a pack, refuses one too large or for another app, with Swift's texts. | `session::hints` `Session::state_rules`, `AppState::set_rules` | `host_session::oversized_rules_are_rejected_with_swift_text`, `state_rules::rule_pack` |
| `Sources/rapp-host/AppStateWatcher.swift:89-107` | `setWindow` and `seed`: which window the rules sample, and the first report. | `session::hints` `AppState::set_window` | `host_session::state_rules_report` |
| `Sources/rapp-host/AppStateWatcher.swift:108-125` | `offer` and `stop`: frames handed to the engine, at most one waiting. | `session::hints` `AppState::stop`, `round` | `host_session::state_rules_report` |
| `Sources/rapp-host/AppStateWatcher.swift:126-176` | `tick` and `sample`: runs the detectors on a frame and sends a changed report. | `state::engine`, `session::hints` `AppState::engine`, `sample` | `state_rules::state_engine`, `state_rules::reports_fit_the_wire_limit` |
| `Sources/rapp-host/ClipboardWatcher.swift:1-22` | `fitted`: the clipboard text cut to the wire limit on a character boundary. | `clipboard` | `rules_clip::clip_text_never_splits_a_scalar` |
| `Sources/rapp-host/ClipboardWatcher.swift:23-63` | Starts and stops polling the host clipboard. | `session::clip` `start_clipboard`, `stop_clipboard`, watcher `run` | `host_session::host_copy_is_announced` |
| `Sources/rapp-host/ClipboardWatcher.swift:64-83` | `tick`, `read`, `noteOwnWrite`: a new change count is read once; the host's own writes are not echoed. | `session::clip` watcher `tick`, paster `note_own_write` (platform: `ClipboardOps::change_count`, `read`) | `host_session::host_copy_is_announced`, `host_session::paste_does_not_restore_over_a_newer_copy`, `host_session::paste_when_the_target_stays_behind_fails_with_the_fixed_text` |
| `Sources/rapp-host/ClipboardWatcher.swift:84-143` | `capture`, `captureFiles`, `captureImage`: text, files and images into the transfer store. | `session::clip` `capture`, `capture_files`, `png_size`; `transfers` | `host_session::host_copy_is_announced`, `transfers::clip_store_matches_swift` |
| `Sources/rapp-host/CoverCloser.swift:1-58` | Closes the window of another app that covers B's press. | platform: `ControlOps::close_cover`; `session::hints` `dismiss_cover` | `host_session::cover_is_announced_every_5s_and_dismissed` |
| `Sources/rapp-host/FocusReader.swift:1-63` | The focus reader: one query at a time on its own thread. | `session::hints` `focus_ask`, `run_focus_job` | `host_session::focus_region_after_click` |
| `Sources/rapp-host/FocusReader.swift:64-104` | `query`, `stop`, `run`: a query with a deadline; a slow one is abandoned. | `session::hints` `run_focus_job`; `query` | `host_session::slow_focus_query_is_abandoned`, `rules_focus::query_rules_match_swift` |
| `Sources/rapp-host/FocusReader.swift:105-190` | `read` and `attributes`: the accessibility chain from the focused element up. | platform: `ControlOps::focus_chain` | phase D |
| `Sources/rapp-host/FocusReader.swift:191-216` | `installObserver`: keyboard focus moves. | platform: `ControlOps::keyboard_changed` | phase D |
| `Sources/rapp-host/FocusSession.swift:1-49` | The focus session: tracker, pane rules and state for one session. | `session::hints` `FocusSession::new`; `focus::tracker`, `focus::pane` | `rules_focus::focus_tracker_matches_swift`, `rules_focus::focus_pane_matches_swift` |
| `Sources/rapp-host/FocusSession.swift:50-94` | `start`, `input`, `windows`, `locked`: what the tracker hears. | `session::hints` `sync_focus`, `windows_changed`, `focus_windows`, `focus_input`, `focus_locked` | `host_session::focus_region_after_click` |
| `Sources/rapp-host/FocusSession.swift:95-160` | `stop`, `dispatch`, `ask`, `answered`, `emit`: queries out, `focusRegion` back. | `session::hints` `focus_tick`, `focus_dispatch`, `focus_answered`, `focus_emit`, `encoded` | `host_session::focus_region_after_click`, `host_session::slow_focus_query_is_abandoned` |
| `Sources/rapp-host/InputInjector.swift:1-39` | The injector: held keys and buttons, the session's display. | `session::input` `input_ready`; `input::HeldInput` | `rules_input::held_input_matches_swift` |
| `Sources/rapp-host/InputInjector.swift:40-87` | `handle`: text in 20-unit chunks, keys, scroll, each mapped to A's display. | `session::input` `inject` (platform: `InputOps::text`, `key`, `scroll`) | `host_session::typed_text_arrives_in_20_unit_chunks` |
| `Sources/rapp-host/InputInjector.swift:88-127` | `mouse`: presses with click counts; drops a press another app covers. | `session::input` `mouse` (platform: `InputOps::mouse`, `ControlOps::cover_at`) | `host_session::click_count_reaches_the_platform`, `host_session::cover_is_announced_every_5s_and_dismissed` |
| `Sources/rapp-host/InputInjector.swift:128-144` | `releaseAll`: every held key and button let go at session end. | `session::input` `release_all_input` (platform: `InputOps::release`) | `host_session::keys_and_buttons_released_at_session_end` |
| `Sources/rapp-host/InputInjector.swift:145-183` | `clearToPointerInput`: a press on an elevated window is refused and B is told. | `session::input` `clear_to_pointer_input`, `elevated_at`, `input_blocked_by` (platform: `InputOps::blocked_by`) | `host_session::elevated_window_reports_input_blocked` |
| `Sources/rapp-host/InputInjector.swift:184-213` | `topOwner`, `displayBounds`: which app owns the point; the point kept on the display. | `session::input` `top_owner`, `point_on_display`; `hit_test` | `rules_windows::hit_test_matches_swift` |
| `Sources/rapp-host/InputInjector.swift:214-219` | `activateIfNeeded`: the target comes to the front before input. | `session::input` `activate_if_needed` (platform: `TargetOps::activate`) | `host_session::click_count_reaches_the_platform` |
| `Sources/rapp-host/InputInjector.swift:220-233` | `post` and `globalPoint`: the system event, in global points. | platform: `InputOps::mouse`, `key`, `scroll` | phase D |
| `Sources/rapp-host/InputSourceWatcher.swift:1-16` | The input-source state B is told about (v8). | `platform::InputSource`; `session::session` `sent_input_source` | `host_session::input_source_is_reported_and_selected` |
| `Sources/rapp-host/InputSourceWatcher.swift:17-68` | `InputSources.current` and `select`: the system's keyboard sources. | platform: `InputSourceOps::current`, `list`, `select`, `select_english` | phase D |
| `Sources/rapp-host/InputSourceWatcher.swift:69-103` | The watcher: a changed source is sent to B. | `session::session` `start_input_source`, `send_input_source` | `host_session::input_source_is_reported_and_selected` |
| `Sources/rapp-host/main.swift:1-25` | Usage text and argument parsing. | `cli` `parse_host_arguments`; `run` `USAGE_TEXT` | `cli::host_arguments_match_swift` |
| `Sources/rapp-host/main.swift:26-33` | Permissions: screen capture and accessibility. | platform: `Platform::permissions`; `cli` `check_json` | `cli::check_json_carries_platform_fields` |
| `Sources/rapp-host/main.swift:34-59` | The app listing: apps with windows, desktop entries first. | `cli` `shareable_apps`, `apps_json`, `apps_text` | `cli::apps_json_starts_with_the_desktop_main_display_first`, `cli::apps_json_without_displays_has_no_desktop_entry` |
| `Sources/rapp-host/main.swift:60-64` | `version`. | `run::run`; `cli` `version_json` | `cli::version_reports_crate_version_and_platform` |
| `Sources/rapp-host/main.swift:65-76` | `list-apps`. | `run::run` (platform: `Platform::applications`) | `host_session::list_apps_check_version_lock_json` |
| `Sources/rapp-host/main.swift:77-84` | `check`, `--prompt` accepted and ignored. | `run::run` | `cli::check_prompt_is_accepted_and_ignored` |
| `Sources/rapp-host/main.swift:85-98` | `lock`: locks A, reports ok, already or failed. | `run::run`; `cli` `lock_json` (platform: `LockOps::lock`) | `host_session::lock_command_reports_ok_already_failed`, `cli::lock_json_lines` |
| `Sources/rapp-host/main.swift:99-136` | `serve` and its stdin commands (`quit`, `kick`, `peer`, `yield`), exit on EOF. | `run::run`; `cli` `parse_worker_command`; `session::server` `Server` | `host_session::quit_exits_0`, `host_session::stdin_eof_exits_0`, `cli::worker_commands_match_swift` |
| `Sources/rapp-host/MenuBarReader.swift:1-78` | Reads the app's menu bar for `menuBar` (17). | not on Windows: no menu mirror, `menuPick` ignored (spec §6.3, §6.8, §2.2) | `host_session::menu_pick_is_ignored` |
| `Sources/rapp-host/Paster.swift:1-45` | The paster: one paste at a time, a queue behind it. | `session::clip` `paste`, paster `run` | `rules_clip::paste_session_matches_swift` |
| `Sources/rapp-host/Paster.swift:46-75` | `paste` and `end`: text inline, an item from the store, a missing item refused. | `session::clip` `paste`, `paste_reply` | `host_session::paste_text_inline`, `host_session::paste_item_not_uploaded` |
| `Sources/rapp-host/Paster.swift:76-109` | `next` and `finish`: the next queued paste, `pasted` back to B. | `session::clip` `paste_next`, `paste_finished`, paster `finish` | `host_session::put_then_paste_a_file` |
| `Sources/rapp-host/Paster.swift:110-137` | `noteOwnWrite` and `write`: the item on the clipboard. | `session::clip` paster `note_own_write`, `write` (platform: `ClipboardOps::write`) | `host_session::paste_text_inline` |
| `Sources/rapp-host/Paster.swift:138-164` | `waitFrontmost` and `sendPaste`: the target in front, then the paste key; locked A fails with the fixed text. | `session::clip` paster `wait_frontmost` (platform: `InputOps::paste_key`) | `host_session::paste_when_locked_fails_with_the_fixed_text`, `host_session::paste_when_the_target_stays_behind_fails_with_the_fixed_text` |
| `Sources/rapp-host/Paster.swift:165-200` | `takeSnapshot` and `restoreOnMain`: the old clipboard back, unless something newer was copied. | `session::clip` `paste_restore_check`, paster `restore`, `read` (platform: `ClipboardOps::snapshot`, `restore`) | `host_session::paste_does_not_restore_over_a_newer_copy` |
| `Sources/rapp-host/PowerHold.swift:1-45` | Keeps A awake while a session is open. | `session::session` `stay_awake` (a `lock::StayAwake` on a lock handle of its own; the two log lines); platform: `LockOps::stay_awake` | `rules_lock::lock_rules_match_swift`, `host_session::stay_awake_spans_the_session`, `host_session::a_refused_hello_never_holds_a_awake` |
| `Sources/rapp-host/ScreenLocker.swift:1-22` | Locks the screen for `lock`. | platform: `LockOps::lock`; `lock` `lock_screen` | `host_session::lock_command_reports_ok_already_failed`, `rules_lock::lock_rules_match_swift` |
| `Sources/rapp-host/SecureFocusWatcher.swift:1-65` | Watches for keyboard focus in a password field; tells B on a change. | `session::hints` `check_secure_focus` | `host_session::secure_focus_follows_the_platform` |
| `Sources/rapp-host/SecureFocusWatcher.swift:66-110` | `readSecure` and `installObserver`: the focused element's role. | platform: `ControlOps::secure_focus` | phase D |
| `Sources/rapp-host/Server.swift:1-14` | `describe`: one message as a log line, never its text. | `session::session` `kind_name`, `client_description` | `host_session::listening_then_ready` |
| `Sources/rapp-host/Server.swift:15-88` | The server: listen, `kick`, `stop`, `peer`. | `session::server` `Server::start`, `kick`, `stop`, `peer` | `host_session::listening_then_ready`, `host_session::kick_ends_the_session` |
| `Sources/rapp-host/Server.swift:89-115` | `yieldTo`, `accept`, `reject`. | `session::server` `Server::yield_to`, `accept_loop`, `Inner::reject` | `host_session::yield_blocks_input_for_1s`, `host_session::wrong_token_is_rejected` |
| `Sources/rapp-host/Server.swift:116-166` | `route`: a hello takes over only if it would be accepted; `fetch`/`put` become side connections. | `session::server` `Inner::route` | `host_session::second_hello_takes_over`, `host_session::fifth_side_connection_is_refused` |
| `Sources/rapp-host/Server.swift:167-236` | `Intake`: the first message within 5 s, or the connection is dropped. | `session::intake` `first_message`, `read_timeout`, `bad_data_reason` | `host_session::silent_client_is_dropped_after_5s`, `host_session::wrong_app_is_rejected` |
| `Sources/rapp-host/Server.swift:237-360` | The session's fields and `init`. | `session::session` `Session::spawn` | `host_session::listening_then_ready` |
| `Sources/rapp-host/Server.swift:361-392` | `start` and `drain`: the reader and the writer. | `session::session` `run`, `spawn_reader`, `flush_send_error` | `host_session::disconnect_mid_frame_cleans_up` |
| `Sources/rapp-host/Server.swift:393-411` | `receive`: bad data ends the session, not the worker. | `session::session` `spawn_reader` | `host_session::garbage_ends_the_session_not_the_worker` |
| `Sources/rapp-host/Server.swift:412-442` | `handle`: the yield gate, then `hello` checks token, app and version. | `session::session` `handle`, `gated`, `hello` | `host_session::version_mismatch_is_rejected`, `host_session::yield_blocks_then_releases` |
| `Sources/rapp-host/Server.swift:443-469` | Input, `setStream`, `ping`, `resize` dispatch. | `session::session` `handle` | `host_session::set_stream_changes_mode`, `host_session::menu_pick_is_ignored` |
| `Sources/rapp-host/Server.swift:470-487` | `focus`, `close`, `move`. | `session::input` `focus_window`, `close_window`, `move_window`; `geometry` (platform: `WindowOps::raise`, `close`, `move_to`) | `host_session::window_commands_reach_the_platform`, `host_session::desktop_session_shows_the_main_display` |
| `Sources/rapp-host/Server.swift:488-505` | `menuPick`. | `session::session` `handle` (passes the yield gate, `gated`; then always the "no longer has" branch, `:490-494`: no menus on Windows, spec §6.3) | `host_session::menu_pick_is_ignored` |
| `Sources/rapp-host/Server.swift:506-524` | `paste`, `selectInput`, `frameAck`. | `session::clip` `paste`; `session::input` `select_input`; `session::session` `handle` | `host_session::paste_text_inline`, `host_session::input_source_is_reported_and_selected`, `host_session::unacknowledged_controller_gets_bounded_frames` |
| `Sources/rapp-host/Server.swift:525-543` | `unlock`, `dismissCover`, `setView`, `stateRules`; the types the host never handles. | `session::session` `handle` | `protocol::not_handled_is_exactly_17_18_28`, `host_session::set_view_narrows_the_picture` |
| `Sources/rapp-host/Server.swift:544-579` | `dismissCover` and `covered`: the cover named every 5 s, closed on request. | `session::hints` `dismiss_cover`, `covered` | `host_session::cover_is_announced_every_5s_and_dismissed` |
| `Sources/rapp-host/Server.swift:580-613` | `activated` and `startHints`: an app opened by input is announced. | `session::hints` `start_hints`, `hints_tick`, `check_opened_app` (platform: `WindowOps::opened_app`) | `host_session::app_opened_after_input_only` |
| `Sources/rapp-host/Server.swift:614-660` | `admit`, `yielded`, `startInputTimer`, `decoratedWindow`. | `session::session` `admit`, `yielded`; `session::input` `decorated_window` | `host_session::yield_blocks_then_releases` |
| `Sources/rapp-host/Server.swift:661-675` | `appDisplayName`: the name in `ready`. | `session::session` `app_display_name` | `host_session::listening_then_ready` |
| `Sources/rapp-host/Server.swift:676-698` | `waitForUnlock`: an app session started on a locked A waits, then shows. | `session::session` `wait_for_unlock`, `locked_canvas`, `lock_wait_tick` | `host_session::app_session_started_locked_waits_then_shows`, `host_session::locked_start_announces_the_app_display` |
| `Sources/rapp-host/Server.swift:699-740` | `startCapture`: opens the app, refuses with the fixed reasons. | `session::session` `start_app`, `app_opened` (platform: `Platform::open`) | `host_session::cannot_open_reports_the_reason`, `cli::open_error_reasons_are_fixed` |
| `Sources/rapp-host/Server.swift:741-793` | `captureReady`: `ready`, the window table, the first frame, density capped by the display. | `session::session` `app_opened`, `ceiling`; `session::capture` `start_capture_thread` | `host_session::density_is_capped_by_the_display_scale`, `host_session::listening_then_ready` |
| `Sources/rapp-host/Server.swift:794-811` | `startTimers`: the 1 s tick and the window poll. | `session::session` `start_timers`, `start_window_poll` | `host_session::stats_event_every_second` |
| `Sources/rapp-host/Server.swift:812-862` | `startDesktop` and `desktopReady`: the whole display, one fixed window. | `session::session` `start_desktop`, `desktop_ready`; `desktop` | `host_session::desktop_session_shows_the_main_display`, `rules_windows::desktop_matches_swift` |
| `Sources/rapp-host/Server.swift:863-873` | `sendLocked`: the lock state, only when it changed. | `session::session` `send_locked` | `host_session::unlock_with_a_wrong_password`, `host_session::unlock_when_not_locked` |
| `Sources/rapp-host/Server.swift:874-913` | `unlock`: types B's password at the lock screen, one typist at a time. | `session::unlock` `unlock`; `lock` `type_unlock_password`, `with_unlock_lock` | `host_session::unlock_with_the_right_password`, `host_session::password_never_leaves`, `host_session::disconnect_while_typing_frees_the_lock` |
| `Sources/rapp-host/Server.swift:914-940` | `startClipboard`: the store and the watcher, main display only for a desktop. | `session::clip` `start_clipboard`, `lock_store` | `host_session::host_copy_is_announced` |
| `Sources/rapp-host/Server.swift:941-976` | `tableChanged` and `applyRegion`: the window table and the captured region. | `session::session` `table_changed`, `apply_region`; `session::tracker` `window_table` | `host_session::window_added_and_removed`, `host_session::set_view_narrows_the_picture`, `host_session::empty_region_sends_no_frame` |
| `Sources/rapp-host/Server.swift:977-1036` | `frameArrived`, `quantizeAndSubmit`, `submit`: frames into tiles. | `session::capture` `frame_arrived`, `quantize_frame`; `tile`; `quantize` | `host_session::scroll_arrives_as_copy_tiles`, `tile::frames_match_swift` |
| `Sources/rapp-host/Server.swift:1037-1084` | `makePacedSender`, `applyLevel`, `syncFocus`, `levelChanged`: pacing and saving levels. | `session::session` `make_paced_sender`, `apply_level`, `level_changed`; `pacing` | `host_session::unacknowledged_controller_gets_bounded_frames`, `pacing::paced_sender_matches_swift` |
| `Sources/rapp-host/Server.swift:1085-1112` | `tick`: stats, liveness of the target. | `session::session` `tick` | `host_session::stats_event_every_second`, `host_session::target_exit_ends_the_session` |
| `Sources/rapp-host/Server.swift:1113-1149` | `startInputSource`, `sendInputSource`, `selectInput`. | `session::session` `start_input_source`, `send_input_source`; `session::input` `select_input` | `host_session::input_source_is_reported_and_selected` |
| `Sources/rapp-host/Server.swift:1150-1185` | `streamDescription` and `setStream`. | `session::session` `stream_description`; `session::capture` `set_stream`, `set_stream_request` | `host_session::set_stream_changes_mode`, `host_session::pause_mode_change_resumes_full` |
| `Sources/rapp-host/Server.swift:1186-1197` | `resize`: content size plus the title row, kept on the display. | `session::input` `resize_window`; `geometry` (platform: `WindowOps::resize`) | `host_session::window_commands_reach_the_platform` |
| `Sources/rapp-host/Server.swift:1198-1238` | `setPaused`, `updateCapture`, `send`, `transmit`. | `session::capture` `set_paused`; `session::session` `send`, `transmit`, `write`; `pause` | `host_session::pause_and_resume`, `pacing::pause_outbox_matches_swift` |
| `Sources/rapp-host/Server.swift:1239-1248` | `fail`: an error to B, then the end. | `session::session` `fail` | `host_session::capture_error_ends_the_session` |
| `Sources/rapp-host/Server.swift:1249-1265` | `scheduleMenuRead`. | not on Windows: no menu mirror (spec §6.3) | `host_session::menu_pick_is_ignored` |
| `Sources/rapp-host/Server.swift:1266-1319` | `takeOver` and `end`: the notice, input released, timers and capture stopped once. | `session::session` `take_over`, `end` | `host_session::second_hello_takes_over`, `host_session::keys_and_buttons_released_at_session_end` |
| `Sources/rapp-host/Server.swift:1320-1322` | `uptimeSeconds`. | `clock` `Clock::now` | `host_session::stats_event_every_second` |
| `Sources/rapp-host/SideConnection.swift:1-78` | A side connection: its slot and `start`. | `session::side` `SideConnection::new`, `run`, `start` | `host_session::fifth_side_connection_is_refused`, `host_session::side_connection_with_wrong_token_is_refused` |
| `Sources/rapp-host/SideConnection.swift:79-126` | `fetch` and `put`: chunks out, chunks in, the finished file named safely. | `session::side` `send_chunks`, `receive_chunks`, `handle`, `finish_put`; `filename` | `host_session::fetch_a_host_file`, `host_session::put_resumes_after_disconnect`, `host_session::hostile_names_stay_inside` |
| `Sources/rapp-host/SideConnection.swift:127-175` | `receive`, `send`, `fail`, `close`, `end`. | `session::side` `send`, `fail`, `end`, `abort`; `session::server` `side_ended` | `host_session::put_resumes_after_disconnect`, `transfers::transfer_chunks_match_swift` |
| `Sources/rapp-host/UnlockTyper.swift:1-45` | Wakes the lock screen, types the password, presses Return. | `lock` `type_unlock_password`, `password_units`; platform: `LockOps::wake`, `type_units`, `press_return` | `rules_lock::unlock_sequence_matches_swift`, `host_session::unlock_with_the_right_password` |
| `Sources/rapp-host/VisionText.swift:1-90` | On-device text recognition for state rules. | platform: `TextReader::lines` (`Parts::text`) | `state_rules::rule_detectors` |
| `Sources/rapp-host/WindowCapture.swift:1-27` | `HostError` and `FoundApp`: the fixed open-error reasons. | `platform` `OpenError` | `cli::open_error_reasons_are_fixed` |
| `Sources/rapp-host/WindowCapture.swift:28-125` | `find` and `findDisplay`: the app and its display. | platform: `Platform::open`, `TargetOps::display` | `host_session::cannot_open_reports_the_reason` |
| `Sources/rapp-host/WindowCapture.swift:126-164` | The capture's inits and its configuration. | platform: `Capture::frame` | phase D |
| `Sources/rapp-host/WindowCapture.swift:165-243` | `start`, `stop`, `setRegion`, `setStream`, `apply`, `output`. | `session::capture` `start_capture_thread`, `capture_params_changed`, `stop_capture`, `run` | `host_session::set_view_narrows_the_picture`, `host_session::capture_silence_does_not_spin`, `host_session::disconnect_mid_frame_cleans_up` |
| `Sources/rapp-host/WindowCapture.swift:244-250` | The stream's error ends the session. | `session::capture` `deliver` | `host_session::capture_error_ends_the_session` |
| `Sources/rapp-host/WindowCapture.swift:251-272` | `currentDisplays`: the displays for `list-apps` and desktop sessions. | platform: `Platform::displays`; `desktop` `ordered_displays` | `rules_windows::desktop_matches_swift` |
| `Sources/rapp-host/WindowCapture.swift:273-287` | `lockedAppDisplay`: the display an app on a locked A is shown on. | `session::session` `locked_canvas`; `lock` `locked_start_display` (platform: `Platform::locked_app_windows`) | `host_session::locked_start_announces_the_app_display`, `host_session::locked_start_without_app_windows_announces_the_main_display` |
| `Sources/rapp-host/WindowResizer.swift:1-119` | Moves and resizes the target's windows, kept on the display. | `geometry` `window_size`, `clamped_window_origin`; `session::input` `resize_window`, `move_window`; platform: `WindowOps::resize`, `move_to` | `host_session::window_commands_reach_the_platform`, `rules_windows::geometry_matches_swift` |
| `Sources/rapp-host/WindowTracker.swift:1-35` | The tracker: polls the target's windows. | `session::session` `start_window_poll` | `host_session::window_added_and_removed` |
| `Sources/rapp-host/WindowTracker.swift:36-105` | `poll`: the window table from the system list. | `session::tracker` `window_table`, `raw_for`; `wintable` (platform: `WindowOps::list`, `screen`) | `rules_windows::window_table_matches_swift`, `host_session::all_windows_closed_keeps_the_session` |
| `Sources/rapp-host/WindowTracker.swift:106-112` | `globalFrame`. | `session::tracker` `global_frame` | `rules_windows::view_region_matches_swift` |

## 2. `Sources/RappCore/`

| Swift | Status | Fixture test |
|---|---|---|
| `Clipboard.swift` | ported → `clipboard` | `rules_clip::clip_rules_match_swift` |
| `DataPaths.swift` | ported in part → `transfers` (`transfer_dir`), `lock` (`unlock_lock_file`); the data root itself comes from platform: `Platform::data_root` | `transfers::transfer_dir_prefers_rapp_downloads` |
| `Deflate.swift` | ported → `deflate` | `deflate::script_matches_swift` |
| `Desktop.swift` | ported → `desktop` | `rules_windows::desktop_matches_swift` |
| `FileLock.swift` | ported → `lock` (`with_unlock_lock`) | `rules_lock::two_typists_do_not_overlap` |
| `FocusPane.swift` | ported → `focus::pane` | `rules_focus::focus_pane_matches_swift` |
| `FocusTracker.swift` | ported → `focus::tracker` | `rules_focus::focus_tracker_matches_swift` |
| `FrameMark.swift` | controller only, not ported | - |
| `Geometry.swift` | ported → `geometry` | `rules_windows::geometry_matches_swift` |
| `HIDKeys.swift` | controller only, not ported | - |
| `HeldInput.swift` | ported → `input` | `rules_input::held_input_matches_swift` |
| `HitTest.swift` | ported → `hit_test` | `rules_windows::hit_test_matches_swift` |
| `HostHints.swift` | ported → `hints` | `rules_windows::hints_match_swift` |
| `InputYield.swift` | ported → `input` | `rules_input::input_yield_matches_swift` |
| `Menus.swift` | macOS only (no menu mirror, spec §6.3) | - |
| `PacedSender.swift` | ported → `pacing` | `pacing::paced_sender_matches_swift` |
| `PathProbe.swift` | controller only, not ported | - |
| `PauseOutbox.swift` | ported → `pause` | `pacing::pause_outbox_matches_swift` |
| `PeerNames.swift` | ported → `input` (`PeerNames`) | `rules_input::peer_names_match_swift` |
| `PendingActions.swift` | controller only, not ported | - |
| `Protocol.swift` | ported → `protocol` (host half; `RemoteAddress` and the client parsers are controller only) | `protocol::every_sample_decodes_and_reencodes_identically` |
| `Quantize.swift` | ported → `quantize` | `quantize::quantize_matches_swift` |
| `QueryCoalescer.swift` | ported → `query` | `rules_focus::query_rules_match_swift` |
| `QueryDeadline.swift` | ported → `query` | `rules_focus::query_rules_match_swift` |
| `SaveLadder.swift` | ported → `pacing` | `pacing::save_ladder_matches_swift` |
| `ScreenLock.swift` | ported → `lock` | `rules_lock::lock_rules_match_swift` |
| `ScrollDetect.swift` | ported → `scroll` | `tile::frames_match_swift` |
| `SendPacer.swift` | ported → `pacing` | `pacing::send_pacer_matches_swift` |
| `StateRules/Detectors.swift` | ported → `state::detectors` | `state_rules::rule_detectors` |
| `StateRules/Regions.swift` | ported → `state::regions` | `state_rules::rule_regions` |
| `StateRules/RuleImage.swift` | ported → `state::rule_image` | `state_rules::frames_match_the_swift_canvas` |
| `StateRules/RulePack.swift` | ported → `state::rule_pack` | `state_rules::rule_pack` |
| `StateRules/RuleValue.swift` | ported → `state::rule_value` | `state_rules::rule_pack` |
| `StateRules/StateEngine.swift` | ported → `state::engine` | `state_rules::state_engine` |
| `StateRules/StateTable.swift` | ported → `state::table` | `state_rules::state_table` |
| `StayAwake.swift` | ported → `lock` (`StayAwake`) | `rules_lock::lock_rules_match_swift` |
| `TileCodec.swift` | ported → `tile` (encoder; `FrameDecoder` is controller only) | `tile::frames_match_swift` |
| `Timeout.swift` | not ported: Swift's async give-up; host-core uses deadlines on its own threads (`query`, `intake::read_timeout`) | - |
| `Transfers.swift` | ported → `transfers` | `transfers::transfer_chunks_match_swift` |
| `UnlockSequence.swift` | ported → `lock` | `rules_lock::unlock_sequence_matches_swift` |
| `UpdateGate.swift` | controller only, not ported | - |
| `WeakTier.swift` | ported → `pacing` | `pacing::weak_tier_matches_swift` |
| `Windows.swift` | ported → `wintable` | `rules_windows::window_table_matches_swift` |
| `WorkerCLI.swift` | ported → `cli` (host half; no client arguments, `WorkerOutput` or `TakeoverGate`) | `cli::host_arguments_match_swift` |

## 3. Digests

`shasum -a 256` of every file under `Sources/rapp-host/` and `Sources/RappCore/`, paths from
the repository root.

```
7c599bb9f0c82586f02f1710136424867a927db9d401042aa70f567d55880f80  Sources/RappCore/Clipboard.swift
dadb12db5264f249d58ee765d8b09a838cdfb33492e2f829c8ec1a86244ba838  Sources/RappCore/DataPaths.swift
cb57dd5065c384680d8b5f86bb7a59548df3a954415d9e9c2be2e06847517e8c  Sources/RappCore/Deflate.swift
cba9cbaab2f469de0c5b3b55801b32eacb1b864f7e891874ea079d492edcb9b5  Sources/RappCore/Desktop.swift
cfc0ced6ae3b298ccdad6bd3c7c66403ad75cc925f8b22054d12af6d442d0bc2  Sources/RappCore/FileLock.swift
ecc1a7139275f7845abd9b686f5d694e8498eb3b7ec416063da083dd873f4b8a  Sources/RappCore/FocusPane.swift
fcf2911285bdf8a6a7a4368172fbc1f3b0918ceef5d69c6e3a2faf3e7b34d665  Sources/RappCore/FocusTracker.swift
fb012bc24898ce4e8014d82dd7df476d6570310a1bcdd9d6b5201db799839fb7  Sources/RappCore/FrameMark.swift
dcdaa3aa3323ee4a666ba6a3a50adeceb9f03a7aafdeccc87496608c4adfa09c  Sources/RappCore/Geometry.swift
812570e9f01a8fadb28e8c4b47c378a52f8e2683067644eb1aee4442b1f1638f  Sources/RappCore/HIDKeys.swift
3dc72100a44a90425ba5ac91e835af34136b7027b24316a395b60adc7ffdfaa6  Sources/RappCore/HeldInput.swift
ad9bb2cdbaa5eda62f9ec7c14b08044e88a5f11bc345007902f18103459e6827  Sources/RappCore/HitTest.swift
94f93cf3116bb933f53eaf8359ddceebfa3b9cb5241e6ea935363b34a9540fb8  Sources/RappCore/HostHints.swift
60d5493f806b81acebc10c4a7fc1de05f926e9757ba472b2771b6d77783edeb5  Sources/RappCore/InputYield.swift
0f0e840586edf1753bd0e3f6e4c8e0a0d2e0c001e10d5e65683d4deddd854b78  Sources/RappCore/Menus.swift
d64feb117f1e0bbf64b6ec725d8e81aadc7cdbbc0a9ec873e2b5872bb1c59ae9  Sources/RappCore/PacedSender.swift
11c6bcd805042536e69d62637c41f804d01ddfe2e171f111c8865a8955608192  Sources/RappCore/PathProbe.swift
b49fe86a098fe62f56ba81641fff516d3cf5ea800561389acc5d1a854b11a091  Sources/RappCore/PauseOutbox.swift
5dbbdd07ffa7212a8f26a30946b763dc83de68832e37214f3584228643778ebb  Sources/RappCore/PeerNames.swift
2821a254cb7131dda6649fbc73c89b57638392b5a525b5cfb3620cfe91d71f7e  Sources/RappCore/PendingActions.swift
43e4fd24b8876186b46313ef227e90da45ea475d362e3b8785e97e340dd36d50  Sources/RappCore/Protocol.swift
08ef38b430ddd249237c8636ecc9fea870a1f8ce1f728d36e45d5bcfc2c4dcff  Sources/RappCore/Quantize.swift
de52c0ca982341693ebe1435ca95c5d7adea199c03a746ba8d2a116584bef67a  Sources/RappCore/QueryCoalescer.swift
4b00a8d07d57ee3ced325bc84e64067b74eadc980be9c447c26bc1aaba33a368  Sources/RappCore/QueryDeadline.swift
bcbdaab35b7c30c1c844ad5448fa5085dda32984dab29ec10d2e465c3f96dfb9  Sources/RappCore/SaveLadder.swift
c50c23eac02d1204fdfc959ab2f015d05cb0d636108037dee84d7e349a81ac4f  Sources/RappCore/ScreenLock.swift
fdc69e9c3f4eea622cb304dec8236c72e7c45511bca5781b5c4e668a105e443d  Sources/RappCore/ScrollDetect.swift
fc9c28644fb89877d304e121b5d1356523cd85e74140da148142f35cdc0f1a00  Sources/RappCore/SendPacer.swift
2495fdabeb693f94e4098a9bf03f78b7909979d99a2bb47901580b543e43560c  Sources/RappCore/StateRules/Detectors.swift
7e6a07803bb6f87387f1a211ee1e5749199da5292945d351848c74c5e8e5e243  Sources/RappCore/StateRules/Regions.swift
0b52cf45b3ec917be446e25860ad03f2a23a222dbcd85b1cf24483034129da16  Sources/RappCore/StateRules/RuleImage.swift
125550e28c909ec49c92d186b2dbaaa13293b578e9b08a260770ec0aa8a79e5a  Sources/RappCore/StateRules/RulePack.swift
eda09c4e90d814e62031d1066f0cdfa379dc75f2a2033bac67ecb2814c549038  Sources/RappCore/StateRules/RuleValue.swift
ae529827aeee7608aa58726a3635e5d6608a07f4d17467457f1707c1e22df506  Sources/RappCore/StateRules/StateEngine.swift
75c696ee929c497248a2e7e1e47afa82b7caf18a234e3a7e144800dc5bb8ca46  Sources/RappCore/StateRules/StateTable.swift
9acfaa06ac0e85ae988b6a011f0e22ce08c99eead636cd98c3a63098cd38ce58  Sources/RappCore/StayAwake.swift
6885204c71b13cc69d3444f86a489286a578a77ee3d123750ecb71daec3548f1  Sources/RappCore/TileCodec.swift
38f814922111db6bf0baeae6c23df93d22311a451bc6e68afceca69805661bf3  Sources/RappCore/Timeout.swift
10846fe7631fe1c6071b0e783d1d3429e4d0ef4318130bf4c0604a42c865fb67  Sources/RappCore/Transfers.swift
7bd5b9510fd314eab121303bfb8c15634604b43b991b79d77b9bb6078978b80c  Sources/RappCore/UnlockSequence.swift
a47cf139680513718a6f91b8b14276abd7056d0365341143283a3da97747ae81  Sources/RappCore/UpdateGate.swift
d2126e63ff027ae07e4fd7478d5d5995600d13d59068ef432760c6a7df6d59b0  Sources/RappCore/WeakTier.swift
855302a591d6b0c5b89869de0d249f8e48fb51fcbf875945152ddd545844fe9f  Sources/RappCore/Windows.swift
49ea5ebda2fcb6790d297a18e5855ce1bdca3e0f07e8957099932aac46e0fffe  Sources/RappCore/WorkerCLI.swift
53899148e82cc2e79b256a1c845672aa361f579770ebfa3f9d789e15ea321a3a  Sources/rapp-host/AppStateWatcher.swift
5ebacebf3cbe50dcf01d363b279f3c194df19851c1914ff88d63c05821cc4593  Sources/rapp-host/ClipboardWatcher.swift
d28e41f0309e501b74d6beaaf1d11c02a531f815ae3fcc6a212bde682eff7b56  Sources/rapp-host/CoverCloser.swift
4c93ab3aa1267985bdcf1a2f033f9565c1901a809fbacb50f6600b4797112f8b  Sources/rapp-host/FocusReader.swift
c40232b1371c423b44b1783b5d65d3aaf4d20e927b64ee1cc9c2afe95265688c  Sources/rapp-host/FocusSession.swift
f7a9d91f1633cdf383ac941e663868c273ecbe620ca49ef06c69a758ffeca292  Sources/rapp-host/InputInjector.swift
e5162462bab7eeaec9f5597385f3906658e0d31988440adcd24b14537cbb1a95  Sources/rapp-host/InputSourceWatcher.swift
379bde0688cbcc190732bc4ed0c81d9917421f73271b240b71ebb6e6a7f2b7b4  Sources/rapp-host/MenuBarReader.swift
093f781ec28495dd299a6732e55eb8113a88076e3b1aff25039935ce57d380bf  Sources/rapp-host/Paster.swift
92dd0d976636a9804083ad6bfd4a8522d241ca5c1b0973e6b46956ed9ca06812  Sources/rapp-host/PowerHold.swift
94b92bf125436c7d83969c2116ab7cac4e17e509c07043c72c385cd34107ffad  Sources/rapp-host/ScreenLocker.swift
d45467588b040bea4399e3d9ce23e8981612bb18898801062e29551e3f995524  Sources/rapp-host/SecureFocusWatcher.swift
8c71cea93dec086968d454bd5b47eef72e20fb9591b89fc1762c1e78d4c5330c  Sources/rapp-host/Server.swift
e669f56ff9a49750a9db2e17ea1f3b08f6a251488819d851d5573f0864a3a9d3  Sources/rapp-host/SideConnection.swift
8f8587f892f1837495c4db51a92c2cf2f0797be9bb1f46da566b4ede9361066e  Sources/rapp-host/UnlockTyper.swift
101af5b204f2e65498ab6a8464dae1e7ae0fa6430545e39d5b421c03ceea48de  Sources/rapp-host/VisionText.swift
400d898c40f7f68069db725ff6d707f43c4e17b24f45b4fa61c2cbcb71692877  Sources/rapp-host/WindowCapture.swift
acf7c738941464c3588a4947609f9cd9c3921c0156a04fa94adb305fd503cb51  Sources/rapp-host/WindowResizer.swift
89ec06578c09941aca07ce1652b2784b1f4194f8a44e5c4d4bdf521cf3203f02  Sources/rapp-host/WindowTracker.swift
b82f7ac2327ac75eb10c0c5447fb97d1d2f1d5089d8e2385e839c9c6c238aa51  Sources/rapp-host/main.swift
```

## 4. Not byte-exact

Each entry: what differs from Swift, why, and the weaker check that stands in.

- **Text recognition (`VisionText.swift`).** The recogniser is the platform's (spec §6.8,
  probe H7), so its lines cannot match Vision's. Check: the detectors are fixture-tested with
  scripted lines (`state_rules::rule_detectors`); the reader itself is phase D's.
- **The display an app on a locked A is shown on (`WindowCapture.swift:273-287`).** Swift
  asks the window server for the app's windows; host-core asks the platform
  (`Platform::locked_app_windows`) and applies the same `locked_start_display`. A platform that
  cannot list windows while locked answers `None`, and the session shows the main display, as
  Swift does when the app lists no usable window. Check:
  `host_session::locked_start_announces_the_app_display`,
  `host_session::locked_start_without_app_windows_announces_the_main_display`.
- **Staying awake (`PowerHold.swift`).** Swift's session holds an IOKit assertion through
  `StayAwake`, begun at a valid hello and ended at the end. host-core does the same with
  `lock::StayAwake` around `LockOps::stay_awake(true/false)` on a lock handle the session keeps
  for this alone, and writes PowerHold's two lines ("keeping A awake while the session is
  open", "A may idle again"). `stay_awake` returns nothing, so a refusal is not seen and
  Swift's "could not keep A awake (IOKit …)" line has no counterpart. Check:
  `host_session::stay_awake_spans_the_session`, `host_session::a_refused_hello_never_holds_a_awake`.
- **Typing after the session ended.** Swift's typing loop asks only the screen's lock state;
  host-core's also stops once the session is gone (plan B Review Focus 2). Check:
  `host_session::disconnect_while_typing_frees_the_lock`.
