#include "candidates_mock.h"
#include "../rapp_candidates_gtk.h"

namespace {
GtkWidget *last_child(GtkWidget *container) {
  auto *children = gtk_container_get_children(GTK_CONTAINER(container));
  auto *last = GTK_WIDGET(g_list_last(children)->data);
  g_list_free(children);
  return last;
}
}
int main(int argc, char **argv) {
  try {
    require(g_strcmp0(g_getenv("RAPP_CANDIDATES_ISOLATED_TEST"), "1") == 0 &&
      g_strcmp0(g_getenv("GDK_BACKEND"), "broadway") == 0, "private display and bus required");
    gtk_init(&argc, &argv);
    g_set_prgname("com.rapp.rapp");
    Mock mock;
    auto *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    g_object_ref_sink(window);
    gtk_window_set_default_size(GTK_WINDOW(window), 480, 240);
    auto *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(window), root);
    auto *editor = gtk_text_view_new();
    auto *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor));
    gtk_text_buffer_set_text(buffer, "unchanged draft", -1);
    auto *scroll = gtk_scrolled_window_new(nullptr, nullptr);
    gtk_widget_set_size_request(scroll, -1, 60);
    gtk_container_add(GTK_CONTAINER(scroll), editor);
    auto *box = rapp::wrap_gtk_candidates(GTK_TEXT_VIEW(editor), scroll);
    auto *row = last_child(box);
    gtk_box_pack_start(GTK_BOX(root), box, TRUE, TRUE, 0);
    // A second real IM context sharing the draft must not share its lease.
    auto *other = gtk_text_view_new_with_buffer(buffer);
    auto *other_scroll = gtk_scrolled_window_new(nullptr, nullptr);
    gtk_widget_set_size_request(other_scroll, -1, 60);
    gtk_container_add(GTK_CONTAINER(other_scroll), other);
    auto *other_box = rapp::wrap_gtk_candidates(GTK_TEXT_VIEW(other), other_scroll);
    auto *other_row = last_child(other_box);
    gtk_box_pack_start(GTK_BOX(root), other_box, TRUE, TRUE, 0);
    auto *field = gtk_entry_new();
    gtk_box_pack_start(GTK_BOX(root), field, FALSE, FALSE, 0);
    unsigned paints = 0;
    g_signal_connect_after(row, "draw", G_CALLBACK(+[](GtkWidget *, cairo_t *, gpointer data) -> gboolean {
      ++*static_cast<unsigned *>(data); return FALSE;
    }), &paints);
    gtk_widget_show_all(window);
    gtk_window_present(GTK_WINDOW(window));
    gtk_widget_grab_focus(editor);
    wait([&] { return mock.registrations && gtk_widget_get_mapped(row) && paints; }, "GTK3 candidates not painted", 5000);
    require(!gtk_widget_get_visible(other_row), "unfocused sibling owns a row");
    // Paint the actual GTK widget into an initially transparent surface.
    spin(50);
    auto *image = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 480, 80);
    auto *cr = cairo_create(image);
    gtk_widget_draw(row, cr);
    cairo_destroy(cr);
    cairo_surface_flush(image);
    const auto *pixels = cairo_image_surface_get_data(image);
    const int stride = cairo_image_surface_get_stride(image);
    bool ink = false, transparent = false;
    for (int y = 0; y < 80; ++y) for (int x = 0; x < 480; ++x) {
      ink |= pixels[y * stride + x * 4 + 3] != 0;
      transparent |= pixels[y * stride + x * 4 + 3] == 0;
    }
    require(ink && transparent, "candidate painter has no text or fills its background");
    if (const auto *artifact = g_getenv("RAPP_CANDIDATE_PNG")) {
      // A light parent backdrop makes the transparent row readable in PNG viewers.
      auto *preview = cairo_create(image);
      cairo_set_source_rgb(preview, .97, .97, .97);
      cairo_paint(preview);
      gtk_widget_draw(row, preview);
      cairo_destroy(preview);
      cairo_surface_write_to_png(image, artifact);
    }
    cairo_surface_destroy(image);
    const auto token = mock.token;
    GdkEventButton click{};
    click.type = GDK_BUTTON_PRESS; click.button = 1; click.x = 4; click.y = 5;
    gboolean handled = FALSE;
    g_signal_emit_by_name(row, "button-press-event", &click, &handled);
    wait([&] { return mock.selections == 1; }, "candidate click not delivered");
    require(handled && gtk_widget_has_focus(editor), "candidate click stole focus");
    require(mock.last_selection == 7 && mock.last_selection_serial == 1 && mock.last_selection_token == token,
      "candidate action lost its original index, serial or token");
    GtkTextIter begin, end;
    gtk_text_buffer_get_bounds(buffer, &begin, &end);
    g_autofree gchar *draft = gtk_text_buffer_get_text(buffer, &begin, &end, FALSE);
    require(std::string(draft) == "unchanged draft", "candidate UI changed the document itself");
    check("GTK3 mapped transparent candidates, exact selection and retained editor focus");
    const int normal_height = gtk_widget_get_allocated_height(row);
    auto *css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(css, "textview { font-size: 24px; }", -1, nullptr);
    gtk_style_context_add_provider(gtk_widget_get_style_context(editor), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    wait([&] { return gtk_widget_get_allocated_height(row) > normal_height; }, "candidate row ignored editor font scaling");
    mock.rows.clear();
    for (int i = 0; i < 8; ++i) mock.rows.push_back({7 + 5 * i, std::to_string(i + 1), "长候选你好👩‍💻é家庭👨‍👩‍👧‍👦"});
    const auto old_paints = paints;
    mock.frame(++mock.serial);
    wait([&] { return paints > old_paints; }, "scaled Unicode candidates not painted");
    spin(80);
    const auto pages_before = mock.pages;
    click.x = gtk_widget_get_allocated_width(row) - 5;
    g_signal_emit_by_name(row, "button-press-event", &click, &handled);
    spin(80);
    require(mock.pages == pages_before, "local pagination prematurely called engine Page");
    click.x = 4;
    g_signal_emit_by_name(row, "button-press-event", &click, &handled);
    wait([&] { return mock.selections == 2; }, "local page selection missing");
    require(mock.last_selection > 7 && (mock.last_selection - 7) % 5 == 0, "local page renumbered the engine index");
    check("GTK3 editor font scaling and long Unicode local pages preserve original indices");
    gtk_widget_grab_focus(other);
    wait([&] { return mock.token != token && gtk_widget_get_mapped(other_row) && !gtk_widget_get_visible(row); },
      "shared-buffer views did not hand off their leases");
    const auto current = mock.token;
    gtk_widget_grab_focus(field);
    wait([&] { return !gtk_widget_get_visible(other_row); }, "ordinary field did not restore system candidates");
    mock.frame(100, current);
    spin(150);
    require(!gtk_widget_get_visible(row) && !gtk_widget_get_visible(other_row), "late frame reopened an unfocused panel");
    check("GTK3 shared draft uses separate leases; ordinary fields and stale frames remain isolated");
    gtk_widget_destroy(window);
    g_object_unref(window);
    spin(1200);
    check("GTK3 destruction removes timers and callbacks without accessing dead widgets");
  } catch (const std::exception &e) {
    std::cerr << "FAIL: " << e.what() << std::endl;
    return 1;
  }
}
