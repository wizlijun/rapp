#include "rapp_candidates_gtk.h"
#include "rapp_candidates.h"
#include "rapp_candidates_layout.h"
#include <cmath>
#include <utility>

namespace rapp {
namespace {
struct GtkCandidates {
  GtkTextView *editor;
  GtkWidget *row, *scroll, *box;
  std::shared_ptr<CandidateLease> lease;
  CandidateSnapshot snapshot;
  CandidatePage page;
  guint timer = 0;
  bool composing = false, reserve = false, dirty = true, manual = false, engaged = false;
  size_t requested = 0;
  int pitch = 22, left = 0, right = 0;
  double gap = 12, navigation = 48;

  ~GtkCandidates() {
    if (timer) g_source_remove(timer);
    g_signal_handlers_disconnect_by_data(editor, this);
    g_signal_handlers_disconnect_by_data(gtk_text_view_get_buffer(editor), this);
    g_signal_handlers_disconnect_by_data(row, this);
    // Remove callbacks before release can publish its final empty frame.
    lease.reset();
    g_object_unref(editor);
    g_object_unref(row);
    g_object_unref(scroll);
  }
  static std::string label(const Candidate &candidate) {
    auto number = candidate.label;
    while (!number.empty() && (number.back() == '.' || number.back() == ' ')) number.pop_back();
    auto word = candidate.text;
    std::replace(word.begin(), word.end(), '\n', ' ');
    std::replace(word.begin(), word.end(), '\r', ' ');
    return number.empty() ? word : number + "\u2009" + word;
  }
  PangoLayout *layout(const std::string &text) const {
    return gtk_widget_create_pango_layout(GTK_WIDGET(editor), text.c_str());
  }
  bool focused() const {
    auto *widget = GTK_WIDGET(editor);
    auto *window = gtk_widget_get_toplevel(widget);
    return gtk_widget_get_mapped(widget) && gtk_widget_has_focus(widget) &&
      gtk_text_view_get_editable(editor) && GTK_IS_WINDOW(window) &&
      gtk_window_is_active(GTK_WINDOW(window));
  }
  bool capacity() const {
    g_autoptr(PangoLayout) minimum = layout("1 中…");
    int width = 0;
    pango_layout_get_pixel_size(minimum, &width, nullptr);
    const auto available = gtk_widget_get_allocated_width(scroll) - left - right;
    return available >= width + navigation && gtk_widget_get_allocated_height(scroll) >= pitch &&
      (!reserve || gtk_widget_get_allocated_height(box) >= pitch * 2 + 6);
  }
  void metrics() {
    g_autoptr(PangoLayout) sample = layout("中Mg");
    pango_layout_get_pixel_size(sample, nullptr, &pitch);
    pitch = std::max(1, pitch + gtk_text_view_get_pixels_above_lines(editor) +
      gtk_text_view_get_pixels_below_lines(editor));
    left = gtk_text_view_get_left_margin(editor);
    right = gtk_text_view_get_right_margin(editor);
    gap = std::max(4.0, pitch * .6);
    g_autoptr(PangoLayout) arrows = layout("‹  ›");
    int width = 0;
    pango_layout_get_pixel_size(arrows, &width, nullptr);
    navigation = std::max(pitch * 2.5, width + gap);
  }
  void refresh() {
    const bool was_reserved = reserve;
    const bool redraw = dirty;
    if (dirty) metrics();
    if (!snapshot.rows.empty()) reserve = true;
    else if (!lease->accepted() || (!composing &&
      gtk_text_buffer_get_char_count(gtk_text_view_get_buffer(editor)) == 0)) reserve = false;
    if (dirty) {
      std::vector<double> widths;
      size_t selected = manual ? requested : 0;
      for (size_t i = 0; i < snapshot.rows.size(); ++i) {
        g_autoptr(PangoLayout) text = layout(label(snapshot.rows[i]));
        int width = 0;
        pango_layout_get_pixel_size(text, &width, nullptr);
        widths.push_back(width);
        if (!manual && snapshot.rows[i].index == snapshot.cursor) selected = i;
      }
      page = candidate_page(widths,
        gtk_widget_get_allocated_width(scroll) - left - right - navigation, gap, selected);
      gtk_widget_set_size_request(row, -1, pitch + 6);
      dirty = false;
    }
    gtk_widget_set_visible(row, reserve);
    if (redraw || was_reserved != reserve) gtk_widget_queue_draw(row);
  }
  void lost_focus() {
    reserve = false;
    if (engaged) { engaged = false; lease->release(); }
    gtk_widget_hide(row);
  }
  void tick() {
    if (dirty) metrics();
    if (!focused() || !capacity()) { lost_focus(); return; }
    engaged = true;
    lease->update(true, !composing);
    refresh();
  }
  void draw(cairo_t *cr) {
    if (!focused() || snapshot.rows.empty()) return;
    if (!capacity() || gtk_widget_get_allocated_height(row) < pitch || page.widths.empty()) {
      lost_focus();
      return;
    }
    GdkRGBA color;
    gtk_style_context_get_color(gtk_widget_get_style_context(GTK_WIDGET(editor)), GTK_STATE_FLAG_NORMAL, &color);
    gdk_cairo_set_source_rgba(cr, &color);
    double x = left;
    for (size_t i = page.start; i < page.end; ++i) {
      const auto &candidate = snapshot.rows[i];
      const auto text = label(candidate);
      g_autoptr(PangoLayout) word = layout(text);
      pango_layout_set_width(word, static_cast<int>(page.widths[i - page.start] * PANGO_SCALE));
      pango_layout_set_ellipsize(word, PANGO_ELLIPSIZE_END);
      auto *attributes = pango_attr_list_new();
      const auto split = text.find("\u2009");
      const auto begin = split == std::string::npos ? 0 : split + 3;
      if (begin) {
        auto *muted = pango_attr_foreground_alpha_new(42598);
        muted->end_index = begin;
        pango_attr_list_insert(attributes, muted);
      }
      if (candidate.index == snapshot.cursor) {
        auto *underline = pango_attr_underline_new(PANGO_UNDERLINE_SINGLE);
        underline->start_index = begin;
        pango_attr_list_insert(attributes, underline);
      }
      pango_layout_set_attributes(word, attributes);
      pango_attr_list_unref(attributes);
      int height = 0;
      pango_layout_get_pixel_size(word, nullptr, &height);
      cairo_move_to(cr, x, std::max(0, pitch - height) / 2.0);
      pango_cairo_show_layout(cr, word);
      x += page.widths[i - page.start] + gap;
    }
    if (page.start > 0 || page.end < snapshot.rows.size() || snapshot.previous || snapshot.next) {
      g_autoptr(PangoLayout) arrows = layout("‹  ›");
      cairo_move_to(cr, gtk_widget_get_allocated_width(scroll) - right - navigation, 0);
      pango_cairo_show_layout(cr, arrows);
    }
    lease->rendered(snapshot.token, snapshot.serial);
  }
  void click(double x, double y) {
    if (!focused() || !lease->accepted() || y < 0 || y > pitch) return;
    double left_edge = left;
    for (size_t i = page.start; i < page.end; ++i) {
      const double width = page.widths[i - page.start];
      if (x >= left_edge && x < left_edge + width) {
        lease->select(snapshot.token, snapshot.serial, snapshot.rows[i].index);
        return;
      }
      left_edge += width + gap;
    }
    const double nav = gtk_widget_get_allocated_width(scroll) - right - navigation;
    if (x < nav || x > nav + navigation) return;
    const bool next = x >= nav + navigation / 2;
    if (next && page.end < snapshot.rows.size()) requested = page.end;
    else if (!next && page.start > 0) requested = page.start - 1;
    else { lease->page(snapshot.token, snapshot.serial, next); return; }
    manual = dirty = true;
    refresh();
  }
};
}
GtkWidget *wrap_gtk_candidates(GtkTextView *editor, GtkWidget *scroll) {
  auto *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  auto *row = gtk_drawing_area_new();
  gtk_widget_set_can_focus(row, FALSE);
  gtk_widget_set_no_show_all(row, TRUE);
  gtk_widget_add_events(row, GDK_BUTTON_PRESS_MASK);
  gtk_box_pack_start(GTK_BOX(box), scroll, TRUE, TRUE, 0);
  gtk_box_pack_start(GTK_BOX(box), row, FALSE, FALSE, 0);
  auto *panel = new GtkCandidates{editor, row, scroll, box, {}, {}, {}};
  g_object_ref(editor);
  g_object_ref(row);
  g_object_ref(scroll);
  panel->lease = CandidateLease::create([panel](const CandidateSnapshot &snapshot) {
    panel->snapshot = snapshot;
    panel->manual = false;
    panel->dirty = true;
    panel->refresh();
  });
  g_signal_connect(row, "draw", G_CALLBACK(+[](GtkWidget *, cairo_t *cr, gpointer data) -> gboolean {
    static_cast<GtkCandidates *>(data)->draw(cr); return FALSE;
  }), panel);
  g_signal_connect(row, "button-press-event", G_CALLBACK(+[](GtkWidget *, GdkEventButton *event, gpointer data) -> gboolean {
    if (event->button != 1) return FALSE;
    static_cast<GtkCandidates *>(data)->click(event->x, event->y); return TRUE;
  }), panel);
  g_signal_connect(editor, "preedit-changed", G_CALLBACK(+[](GtkTextView *, const gchar *text, gpointer data) {
    auto *panel = static_cast<GtkCandidates *>(data);
    panel->composing = text && *text;
  }), panel);
  g_signal_connect(editor, "focus-out-event", G_CALLBACK(+[](GtkWidget *, GdkEventFocus *, gpointer data) -> gboolean {
    static_cast<GtkCandidates *>(data)->lost_focus(); return FALSE;
  }), panel);
  g_signal_connect(editor, "unmap", G_CALLBACK(+[](GtkWidget *, gpointer data) {
    static_cast<GtkCandidates *>(data)->lost_focus();
  }), panel);
  g_signal_connect(editor, "style-updated", G_CALLBACK(+[](GtkWidget *, gpointer data) {
    static_cast<GtkCandidates *>(data)->dirty = true;
  }), panel);
  g_signal_connect(editor, "size-allocate", G_CALLBACK(+[](GtkWidget *, GtkAllocation *, gpointer data) {
    static_cast<GtkCandidates *>(data)->dirty = true;
  }), panel);
  panel->timer = g_timeout_add(100, +[](gpointer data) -> gboolean {
    static_cast<GtkCandidates *>(data)->tick(); return G_SOURCE_CONTINUE;
  }, panel);
  g_object_set_data_full(G_OBJECT(box), "rapp-candidates", panel, +[](gpointer data) {
    delete static_cast<GtkCandidates *>(data);
  });
  return box;
}
}
