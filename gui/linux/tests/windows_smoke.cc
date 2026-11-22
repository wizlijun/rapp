// Exercise GTK ownership, drawing and shared drafts without a remote Mac.
#include "../runner/rapp_windows.cc"
#include "../runner/rapp_flutter_candidates.cc"
#include "../runner/rapp_secure_input.cc"
#include <cassert>

// GTK ownership and Cairo drawing need a channel, not a running Flutter engine.
// A real engine requests EGL even on Broadway, which cannot supply it.
static std::vector<std::pair<std::string, FlValue *>> events;
static size_t event_count(const std::string &method) {
  return std::count_if(events.begin(), events.end(), [&](const auto &event) { return event.first == method; });
}
static FlValue *last_event(const std::string &method) {
  for (auto it = events.rbegin(); it != events.rend(); ++it) if (it->first == method) return it->second;
  return nullptr;
}
struct TestMessenger { GObject parent; gpointer data; GDestroyNotify destroy; FlBinaryMessengerMessageHandler handler; };
struct TestMessengerClass { GObjectClass parent; };
static void messenger_interface(FlBinaryMessengerInterface *iface) {
  iface->set_message_handler_on_channel = +[](FlBinaryMessenger *m, const gchar *,
      FlBinaryMessengerMessageHandler handler, gpointer data, GDestroyNotify destroy) {
    auto *self = reinterpret_cast<TestMessenger *>(m);
    if (self->destroy) self->destroy(self->data);
    self->data = data; self->destroy = destroy; self->handler = handler;
  };
  iface->send_response = +[](FlBinaryMessenger *, FlBinaryMessengerResponseHandle *, GBytes *, GError **) -> gboolean { return TRUE; };
  iface->send_on_channel = +[](FlBinaryMessenger *m, const gchar *, GBytes *message, GCancellable *cancel,
      GAsyncReadyCallback callback, gpointer data) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    g_autofree gchar *name = nullptr;
    FlValue *args = nullptr;
    assert(FL_METHOD_CODEC_GET_CLASS(codec)->decode_method_call(FL_METHOD_CODEC(codec), message, &name, &args, nullptr));
    events.emplace_back(name, args);
    auto *task = g_task_new(m, cancel, callback, data);
    static const guint8 success[] = {0, 0};
    g_task_return_pointer(task, g_bytes_new_static(success, sizeof(success)),
                          reinterpret_cast<GDestroyNotify>(g_bytes_unref));
    g_object_unref(task);
  };
  iface->send_on_channel_finish = +[](FlBinaryMessenger *, GAsyncResult *result, GError **error) {
    return static_cast<GBytes *>(g_task_propagate_pointer(G_TASK(result), error));
  };
}
G_DEFINE_TYPE_WITH_CODE(TestMessenger, test_messenger, G_TYPE_OBJECT,
  G_IMPLEMENT_INTERFACE(fl_binary_messenger_get_type(), messenger_interface))
static void test_messenger_class_init(TestMessengerClass *) {}
static void test_messenger_init(TestMessenger *) {}
struct TestResponse { FlBinaryMessengerResponseHandle parent; };
struct TestResponseClass { FlBinaryMessengerResponseHandleClass parent; };
G_DEFINE_TYPE(TestResponse, test_response, fl_binary_messenger_response_handle_get_type())
static void test_response_class_init(TestResponseClass *) {}
static void test_response_init(TestResponse *) {}
int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  g_autoptr(GtkApplication) app =
      gtk_application_new("test.rapp.windows", G_APPLICATION_NON_UNIQUE);
  assert(g_application_register(G_APPLICATION(app), nullptr, nullptr));
  auto *main = GTK_WINDOW(gtk_application_window_new(app));
  g_autoptr(GObject) messenger = G_OBJECT(g_object_new(test_messenger_get_type(), nullptr));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(FL_BINARY_MESSENGER(messenger), "test/rapp",
                            FL_METHOD_CODEC(codec));
  {
    RappWindows manager{channel, main, {}};
    auto session = std::make_unique<Session>();
    auto &s = *session;
    manager.sessions.emplace(17, std::move(session));
    fl_method_channel_set_method_call_handler(channel,
      +[](FlMethodChannel *, FlMethodCall *call, gpointer data) {
        assert(rapp_windows_method(static_cast<RappWindows *>(data), call));
      }, &manager, nullptr);
    auto invoke = [&](const char *method, FlValue *args) {
      setint(args, "sid", 17);
      g_autoptr(GBytes) message = FL_METHOD_CODEC_GET_CLASS(codec)->encode_method_call(FL_METHOD_CODEC(codec), method, args, nullptr);
      g_autoptr(GObject) response = G_OBJECT(g_object_new(test_response_get_type(), nullptr));
      auto *m = reinterpret_cast<TestMessenger *>(messenger);
      m->handler(FL_BINARY_MESSENGER(messenger), "test/rapp", message,
        FL_BINARY_MESSENGER_RESPONSE_HANDLE(response), m->data);
      fl_value_unref(args);
    };
    s.channel = channel;
    s.main = main;
    s.sid = 17;
    s.manager = &manager;
    g_signal_connect(s.buffer, "changed", G_CALLBACK(+[](GtkTextBuffer *, gpointer data) { static_cast<Session *>(data)->changed(); }), &s);
    gtk_text_buffer_set_text(s.buffer, "中文 draft", -1);
    s.blocks.push_back({1, "image.png"});
    g_autoptr(FlValue) table = fl_value_new_list();
    for (auto pair : {std::pair<int, int>{4, 3}, {3, 1}, {2, 0}, {1, 0}}) {
      auto *row = fl_value_new_map();
      setint(row, "id", pair.first);
      setint(row, "parent", pair.second);
      fl_value_append_take(table, row);
    }
    for (auto *row : ordered_windows(table)) {
      int id = integer(get(row, "id")), parent = integer(get(row, "parent"));
      assert(!parent || s.windows.count(parent));
      s.windows[id] = create_window(&s, id, parent != 0,
                                    parent ? s.windows[parent].get() : nullptr);
    }
    assert(s.windows.size() == 4);
    auto *parent = s.windows[1].get();
    parent->focused = true;
    s.w = 4;
    s.h = 4;
    s.pixels.assign(4 * 4 * 4, 255);
    for (size_t i = 0; i < s.pixels.size(); i += 4) {
      s.pixels[i] = 0;
      s.pixels[i + 1] = 0;
    }
    s.surface = cairo_image_surface_create_for_data(
        s.pixels.data(), CAIRO_FORMAT_ARGB32, 4, 4, 16);
    for (auto &entry : s.windows) {
      auto *w = entry.second.get();
      w->w = 4;
      w->h = 4;
      gtk_widget_set_size_request(w->area, 64, 64);
      gtk_widget_show_all(w->shell);
    }
    refresh_chips(&s);
    for (int i = 0; i < 30; i++) {
      while (g_main_context_iteration(nullptr, FALSE)) {
      }
      g_usleep(10000);
    }
    assert(s.draft() == "中文 draft");
    // All normal windows participate; popovers do not keep a minimized session alive.
    auto state = [](Window *w, GdkWindowState flags) {
      GdkEventWindowState event{};
      event.type = GDK_WINDOW_STATE;
      event.changed_mask = GDK_WINDOW_STATE_ICONIFIED;
      event.new_window_state = flags;
      gboolean handled = FALSE;
      g_signal_emit_by_name(w->shell, "window-state-event", &event, &handled);
    };
    const auto visibility_events = event_count("window_visible");
    state(parent, GDK_WINDOW_STATE_ICONIFIED);
    assert(s.any_visible && event_count("window_visible") == visibility_events);
    state(s.windows[2].get(), GDK_WINDOW_STATE_ICONIFIED);
    assert(!s.any_visible && !fl_value_get_bool(get(last_event("window_visible"), "visible")));
    state(parent, GDK_WINDOW_STATE_FOCUSED);
    assert(s.any_visible && fl_value_get_bool(get(last_event("window_visible"), "visible")));
    const auto restored_events = event_count("window_visible");
    state(parent, static_cast<GdkWindowState>(0)); // Losing focus alone never pauses.
    assert(s.any_visible && event_count("window_visible") == restored_events);
    gtk_widget_hide(parent->shell);
    assert(!s.any_visible);
    gtk_widget_show(parent->shell); // Reopened from outside Dart (launcher/tray).
    assert(s.any_visible);
    state(s.windows[2].get(), static_cast<GdkWindowState>(0));
    assert(gtk_widget_get_allocated_width(parent->area) >= 64);
    auto *surface = cairo_image_surface_create(
        CAIRO_FORMAT_ARGB32, gtk_widget_get_allocated_width(parent->area),
        gtk_widget_get_allocated_height(parent->area));
    auto *cr = cairo_create(surface);
    gtk_widget_draw(parent->area, cr);
    cairo_surface_flush(surface);
    int x = gtk_widget_get_allocated_width(parent->area) / 2,
        y = gtk_widget_get_allocated_height(parent->area) / 2;
    auto *pixel = cairo_image_surface_get_data(surface) +
                  y * cairo_image_surface_get_stride(surface) + x * 4;
    assert(pixel[2] == 255 && pixel[1] == 0 && pixel[0] == 0);
    // Smart focus: the centre stays red while the outside becomes luma gray.
    auto *focus = fl_value_new_map();
    setint(focus, "window", 1);
    auto *rects = fl_value_new_list(), *rect = fl_value_new_list();
    for (auto value : {1, 1, 2, 2}) fl_value_append_take(rect, fl_value_new_float(value));
    fl_value_append_take(rects, rect);
    put(focus, "rects", rects);
    invoke("focus", focus);
    assert(s.focus_window == 1 && s.focus_rects.size() == 1);
    gtk_widget_draw(parent->area, cr);
    cairo_surface_flush(surface);
    assert(pixel[2] == 255 && pixel[1] == 0 && pixel[0] == 0);
    const double zoom = std::min(gtk_widget_get_allocated_width(parent->area) / 4.,
                                gtk_widget_get_allocated_height(parent->area) / 4.);
    const int outside_x = x - static_cast<int>(zoom * 1.5);
    auto *outside = cairo_image_surface_get_data(surface) + y * cairo_image_surface_get_stride(surface) + outside_x * 4;
    assert(outside[0] == outside[1] && outside[1] == outside[2] && outside[2] == 76);
    parent->focused = false;
    gtk_widget_draw(parent->area, cr);
    cairo_surface_flush(surface);
    assert(outside[2] == 255 && outside[1] == 0 && outside[0] == 0);
    auto *options = fl_value_new_map();
    put(options, "allowed", fl_value_new_bool(false));
    invoke("composer_options", options);
    assert(!gtk_widget_get_visible(parent->composer));
    options = fl_value_new_map();
    put(options, "allowed", fl_value_new_bool(true));
    put(options, "scale", fl_value_new_float(1.5));
    invoke("composer_options", options);
    assert(gtk_widget_get_visible(parent->composer));
    auto *banner = fl_value_new_map();
    settext(banner, "text", "locked");
    invoke("banner", banner);
    assert(std::string(gtk_label_get_text(GTK_LABEL(parent->banner))) == "locked");
    auto *draft = fl_value_new_map();
    settext(draft, "text", "new draft");
    invoke("composer_draft", draft);
    assert(s.draft() == "new draft");
    s.sending = true;
    s.sent_text = "new draft";
    auto *submitted = fl_value_new_map();
    put(submitted, "taken", fl_value_new_bool(true));
    invoke("composer_submitted", submitted);
    assert(s.draft().empty());
    auto *done = fl_value_new_map();
    invoke("composer_done", done);
    assert(!s.sending);
    // 0.13: remote password focus must bypass type-to-compose at the very
    // native handler that receives the first key; explicit Ctrl+Enter remains.
    options = fl_value_new_map();
    put(options, "compose", fl_value_new_bool(true));
    put(options, "font_size", fl_value_new_float(18));
    settext(options, "font_family", "sans");
    setint(options, "text_color", 0xffddeeff);
    setint(options, "hint_color", 0xff8899aa);
    setint(options, "focus_color", 0xff112233);
    invoke("composer_options", options);
    assert(s.font_size == 18 && s.focus_color.red == 0x11 / 255.);
    auto *secure = fl_value_new_map();
    put(secure, "on", fl_value_new_bool(true));
    invoke("secure_focus", secure);
    GdkEventKey press{};
    press.type = GDK_KEY_PRESS; press.keyval = GDK_KEY_a;
    press.window = gtk_widget_get_window(parent->area);
    gboolean handled = FALSE;
    const auto compose_before = event_count("composer_action");
    g_signal_emit_by_name(parent->area, "key-press-event", &press, &handled);
    assert(s.draft().empty() && event_count("composer_action") == compose_before);
    press.keyval = GDK_KEY_Return; press.state = GDK_CONTROL_MASK;
    g_signal_emit_by_name(parent->area, "key-press-event", &press, &handled);
    assert(event_count("composer_action") == compose_before + 1);
    assert(std::string(text(get(last_event("composer_action"), "action"))) == "open");

    auto notice = [&](int epoch, const char *value) {
      auto *args = fl_value_new_map(); setint(args, "epoch", epoch); settext(args, "text", value);
      auto *actions = fl_value_new_list(), *action = fl_value_new_map();
      settext(action, "id", "dismiss"); settext(action, "label", "关掉它");
      fl_value_append_take(actions, action); put(args, "actions", actions);
      invoke("host_notice", args);
    };
    notice(10, "first cover");
    GList *buttons = gtk_container_get_children(GTK_CONTAINER(parent->notice));
    auto *old_button = GTK_WIDGET(g_object_ref(g_list_nth_data(buttons, 1)));
    g_list_free(buttons);
    gtk_button_clicked(GTK_BUTTON(old_button));
    assert(integer(get(last_event("host_notice_action"), "epoch")) == 10);
    notice(11, "new cover");
    notice(9, "stale cover");
    assert(s.notice_text == "new cover");
    gtk_button_clicked(GTK_BUTTON(old_button));
    assert(integer(get(last_event("host_notice_action"), "epoch")) == 10);
    g_object_unref(old_button);
    notice(11, "");
    assert(!gtk_widget_get_visible(parent->notice));

    // Inline blocks round-trip at their real caret positions, across both native
    // views. The shared buffer stores anchors; neither copy nor cut leaks marks.
    s.blocks.clear();
    set_draft(&s, "AB");
    GtkTextIter caret;
    gtk_text_buffer_get_iter_at_offset(s.buffer, &caret, 1);
    gtk_text_buffer_place_cursor(s.buffer, &caret);
    auto marked = [](gunichar value) { char text[7] = {}; g_unichar_to_utf8(value, text); return std::string(text); };
    const auto first = marked(0xfdd0), second = marked(0xfdd1), third = marked(0xfdd2);
    auto add = [&](const char *value, int id, gunichar mark) {
      auto *args = fl_value_new_map(); settext(args, "text", value);
      auto *blocks = fl_value_new_list(), *block = fl_value_new_map();
      setint(block, "n", id); settext(block, "label", "文件 图片.png"); setint(block, "mark", mark);
      fl_value_append_take(blocks, block); put(args, "blocks", blocks);
      invoke("composer_insert", args);
    };
    const auto drafts_before = event_count("draft");
    add("中", 7, 0xfdd0);
    assert(s.draft() == "A中" + first + "B");
    assert(event_count("draft") == drafts_before + 1);
    gtk_text_buffer_get_iter_at_offset(s.buffer, &caret, 2);
    auto *anchor = gtk_text_iter_get_child_anchor(&caret);
    assert(anchor);
    GList *widgets = gtk_text_child_anchor_get_widgets(anchor);
    assert(g_list_length(widgets) == 2); // one widget per view, one logical chip
    g_list_free(widgets);
    add("", 8, 0xfdd1);
    assert(s.draft() == "A中" + first + second + "B");
    GtkTextIter begin, end;
    gtk_text_buffer_get_bounds(s.buffer, &begin, &end);
    gtk_text_buffer_select_range(s.buffer, &begin, &end);
    g_signal_emit_by_name(parent->editor, "copy-clipboard");
    g_autofree gchar *copied = gtk_clipboard_wait_for_text(gtk_widget_get_clipboard(parent->editor, GDK_SELECTION_CLIPBOARD));
    assert(copied && std::string(copied) == "A中B");
    g_signal_emit_by_name(parent->editor, "cut-clipboard");
    assert(s.draft().empty() && s.blocks.size() == 2); // hold until submit / handoff
    set_draft(&s, "左" + first + "右" + second);
    send_draft(&s);
    assert(std::string(text(get(last_event("composer_send"), "text"))) == "左" + first + "右" + second);
    assert(!get(last_event("composer_send"), "pieces"));
    add("尾", 9, 0xfdd2); // an insertion after take must survive acknowledgement
    submitted = fl_value_new_map(); put(submitted, "taken", fl_value_new_bool(true));
    invoke("composer_submitted", submitted);
    assert(s.draft() == "尾" + third && s.blocks.size() == 1 && s.blocks.front().n == 9);
    invoke("composer_done", fl_value_new_map());

    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    // Parent disposal before a retained popover must not leave a dangling GTK
    // pointer.
    s.windows.erase(1);
    s.windows.erase(4);
    s.windows.erase(3);
    s.windows.erase(2);
    s.windows[1] = create_window(&s, 1, false, nullptr);
    auto *view = s.windows[1]->editor;
    gtk_widget_show_all(s.windows[1]->shell);
    while (g_main_context_iteration(nullptr, FALSE)) {}
    set_draft(&s, "");
    // History is available with an unsent draft, and editing a recalled entry
    // must not lose Down's path back to the draft (0.15.1).
    auto editor_key = [&](guint key, guint modifiers = 0) {
      GdkEventKey event{};
      event.type = GDK_KEY_PRESS; event.keyval = key; event.state = modifiers;
      event.window = gtk_widget_get_window(view);
      gboolean taken = FALSE;
      g_signal_emit_by_name(view, "key-press-event", &event, &taken);
    };
    set_draft(&s, "unfinished");
    auto actions_before = event_count("composer_action");
    editor_key(GDK_KEY_Up);
    assert(event_count("composer_action") == actions_before + 1);
    assert(std::string(text(get(last_event("composer_action"), "action"))) == "up");
    assert(std::string(text(get(last_event("composer_action"), "text"))) == "unfinished");
    auto *recalled = fl_value_new_map(); settext(recalled, "text", "older");
    invoke("composer_draft", recalled);
    gtk_text_buffer_insert_at_cursor(s.buffer, " edited", -1);
    editor_key(GDK_KEY_Down);
    assert(std::string(text(get(last_event("composer_action"), "action"))) == "down");
    assert(std::string(text(get(last_event("composer_action"), "text"))) == "older edited");
    // A composing input method may decline a key. It still owns the preedit:
    // do not recall history, queue a send, zoom or close its session.
    actions_before = event_count("composer_action");
    const auto closes_before = event_count("close");
    const auto composing_sends = event_count("composer_send");
    const auto pending_before = s.pending.size();
    g_signal_emit_by_name(view, "preedit-changed", "ni");
    editor_key(GDK_KEY_Up);
    editor_key(GDK_KEY_Down);
    editor_key(GDK_KEY_Return);
    editor_key(GDK_KEY_plus, GDK_CONTROL_MASK);
    editor_key(GDK_KEY_q, GDK_CONTROL_MASK);
    assert(event_count("composer_action") == actions_before);
    assert(event_count("close") == closes_before);
    assert(event_count("composer_send") == composing_sends && s.pending.size() == pending_before);
    g_signal_emit_by_name(view, "preedit-changed", "");
    while (g_main_context_iteration(nullptr, FALSE)) {}
    set_draft(&s, "");
    // Commit and another Return can arrive before the low-priority idle: send
    // must queue after the earlier paste instead of snapshotting the old draft.
    g_signal_emit_by_name(view, "preedit-changed", "ni");
    auto *before_send = fl_value_new_map(); settext(before_send, "text", " first");
    invoke("composer_insert", before_send);
    const auto sends_before = event_count("composer_send");
    gtk_text_buffer_insert_at_cursor(s.buffer, "你", -1);
    g_signal_emit_by_name(view, "preedit-changed", "");
    send_draft(&s); send_draft(&s);
    assert(event_count("composer_send") == sends_before);
    while (g_main_context_iteration(nullptr, FALSE)) {}
    assert(event_count("composer_send") == sends_before + 1);
    assert(std::string(text(get(last_event("composer_send"), "text"))) == "你 first");
    invoke("composer_done", fl_value_new_map());
    // Acknowledging the last send must not mutate a new preedit. Completion
    // follows the same queue so it cannot erase the take snapshot prematurely.
    set_draft(&s, "old");
    send_draft(&s);
    g_signal_emit_by_name(view, "preedit-changed", "ni");
    auto *ack = fl_value_new_map(); put(ack, "taken", fl_value_new_bool(true));
    invoke("composer_submitted", ack);
    invoke("composer_done", fl_value_new_map());
    assert(s.draft() == "old" && s.sent_text == "old");
    gtk_text_buffer_insert_at_cursor(s.buffer, "你", -1);
    g_signal_emit_by_name(view, "preedit-changed", "");
    send_draft(&s);
    while (g_main_context_iteration(nullptr, FALSE)) {}
    assert(s.draft() == "你");
    assert(std::string(text(get(last_event("composer_send"), "text"))) == "你");
    invoke("composer_done", fl_value_new_map());
    set_draft(&s, "");
    g_signal_emit_by_name(view, "preedit-changed", "ni");
    auto *queued = fl_value_new_map(); settext(queued, "text", " pasted");
    invoke("composer_insert", queued);
    invoke("attach", fl_value_new_map());
    assert(s.pending.size() == 2 && manager.sessions.count(17));
    gtk_text_buffer_insert_at_cursor(s.buffer, "你", -1); // normal IME commit
    g_signal_emit_by_name(view, "preedit-changed", "");
    while (g_main_context_iteration(nullptr, FALSE)) {}
    assert(!manager.sessions.count(17));
    assert(std::string(text(get(last_event("draft"), "text"))) == "你 pasted");
    // Closing a session is not a handoff. It must destroy even a composing
    // window immediately and finish pending platform calls without replay.
    auto *detached = fl_value_new_map(); settext(detached, "text", "kept");
    invoke("detach", detached);
    auto *closing = manager.sessions.at(17).get();
    closing->windows[1] = create_window(closing, 1, false, nullptr);
    g_signal_emit_by_name(closing->windows[1]->editor, "preedit-changed", "ni");
    auto *late = fl_value_new_map(); settext(late, "text", " discarded");
    invoke("composer_insert", late);
    invoke("attach", fl_value_new_map());
    assert(closing->pending.size() == 2);
    const auto old_drafts = event_count("draft");
    auto *discard = fl_value_new_map(); put(discard, "discard", fl_value_new_bool(true));
    invoke("attach", discard);
    while (g_main_context_iteration(nullptr, FALSE)) {}
    assert(manager.sessions.empty() && event_count("draft") == old_drafts);
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
  }
  {
    g_autoptr(GObject) candidate_messenger = G_OBJECT(g_object_new(test_messenger_get_type(), nullptr));
    g_autoptr(GObject) secure_messenger = G_OBJECT(g_object_new(test_messenger_get_type(), nullptr));
    auto *view = gtk_drawing_area_new(); g_object_ref_sink(view);
    rapp::register_flutter_candidates(FL_BINARY_MESSENGER(candidate_messenger), view, main);
    rapp::register_secure_input(FL_BINARY_MESSENGER(secure_messenger), view);
    auto *owner = static_cast<rapp::FlutterCandidates *>(g_object_get_data(G_OBJECT(view), "rapp-candidates"));
    auto secure_call = [&](const char *method) {
      g_autoptr(GBytes) message = FL_METHOD_CODEC_GET_CLASS(codec)->encode_method_call(FL_METHOD_CODEC(codec), method, nullptr, nullptr);
      g_autoptr(GObject) response = G_OBJECT(g_object_new(test_response_get_type(), nullptr));
      auto *m = reinterpret_cast<TestMessenger *>(secure_messenger);
      m->handler(FL_BINARY_MESSENGER(secure_messenger), "rapp/secure-input", message,
        FL_BINARY_MESSENGER_RESPONSE_HANDLE(response), m->data);
    };
    secure_call("begin"); secure_call("begin"); assert(owner->secure);
    secure_call("end"); assert(owner->secure);
    secure_call("end"); secure_call("end"); assert(!owner->secure);
    gtk_widget_destroy(view); g_object_unref(view);
    while (g_main_context_iteration(nullptr, FALSE)) {}
  }
  gtk_widget_destroy(GTK_WIDGET(main));
  for (const auto &event : events) fl_value_unref(event.second);
  events.clear();
  g_print("PASS native windows, nested popups, shared draft, crop drawing and "
          "teardown; v13 secure focus, host hints, inline chips and IME FIFO\n");
}
