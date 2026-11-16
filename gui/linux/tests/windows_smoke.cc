// Exercise GTK ownership, drawing and shared drafts without a remote Mac.
#include "../runner/rapp_windows.cc"
#include <cassert>

// GTK ownership and Cairo drawing need a channel, not a running Flutter engine.
// A real engine requests EGL even on Broadway, which cannot supply it.
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
  iface->send_on_channel = +[](FlBinaryMessenger *m, const gchar *, GBytes *, GCancellable *cancel,
      GAsyncReadyCallback callback, gpointer data) {
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
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    // Parent disposal before a retained popover must not leave a dangling GTK
    // pointer.
    s.windows.erase(1);
    s.windows.erase(4);
    s.windows.erase(3);
    s.windows.erase(2);
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
  }
  gtk_widget_destroy(GTK_WIDGET(main));
  g_print("PASS native windows, nested popups, shared draft, crop drawing and "
          "teardown\n");
}
