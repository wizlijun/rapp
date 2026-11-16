// Exercise GTK ownership, drawing and shared drafts without a remote Mac.
#include "../runner/rapp_windows.cc"
#include <cassert>
int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  g_autoptr(GtkApplication) app =
      gtk_application_new("test.rapp.windows", G_APPLICATION_NON_UNIQUE);
  assert(g_application_register(G_APPLICATION(app), nullptr, nullptr));
  auto *main = GTK_WINDOW(gtk_application_window_new(app));
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  g_autoptr(FlEngine) engine = fl_engine_new(project);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_engine_get_binary_messenger(engine), "test/rapp",
                            FL_METHOD_CODEC(codec));
  {
    Session s;
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
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    // Parent disposal before a retained popover must not leave a dangling GTK
    // pointer.
    s.windows.erase(1);
    s.windows.erase(4);
    s.windows.erase(3);
    s.windows.erase(2);
  }
  gtk_widget_destroy(GTK_WIDGET(main));
  g_print("PASS native windows, nested popups, shared draft, crop drawing and "
          "teardown\n");
}
