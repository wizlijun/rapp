#include "rapp_windows.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace {
FlValue *get(FlValue *m, const char *k) {
  return m && fl_value_get_type(m) == FL_VALUE_TYPE_MAP
             ? fl_value_lookup_string(m, k)
             : nullptr;
}
const char *text(FlValue *v) {
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(v)
             : "";
}
int64_t integer(FlValue *v) {
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_INT ? fl_value_get_int(v)
                                                        : 0;
}
double number(FlValue *v) {
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT
             ? fl_value_get_float(v)
             : integer(v);
}
void put(FlValue *m, const char *k, FlValue *v) {
  fl_value_set_string_take(m, k, v);
}
void setint(FlValue *m, const char *k, int64_t v) {
  put(m, k, fl_value_new_int(v));
}
void settext(FlValue *m, const char *k, const std::string &v) {
  put(m, k, fl_value_new_string(v.c_str()));
}
struct Session;
struct Window {
  Session *session;
  int id = 0, parent = 0;
  bool popup = false, resizable = false;
  double x = 0, y = 0, w = 1, h = 1, bar = 0;
  GtkWidget *shell = nullptr, *area = nullptr, *chips = nullptr,
            *status = nullptr, *menubar = nullptr, *tools = nullptr;
  guint resize_timer = 0;
  int aw = 0, ah = 0;
  bool allocated = false;
  std::map<guint, int> held;
  ~Window();
};
struct Block {
  int n;
  std::string label;
};
struct Session {
  FlMethodChannel *channel;
  GtkWindow *main;
  int64_t sid;
  bool closing = false, disconnected = false, sending = false;
  std::map<int, std::unique_ptr<Window>> windows;
  GtkTextBuffer *buffer = gtk_text_buffer_new(nullptr);
  std::vector<Block> blocks, sent_blocks;
  std::string sent_text, status;
  cairo_surface_t *surface = nullptr;
  std::vector<guint8> pixels;
  double x = 0, y = 0, w = 1, h = 1;
  int selected = 0;
  FlValue *menus = nullptr;
  FlValue *clips = nullptr;
  std::string mode = "color16", density = "adaptive";
  int fps = 15;
  ~Session() {
    closing = true;
    windows.clear();
    if (surface)
      cairo_surface_destroy(surface);
    if (menus)
      fl_value_unref(menus);
    if (clips)
      fl_value_unref(clips);
    g_object_unref(buffer);
  }
  void emit(const char *method, FlValue *args = nullptr) {
    if (closing)
      return;
    if (!args)
      args = fl_value_new_map();
    setint(args, "sid", sid);
    fl_method_channel_invoke_method(channel, method, args, nullptr, nullptr,
                                    nullptr);
    fl_value_unref(args);
  }
  std::string draft() {
    GtkTextIter a, b;
    gtk_text_buffer_get_bounds(buffer, &a, &b);
    gchar *s = gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
    std::string out = s;
    g_free(s);
    return out;
  }
};
Window::~Window() {
  if (resize_timer)
    g_source_remove(resize_timer);
  if (shell) {
    gtk_widget_destroy(shell);
    g_object_unref(shell);
  }
}
FlValue *window_args(Window *w) {
  auto *a = fl_value_new_map();
  setint(a, "window", w->id);
  return a;
}
int keycode(guint key) {
  key = gdk_keyval_to_lower(key);
  const int letters[] = {0,  11, 8,  2,  14, 3, 5,  4,  34, 38, 40, 37, 46,
                         45, 31, 35, 12, 15, 1, 17, 32, 9,  13, 7,  16, 6};
  if (key >= 'a' && key <= 'z')
    return letters[key - 'a'];
  const std::map<guint, int> keys = {{'1', 18},
                                     {'2', 19},
                                     {'3', 20},
                                     {'4', 21},
                                     {'5', 23},
                                     {'6', 22},
                                     {'7', 26},
                                     {'8', 28},
                                     {'9', 25},
                                     {'0', 29},
                                     {' ', 49},
                                     {'-', 27},
                                     {'=', 24},
                                     {'[', 33},
                                     {']', 30},
                                     {'\\', 42},
                                     {';', 41},
                                     {'\'', 39},
                                     {'`', 50},
                                     {',', 43},
                                     {'.', 47},
                                     {'/', 44},
                                     {GDK_KEY_Return, 36},
                                     {GDK_KEY_KP_Enter, 76},
                                     {GDK_KEY_Escape, 53},
                                     {GDK_KEY_BackSpace, 51},
                                     {GDK_KEY_Tab, 48},
                                     {GDK_KEY_ISO_Left_Tab, 48},
                                     {GDK_KEY_Left, 123},
                                     {GDK_KEY_Right, 124},
                                     {GDK_KEY_Down, 125},
                                     {GDK_KEY_Up, 126},
                                     {GDK_KEY_Home, 115},
                                     {GDK_KEY_End, 119},
                                     {GDK_KEY_Page_Up, 116},
                                     {GDK_KEY_Page_Down, 121},
                                     {GDK_KEY_Delete, 117},
                                     {GDK_KEY_F1, 122},
                                     {GDK_KEY_F2, 120},
                                     {GDK_KEY_F3, 99},
                                     {GDK_KEY_F4, 118},
                                     {GDK_KEY_F5, 96},
                                     {GDK_KEY_F6, 97},
                                     {GDK_KEY_F7, 98},
                                     {GDK_KEY_F8, 100},
                                     {GDK_KEY_F9, 101},
                                     {GDK_KEY_F10, 109},
                                     {GDK_KEY_F12, 111}};
  auto it = keys.find(key);
  return it == keys.end() ? -1 : it->second;
}
void key(Session *s, int code, int mods, bool down) {
  auto *a = fl_value_new_map();
  setint(a, "keyCode", code);
  setint(a, "modifiers", mods);
  put(a, "down", fl_value_new_bool(down));
  s->emit("key", a);
}
int modifiers(guint state) {
  return (state & GDK_SHIFT_MASK ? 1 << 17 : 0) |
         (state & GDK_CONTROL_MASK ? 1 << 20 : 0) |
         (state & GDK_MOD1_MASK ? 1 << 19 : 0);
}
void release(Window *w) {
  for (auto held : w->held)
    key(w->session, held.second, 0, false);
  w->held.clear();
}
void coords(Window *w, double x, double y, double &rx, double &ry) {
  const double scale =
      std::min(gtk_widget_get_allocated_width(w->area) / w->w,
               gtk_widget_get_allocated_height(w->area) / (w->h - w->bar));
  const double ox =
      (gtk_widget_get_allocated_width(w->area) - w->w * scale) / 2;
  const double oy =
      (gtk_widget_get_allocated_height(w->area) - (w->h - w->bar) * scale) / 2;
  rx = std::clamp((x - ox) / scale, 0., w->w);
  ry = std::clamp((y - oy) / scale + w->bar, w->bar, w->h);
}
void mouse(Window *w, const char *kind, guint button, double x, double y,
           int clicks) {
  if (w->session->disconnected)
    return;
  auto *a = window_args(w);
  double rx, ry;
  coords(w, x, y, rx, ry);
  settext(a, "kind", kind);
  settext(a, "button", button == 3 ? "right" : "left");
  put(a, "x", fl_value_new_float(rx));
  put(a, "y", fl_value_new_float(ry));
  setint(a, "clicks", clicks);
  w->session->emit("mouse", a);
}
void refresh_chips(Session *s);
void send_draft(Session *s) {
  if (s->sending || s->disconnected)
    return;
  auto draft = s->draft();
  if (draft.empty() && s->blocks.empty()) {
    key(s, 36, 0, true);
    key(s, 36, 0, false);
    return;
  }
  s->sending = true;
  s->sent_text = draft;
  s->sent_blocks = s->blocks;
  auto *a = fl_value_new_map();
  auto *pieces = fl_value_new_list();
  for (auto &b : s->blocks) {
    auto *p = fl_value_new_map();
    setint(p, "block", b.n);
    fl_value_append_take(pieces, p);
  }
  if (!draft.empty()) {
    auto *p = fl_value_new_map();
    settext(p, "text", draft);
    fl_value_append_take(pieces, p);
  }
  put(a, "pieces", pieces);
  settext(a, "text", draft);
  s->emit("composer_send", a);
}
void refresh_chips(Session *s) {
  for (auto &entry : s->windows) {
    Window *w = entry.second.get();
    if (!w->chips)
      continue;
    GList *children = gtk_container_get_children(GTK_CONTAINER(w->chips));
    for (GList *c = children; c; c = c->next)
      gtk_widget_destroy(GTK_WIDGET(c->data));
    g_list_free(children);
    for (const auto &b : s->blocks) {
      auto *button = gtk_button_new_with_label((b.label + " ×").c_str());
      g_object_set_data(G_OBJECT(button), "block", GINT_TO_POINTER(b.n));
      g_signal_connect(
          button, "clicked",
          reinterpret_cast<GCallback>(+[](GtkButton *button, gpointer data) {
            auto *s = static_cast<Session *>(data);
            int n =
                GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "block"));
            s->blocks.erase(
                std::remove_if(s->blocks.begin(), s->blocks.end(),
                               [n](const Block &b) { return b.n == n; }),
                s->blocks.end());
            auto *a = fl_value_new_map();
            setint(a, "block", n);
            s->emit("composer_drop_block", a);
            refresh_chips(s);
          }),
          s);
      gtk_box_pack_start(GTK_BOX(w->chips), button, FALSE, FALSE, 0);
    }
    gtk_widget_show_all(w->chips);
  }
}
void drop_files(GtkWidget *, GdkDragContext *context, gint, gint,
                GtkSelectionData *data, guint, guint time, gpointer opaque) {
  auto *s = static_cast<Session *>(opaque);
  auto *a = fl_value_new_map();
  auto *files = fl_value_new_list();
  gchar **uris = gtk_selection_data_get_uris(data);
  if (uris) {
    for (int i = 0; uris[i]; i++) {
      gchar *f = g_filename_from_uri(uris[i], nullptr, nullptr);
      if (f) {
        fl_value_append_take(files, fl_value_new_string(f));
        g_free(f);
      }
    }
    g_strfreev(uris);
  }
  const bool ok = fl_value_get_length(files) > 0;
  put(a, "files", files);
  s->emit("drop_files", a);
  gtk_drag_finish(context, ok, FALSE, time);
}
void install_drop(GtkWidget *widget, Session *s) {
  GtkTargetEntry types[] = {{const_cast<char *>("text/uri-list"), 0, 0}};
  gtk_drag_dest_set(widget, GTK_DEST_DEFAULT_ALL, types, 1, GDK_ACTION_COPY);
  g_signal_connect(widget, "drag-data-received",
                   reinterpret_cast<GCallback>(drop_files), s);
}
void fill_menu(GtkWidget *menu, FlValue *items, Session *s,
               const std::vector<int> &prefix) {
  if (!items || fl_value_get_type(items) != FL_VALUE_TYPE_LIST)
    return;
  for (size_t i = 0; i < fl_value_get_length(items); i++) {
    auto *m = fl_value_get_list_value(items, i);
    auto *sep = get(m, "separator");
    auto *item = sep && fl_value_get_bool(sep)
                     ? gtk_separator_menu_item_new()
                     : gtk_menu_item_new_with_label(text(get(m, "title")));
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    auto *enabled = get(m, "enabled");
    if (enabled)
      gtk_widget_set_sensitive(item, fl_value_get_bool(enabled));
    auto path = prefix;
    path.push_back(i);
    auto *children = get(m, "children");
    if (children && fl_value_get_length(children) > 0) {
      auto *sub = gtk_menu_new();
      fill_menu(sub, children, s, path);
      gtk_menu_item_set_submenu(GTK_MENU_ITEM(item), sub);
    } else {
      auto *payload = fl_value_new_list();
      for (int index : path)
        fl_value_append_take(payload, fl_value_new_int(index));
      g_object_set_data_full(G_OBJECT(item), "path", payload,
                             reinterpret_cast<GDestroyNotify>(fl_value_unref));
      g_signal_connect(
          item, "activate",
          reinterpret_cast<GCallback>(+[](GtkMenuItem *item, gpointer data) {
            auto *a = fl_value_new_map();
            put(a, "path",
                fl_value_ref(static_cast<FlValue *>(
                    g_object_get_data(G_OBJECT(item), "path"))));
            static_cast<Session *>(data)->emit("menu_pick", a);
          }),
          s);
    }
  }
}
void menus(Window *w) {
  if (!w->menubar)
    return;
  GList *list = gtk_container_get_children(GTK_CONTAINER(w->menubar));
  for (GList *i = list; i; i = i->next)
    gtk_widget_destroy(GTK_WIDGET(i->data));
  g_list_free(list);
  fill_menu(w->menubar, w->session->menus, w->session, {});
  gtk_widget_show_all(w->menubar);
}
void tool_item(GtkWidget *menu, const char *label, Session *s,
               const char *method, FlValue *args) {
  auto *item = gtk_menu_item_new_with_label(label);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
  g_object_set_data_full(G_OBJECT(item), "args", args,
                         reinterpret_cast<GDestroyNotify>(fl_value_unref));
  g_object_set_data_full(G_OBJECT(item), "method", g_strdup(method), g_free);
  g_signal_connect(
      item, "activate",
      reinterpret_cast<GCallback>(+[](GtkMenuItem *item, gpointer p) {
        auto *args =
            static_cast<FlValue *>(g_object_get_data(G_OBJECT(item), "args"));
        static_cast<Session *>(p)->emit(
            static_cast<const char *>(
                g_object_get_data(G_OBJECT(item), "method")),
            fl_value_ref(args));
      }),
      s);
}
void tools_menu(Window *w) {
  if (!w->tools)
    return;
  auto *s = w->session;
  auto *menu = gtk_menu_new();
  auto choice = [&](const char *label, const char *mode, const char *density,
                    int fps) {
    auto *a = fl_value_new_map();
    settext(a, "mode", mode);
    settext(a, "density", density);
    setint(a, "fps", fps);
    tool_item(menu, label, s, "set_stream", a);
  };
  choice("最省流", "duogray", "adaptive", 1);
  choice("最清晰", "color16", "original", 15);
  const std::pair<const char *, const char *> modes[] = {
      {"duogray", "双色 · 灰度"},
      {"duocolor", "双色 · 彩色"},
      {"color16", "高彩"}};
  for (const auto &value : modes)
    choice((std::string(value.first == s->mode ? "✓ " : "") + value.second)
               .c_str(),
           value.first, s->density.c_str(), s->fps);
  const std::pair<const char *, const char *> densities[] = {
      {"saver1x", "省流"}, {"adaptive", "自适应"}, {"original", "原画"}};
  for (const auto &value : densities)
    choice((std::string(value.first == s->density ? "✓ " : "") + value.second)
               .c_str(),
           s->mode.c_str(), value.first, s->fps);
  for (int fps : {1, 5, 15, 30})
    choice(
        (std::string(fps == s->fps ? "✓ " : "") + std::to_string(fps) + " fps")
            .c_str(),
        s->mode.c_str(), s->density.c_str(), fps);
  auto *a = fl_value_new_map();
  setint(a, "window", w->id);
  tool_item(menu, "把远端窗口移到左上角", s, "move_top_left", a);
  auto *history = gtk_menu_item_new_with_label("远端剪贴板");
  auto *sub = gtk_menu_new();
  gtk_menu_item_set_submenu(GTK_MENU_ITEM(history), sub);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), history);
  if (s->clips)
    for (size_t i = 0; i < fl_value_get_length(s->clips); i++) {
      auto *c = fl_value_get_list_value(s->clips, i);
      auto *item = gtk_menu_item_new_with_label(text(get(c, "title")));
      gtk_menu_shell_append(GTK_MENU_SHELL(sub), item);
      auto *actions = gtk_menu_new();
      gtk_menu_item_set_submenu(GTK_MENU_ITEM(item), actions);
      gtk_widget_set_sensitive(item, fl_value_get_bool(get(c, "pickable")));
      for (bool insert : {false, true}) {
        auto *args = fl_value_new_map();
        setint(args, "clip", integer(get(c, "id")));
        put(args, "insert", fl_value_new_bool(insert));
        tool_item(actions, insert ? "插入到输入区" : "复制到本机", s,
                  "clip_pick", args);
      }
    }
  gtk_widget_show_all(menu);
  gtk_menu_button_set_popup(GTK_MENU_BUTTON(w->tools), menu);
}
std::unique_ptr<Window> create_window(Session *s, int id, bool popup,
                                      Window *parent) {
  auto w = std::make_unique<Window>();
  w->session = s;
  w->id = id;
  w->popup = popup;
  w->area = gtk_drawing_area_new();
  gtk_widget_set_can_focus(w->area, TRUE);
  gtk_widget_add_events(w->area,
                        GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
                            GDK_POINTER_MOTION_MASK | GDK_SCROLL_MASK |
                            GDK_SMOOTH_SCROLL_MASK | GDK_KEY_PRESS_MASK |
                            GDK_KEY_RELEASE_MASK | GDK_FOCUS_CHANGE_MASK);
  if (popup) {
    w->shell = gtk_popover_new(parent->area);
    gtk_popover_set_modal(GTK_POPOVER(w->shell), FALSE);
    gtk_popover_set_position(GTK_POPOVER(w->shell), GTK_POS_BOTTOM);
    gtk_container_add(GTK_CONTAINER(w->shell), w->area);
  } else {
    w->shell = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_application(GTK_WINDOW(w->shell),
                               gtk_window_get_application(s->main));
    auto *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(w->shell), root);
    w->menubar = gtk_menu_bar_new();
    gtk_box_pack_start(GTK_BOX(root), w->menubar, FALSE, FALSE, 0);
    auto *toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_pack_start(GTK_BOX(root), toolbar, FALSE, FALSE, 0);
    auto *attach = gtk_button_new_with_label("放回主窗口");
    gtk_box_pack_start(GTK_BOX(toolbar), attach, FALSE, FALSE, 0);
    g_signal_connect(attach, "clicked",
                     reinterpret_cast<GCallback>(+[](GtkButton *, gpointer p) {
                       static_cast<Session *>(p)->emit("attach");
                     }),
                     s);
    auto *copy = gtk_button_new_with_label("复制");
    gtk_box_pack_start(GTK_BOX(toolbar), copy, FALSE, FALSE, 0);
    g_signal_connect(copy, "clicked",
                     reinterpret_cast<GCallback>(+[](GtkButton *, gpointer p) {
                       auto *s = static_cast<Session *>(p);
                       key(s, 8, 1 << 20, true);
                       key(s, 8, 1 << 20, false);
                     }),
                     s);
    auto *file = gtk_button_new_with_label("附件");
    gtk_box_pack_start(GTK_BOX(toolbar), file, FALSE, FALSE, 0);
    g_signal_connect(file, "clicked",
                     reinterpret_cast<GCallback>(+[](GtkButton *, gpointer p) {
                       static_cast<Session *>(p)->emit("composer_attach");
                     }),
                     s);
    w->tools = gtk_menu_button_new();
    gtk_button_set_label(GTK_BUTTON(w->tools), "画质 / 剪贴板");
    gtk_box_pack_start(GTK_BOX(toolbar), w->tools, FALSE, FALSE, 0);
    auto *cancel = gtk_button_new_with_label("取消传输");
    gtk_box_pack_start(GTK_BOX(toolbar), cancel, FALSE, FALSE, 0);
    g_signal_connect(cancel, "clicked",
                     reinterpret_cast<GCallback>(+[](GtkButton *, gpointer p) {
                       static_cast<Session *>(p)->emit("cancel_transfer");
                     }),
                     s);
    gtk_box_pack_start(GTK_BOX(root), w->area, TRUE, TRUE, 0);
    w->chips = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_pack_start(GTK_BOX(root), w->chips, FALSE, FALSE, 0);
    auto *input = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_pack_start(GTK_BOX(root), input, FALSE, FALSE, 0);
    auto *scroll = gtk_scrolled_window_new(nullptr, nullptr);
    gtk_widget_set_size_request(scroll, -1, 60);
    gtk_box_pack_start(GTK_BOX(input), scroll, TRUE, TRUE, 0);
    auto *editor = gtk_text_view_new_with_buffer(s->buffer);
    gtk_container_add(GTK_CONTAINER(scroll), editor);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(editor), GTK_WRAP_WORD_CHAR);
    g_signal_connect(
        editor, "paste-clipboard",
        reinterpret_cast<GCallback>(+[](GtkTextView *v, gpointer p) {
          g_signal_stop_emission_by_name(v, "paste-clipboard");
          static_cast<Session *>(p)->emit("composer_paste");
        }),
        s);
    g_signal_connect(
        editor, "key-press-event",
        reinterpret_cast<GCallback>(+[](GtkWidget *v, GdkEventKey *e,
                                        gpointer p) -> gboolean {
          if (e->keyval == GDK_KEY_Return || e->keyval == GDK_KEY_KP_Enter) {
            if (gtk_text_view_im_context_filter_keypress(GTK_TEXT_VIEW(v), e))
              return TRUE;
            if (!(e->state & GDK_SHIFT_MASK)) {
              send_draft(static_cast<Session *>(p));
              return TRUE;
            }
          }
          auto *s = static_cast<Session *>(p);
          if ((e->state & GDK_CONTROL_MASK) &&
              gdk_keyval_to_lower(e->keyval) == GDK_KEY_q) {
            s->emit("close");
            return TRUE;
          }
          if ((e->state & GDK_CONTROL_MASK) &&
              gdk_keyval_to_lower(e->keyval) == GDK_KEY_v)
            return FALSE;
          if (s->draft().empty() &&
              !(e->state & (GDK_SUPER_MASK | GDK_META_MASK)) &&
              ((e->state & GDK_CONTROL_MASK) || e->keyval == GDK_KEY_Tab ||
               (e->keyval >= GDK_KEY_Home && e->keyval <= GDK_KEY_Down) ||
               e->keyval == GDK_KEY_Escape || e->keyval == GDK_KEY_BackSpace)) {
            int code = keycode(e->keyval);
            if (code >= 0) {
              key(s, code, modifiers(e->state), true);
              key(s, code, modifiers(e->state), false);
              return TRUE;
            }
          }
          return FALSE;
        }),
        s);
    install_drop(editor, s);
    auto *send = gtk_button_new_with_label("发送 ⏎");
    gtk_box_pack_start(GTK_BOX(input), send, FALSE, FALSE, 0);
    g_signal_connect(send, "clicked",
                     reinterpret_cast<GCallback>(+[](GtkButton *, gpointer p) {
                       send_draft(static_cast<Session *>(p));
                     }),
                     s);
    w->status = gtk_label_new(s->status.c_str());
    gtk_box_pack_start(GTK_BOX(root), w->status, FALSE, FALSE, 0);
    g_signal_connect(w->shell, "delete-event",
                     reinterpret_cast<GCallback>(
                         +[](GtkWidget *, GdkEvent *, gpointer p) -> gboolean {
                           static_cast<Session *>(p)->emit("close");
                           return TRUE;
                         }),
                     s);
  }
  g_object_ref_sink(w->shell);
  auto *raw = w.get();
  if (!popup)
    g_signal_connect(w->shell, "focus-in-event",
                     reinterpret_cast<GCallback>(
                         +[](GtkWidget *, GdkEvent *, gpointer p) -> gboolean {
                           auto *w = static_cast<Window *>(p);
                           w->session->selected = w->id;
                           w->session->emit("select_window", window_args(w));
                           return FALSE;
                         }),
                     raw);
  g_signal_connect(
      w->area, "draw",
      reinterpret_cast<GCallback>(+[](GtkWidget *widget, cairo_t *cr,
                                      gpointer p) -> gboolean {
        auto *w = static_cast<Window *>(p);
        auto *s = w->session;
        cairo_set_source_rgb(cr, .035, .035, .04);
        cairo_paint(cr);
        if (!s->surface)
          return TRUE;
        double z =
            std::min(gtk_widget_get_allocated_width(widget) / w->w,
                     gtk_widget_get_allocated_height(widget) / (w->h - w->bar));
        cairo_translate(
            cr, (gtk_widget_get_allocated_width(widget) - w->w * z) / 2,
            (gtk_widget_get_allocated_height(widget) - (w->h - w->bar) * z) /
                2);
        cairo_rectangle(cr, 0, 0, w->w * z, (w->h - w->bar) * z);
        cairo_clip(cr);
        cairo_scale(cr, z, z);
        cairo_translate(cr, s->x - w->x, s->y - w->y - w->bar);
        cairo_scale(cr, s->w / cairo_image_surface_get_width(s->surface),
                    s->h / cairo_image_surface_get_height(s->surface));
        cairo_set_source_surface(cr, s->surface, 0, 0);
        cairo_paint(cr);
        return TRUE;
      }),
      raw);
  g_signal_connect(
      w->area, "button-press-event",
      reinterpret_cast<GCallback>(
          +[](GtkWidget *widget, GdkEventButton *e, gpointer p) -> gboolean {
            auto *w = static_cast<Window *>(p);
            if (e->button != 1 && e->button != 3)
              return FALSE;
            gtk_widget_grab_focus(widget);
            w->session->selected = w->id;
            w->session->emit("select_window", window_args(w));
            mouse(w, "down", e->button, e->x, e->y,
                  e->type == GDK_2BUTTON_PRESS   ? 2
                  : e->type == GDK_3BUTTON_PRESS ? 3
                                                 : 1);
            return TRUE;
          }),
      raw);
  g_signal_connect(
      w->area, "button-release-event",
      reinterpret_cast<GCallback>(
          +[](GtkWidget *, GdkEventButton *e, gpointer p) -> gboolean {
            mouse(static_cast<Window *>(p), "up", e->button, e->x, e->y, 1);
            return TRUE;
          }),
      raw);
  g_signal_connect(
      w->area, "motion-notify-event",
      reinterpret_cast<GCallback>(
          +[](GtkWidget *, GdkEventMotion *e, gpointer p) -> gboolean {
            mouse(static_cast<Window *>(p),
                  (e->state & (GDK_BUTTON1_MASK | GDK_BUTTON3_MASK)) ? "drag"
                                                                     : "move",
                  e->state & GDK_BUTTON3_MASK ? 3 : 1, e->x, e->y, 1);
            return TRUE;
          }),
      raw);
  g_signal_connect(
      w->area, "scroll-event",
      reinterpret_cast<GCallback>(+[](GtkWidget *, GdkEventScroll *e,
                                      gpointer p) -> gboolean {
        auto *w = static_cast<Window *>(p);
        double dx = 0, dy = 0;
        gdk_event_get_scroll_deltas(reinterpret_cast<GdkEvent *>(e), &dx, &dy);
        if (e->direction == GDK_SCROLL_UP)
          dy = -1;
        if (e->direction == GDK_SCROLL_DOWN)
          dy = 1;
        if (e->direction == GDK_SCROLL_LEFT)
          dx = -1;
        if (e->direction == GDK_SCROLL_RIGHT)
          dx = 1;
        auto *a = window_args(w);
        double x, y;
        coords(w, e->x, e->y, x, y);
        put(a, "x", fl_value_new_float(x));
        put(a, "y", fl_value_new_float(y));
        put(a, "dx", fl_value_new_float(-dx * 10));
        put(a, "dy", fl_value_new_float(-dy * 10));
        w->session->emit("scroll", a);
        return TRUE;
      }),
      raw);
  g_signal_connect(w->area, "key-press-event",
                   reinterpret_cast<GCallback>(+[](GtkWidget *, GdkEventKey *e,
                                                   gpointer p) -> gboolean {
                     auto *w = static_cast<Window *>(p);
                     if (w->session->disconnected ||
                         e->state & (GDK_SUPER_MASK | GDK_META_MASK))
                       return FALSE;
                     if ((e->state & GDK_CONTROL_MASK) &&
                         gdk_keyval_to_lower(e->keyval) == GDK_KEY_q) {
                       w->session->emit("close");
                       return TRUE;
                     }
                     if (e->keyval == GDK_KEY_F11 && !w->popup) {
                       GdkWindow *gw = gtk_widget_get_window(w->shell);
                       if (gdk_window_get_state(gw) &
                           GDK_WINDOW_STATE_FULLSCREEN)
                         gtk_window_unfullscreen(GTK_WINDOW(w->shell));
                       else
                         gtk_window_fullscreen(GTK_WINDOW(w->shell));
                       return TRUE;
                     }
                     int c = keycode(e->keyval);
                     if (c < 0)
                       return FALSE;
                     w->held[e->hardware_keycode] = c;
                     key(w->session, c, modifiers(e->state), true);
                     return TRUE;
                   }),
                   raw);
  g_signal_connect(w->area, "key-release-event",
                   reinterpret_cast<GCallback>(+[](GtkWidget *, GdkEventKey *e,
                                                   gpointer p) -> gboolean {
                     auto *w = static_cast<Window *>(p);
                     auto it = w->held.find(e->hardware_keycode);
                     if (it == w->held.end())
                       return FALSE;
                     key(w->session, it->second, modifiers(e->state), false);
                     w->held.erase(it);
                     return TRUE;
                   }),
                   raw);
  g_signal_connect(w->area, "focus-out-event",
                   reinterpret_cast<GCallback>(
                       +[](GtkWidget *, GdkEvent *, gpointer p) -> gboolean {
                         release(static_cast<Window *>(p));
                         return FALSE;
                       }),
                   raw);
  if (!popup)
    g_signal_connect(
        w->area, "size-allocate",
        reinterpret_cast<GCallback>(
            +[](GtkWidget *, GtkAllocation *a, gpointer p) {
              auto *w = static_cast<Window *>(p);
              bool changed =
                  w->allocated && (a->width != w->aw || a->height != w->ah);
              w->allocated = true;
              w->aw = a->width;
              w->ah = a->height;
              if (!changed || !w->resizable || w->session->disconnected)
                return;
              if (w->resize_timer)
                g_source_remove(w->resize_timer);
              w->resize_timer = g_timeout_add(
                  200,
                  +[](gpointer p) -> gboolean {
                    auto *w = static_cast<Window *>(p);
                    w->resize_timer = 0;
                    auto *a = window_args(w);
                    setint(a, "w", w->aw);
                    setint(a, "h", w->ah + w->bar);
                    w->session->emit("resize", a);
                    return G_SOURCE_REMOVE;
                  },
                  w);
            }),
        raw);
  install_drop(w->area, s);
  menus(w.get());
  tools_menu(w.get());
  return w;
}
} // namespace
struct RappWindows {
  FlMethodChannel *channel;
  GtkWindow *main;
  std::map<int64_t, std::unique_ptr<Session>> sessions;
};
RappWindows *rapp_windows_new(FlMethodChannel *channel, GtkWindow *main) {
  return new RappWindows{channel, main, {}};
}
void rapp_windows_free(RappWindows *w) { delete w; }
bool rapp_windows_method(RappWindows *manager, FlMethodCall *call) {
  const std::string method = fl_method_call_get_name(call);
  if (method != "detach" && method != "attach" && method != "windows" &&
      method != "frame" && method != "raise" && method != "menus" &&
      method != "composer_insert" && method != "composer_done" &&
      method != "status" && method != "stream" && method != "clips")
    return false;
  auto *args = fl_method_call_get_args(call);
  auto sid = integer(get(args, "sid"));
  auto found = manager->sessions.find(sid);
  if (method == "detach" && found == manager->sessions.end()) {
    auto s = std::make_unique<Session>();
    s->sid = sid;
    s->channel = manager->channel;
    s->main = manager->main;
    gtk_text_buffer_set_text(s->buffer, text(get(args, "text")), -1);
    auto *bs = get(args, "blocks");
    if (bs)
      for (size_t i = 0; i < fl_value_get_length(bs); i++) {
        auto *b = fl_value_get_list_value(bs, i);
        s->blocks.push_back(
            {static_cast<int>(integer(get(b, "n"))), text(get(b, "label"))});
      }
    g_signal_connect(
        s->buffer, "changed",
        reinterpret_cast<GCallback>(+[](GtkTextBuffer *, gpointer p) {
          auto *s = static_cast<Session *>(p);
          auto *a = fl_value_new_map();
          settext(a, "text", s->draft());
          s->emit("draft", a);
        }),
        s.get());
    manager->sessions[sid] = std::move(s);
    found = manager->sessions.find(sid);
  }
  if (found == manager->sessions.end()) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    return true;
  }
  auto *s = found->second.get();
  if (method == "attach") {
    manager->sessions.erase(found);
    gtk_window_present(manager->main);
  } else if (method == "raise") {
    for (auto &w : s->windows)
      if (!w.second->popup)
        gtk_window_present(GTK_WINDOW(w.second->shell));
  } else if (method == "windows") {
    auto *table = get(args, "windows");
    std::vector<int> ids;
    if (table)
      for (int pass = 0; pass < 2; pass++)
        for (size_t i = 0; i < fl_value_get_length(table); i++) {
          auto *m = fl_value_get_list_value(table, i);
          std::string kind = text(get(m, "kind"));
          bool popup =
              kind != "normal" && kind != "dialog" && kind != "floating";
          if (popup != (pass == 1))
            continue;
          int id = integer(get(m, "id")), parent_id = integer(get(m, "parent"));
          Window *parent = nullptr;
          if (popup) {
            auto it = s->windows.find(parent_id);
            if (it != s->windows.end())
              parent = it->second.get();
            if (!parent)
              continue;
          }
          ids.push_back(id);
          auto it = s->windows.find(id);
          if (it == s->windows.end()) {
            s->windows[id] = create_window(s, id, popup, parent);
            it = s->windows.find(id);
          }
          auto *w = it->second.get();
          bool initial = w->w == 1 && w->h == 1;
          w->parent = parent_id;
          w->x = number(get(m, "x"));
          w->y = number(get(m, "y"));
          w->w = number(get(m, "w"));
          w->h = number(get(m, "h"));
          w->bar = number(get(m, "titleBar"));
          auto *r = get(m, "resizable");
          w->resizable = r && fl_value_get_bool(r);
          if (!popup) {
            gtk_window_set_title(GTK_WINDOW(w->shell), text(get(m, "title")));
            gtk_window_set_resizable(GTK_WINDOW(w->shell), w->resizable);
            if (initial)
              gtk_window_set_default_size(
                  GTK_WINDOW(w->shell),
                  std::clamp(static_cast<int>(w->w), 240, 1200),
                  std::clamp(static_cast<int>(w->h + 130), 240, 900));
          } else {
            GdkRectangle rect{static_cast<int>(w->x - parent->x + w->w / 2),
                              static_cast<int>(w->y - parent->y - parent->bar),
                              1, 1};
            gtk_popover_set_pointing_to(GTK_POPOVER(w->shell), &rect);
            gtk_widget_set_size_request(w->area, w->w, w->h - w->bar);
          }
          gtk_widget_show_all(w->shell);
          gtk_widget_queue_draw(w->area);
        }
    // Destroy popups first; their GTK parent may otherwise destroy them twice.
    for (int pass = 0; pass < 2; pass++)
      for (auto it = s->windows.begin(); it != s->windows.end();) {
        if (it->second->popup == (pass == 0) &&
            std::find(ids.begin(), ids.end(), it->first) == ids.end())
          it = s->windows.erase(it);
        else
          ++it;
      }
    refresh_chips(s);
  } else if (method == "frame") {
    auto *value = get(args, "bytes");
    if (value && fl_value_get_type(value) == FL_VALUE_TYPE_UINT8_LIST &&
        fl_value_get_length(value) >= 24) {
      auto *bytes = fl_value_get_uint8_list(value);
      uint32_t width, height;
      float rect[4];
      memcpy(&width, bytes, 4);
      memcpy(&height, bytes + 4, 4);
      memcpy(rect, bytes + 8, 16);
      if (width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
          fl_value_get_length(value) ==
              24 + static_cast<size_t>(width) * height * 4) {
        if (s->surface)
          cairo_surface_destroy(s->surface);
        s->pixels.assign(bytes + 24, bytes + fl_value_get_length(value));
        s->surface = cairo_image_surface_create_for_data(
            s->pixels.data(), CAIRO_FORMAT_ARGB32, width, height, width * 4);
        s->x = rect[0];
        s->y = rect[1];
        s->w = rect[2];
        s->h = rect[3];
        for (auto &w : s->windows)
          gtk_widget_queue_draw(w.second->area);
      }
    }
  } else if (method == "menus") {
    if (s->menus)
      fl_value_unref(s->menus);
    s->menus = get(args, "items") ? fl_value_ref(get(args, "items")) : nullptr;
    for (auto &w : s->windows)
      menus(w.second.get());
  } else if (method == "stream" || method == "clips") {
    if (method == "stream") {
      s->mode = text(get(args, "mode"));
      s->density = text(get(args, "density"));
      s->fps = integer(get(args, "fps"));
    } else {
      if (s->clips)
        fl_value_unref(s->clips);
      s->clips = fl_value_ref(get(args, "clips"));
    }
    for (auto &w : s->windows)
      tools_menu(w.second.get());
  } else if (method == "status") {
    s->status = text(get(args, "text"));
    auto *disconnected = get(args, "disconnected");
    if (disconnected && fl_value_get_bool(disconnected)) {
      s->disconnected = true;
      for (auto &w : s->windows)
        release(w.second.get());
    }
    for (auto &w : s->windows)
      if (w.second->status)
        gtk_label_set_text(GTK_LABEL(w.second->status), s->status.c_str());
  } else if (method == "composer_insert") {
    gtk_text_buffer_insert_at_cursor(s->buffer, text(get(args, "text")), -1);
    auto *bs = get(args, "blocks");
    if (bs)
      for (size_t i = 0; i < fl_value_get_length(bs); i++) {
        auto *b = fl_value_get_list_value(bs, i);
        s->blocks.push_back(
            {static_cast<int>(integer(get(b, "n"))), text(get(b, "label"))});
      }
    refresh_chips(s);
  } else if (method == "composer_done") {
    int sent = integer(get(args, "sent"));
    int n = std::min(sent, static_cast<int>(s->sent_blocks.size()));
    bool same = s->blocks.size() >= static_cast<size_t>(n);
    for (int i = 0; same && i < n; i++)
      same = s->blocks[i].n == s->sent_blocks[i].n;
    auto draft = s->draft();
    bool text_sent = sent > static_cast<int>(s->sent_blocks.size());
    if (same && (!text_sent ||
                 draft.compare(0, s->sent_text.size(), s->sent_text) == 0)) {
      s->blocks.erase(s->blocks.begin(), s->blocks.begin() + n);
      if (text_sent)
        gtk_text_buffer_set_text(s->buffer,
                                 draft.substr(s->sent_text.size()).c_str(), -1);
    }
    s->status = text(get(args, "failure"));
    for (auto &w : s->windows)
      if (w.second->status)
        gtk_label_set_text(GTK_LABEL(w.second->status), s->status.c_str());
    s->sending = false;
    s->sent_blocks.clear();
    s->sent_text.clear();
    refresh_chips(s);
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
  return true;
}
