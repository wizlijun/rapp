#include "rapp_candidates.h"
#include <map>
#include <cerrno>

namespace rapp {
namespace {
FlValue *get(FlValue *m, const char *key) {
  return m && fl_value_get_type(m) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(m, key) : nullptr;
}
std::string text(FlValue *v) { return v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING ? fl_value_get_string(v) : ""; }
bool boolean(FlValue *v) { return v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(v); }
int64_t integer(FlValue *v) { return v && fl_value_get_type(v) == FL_VALUE_TYPE_INT ? fl_value_get_int(v) : 0; }
void put(FlValue *m, const char *k, FlValue *v) { fl_value_set_string_take(m, k, v); }
struct Editor {
  std::shared_ptr<CandidateLease> lease;
  int64_t epoch = 0;
  bool active = false, capacity = false, composing = false;
  gint64 alive = 0;
};
struct FlutterCandidates {
  FlMethodChannel *channel;
  GtkWidget *view;
  GtkWindow *window;
  std::map<std::string, Editor> editors;
  guint timer = 0;
  gulong activation = 0;
  void sync() {
    auto *focused = gtk_window_get_focus(window);
    const bool native_focus = gtk_window_is_active(window) && gtk_widget_get_mapped(view) &&
      focused && (focused == view || gtk_widget_is_ancestor(focused, view));
    for (auto &item : editors) {
      auto &e = item.second;
      e.lease->update(e.active && e.capacity && native_focus && g_get_monotonic_time() - e.alive < 1500000, !e.composing);
    }
  }
  void changed(const std::string &id, const CandidateSnapshot &snapshot) {
    const auto found = editors.find(id);
    if (found == editors.end()) return;
    g_autoptr(FlValue) args = fl_value_new_map();
    put(args, "editor", fl_value_new_string(id.c_str()));
    put(args, "epoch", fl_value_new_int(found->second.epoch));
    put(args, "token", fl_value_new_string(snapshot.token.c_str()));
    // D-Bus serials are unsigned 64-bit; never narrow them into codec integers.
    put(args, "serial", fl_value_new_string(std::to_string(snapshot.serial).c_str()));
    put(args, "cursor", fl_value_new_int(snapshot.cursor));
    put(args, "previous", fl_value_new_bool(snapshot.previous));
    put(args, "next", fl_value_new_bool(snapshot.next));
    auto *rows = fl_value_new_list();
    for (const auto &row : snapshot.rows) {
      auto *r = fl_value_new_map();
      put(r, "index", fl_value_new_int(row.index));
      put(r, "label", fl_value_new_string(row.label.c_str()));
      put(r, "text", fl_value_new_string(row.text.c_str()));
      fl_value_append_take(rows, r);
    }
    put(args, "rows", rows);
    fl_method_channel_invoke_method(channel, "candidates", args, nullptr, nullptr, nullptr);
  }
  ~FlutterCandidates() {
    if (timer) g_source_remove(timer);
    if (activation) g_signal_handler_disconnect(window, activation);
    // Callbacks must not look into a map while it is being destroyed.
    auto closing = std::move(editors);
    closing.clear();
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
    g_object_unref(channel);
  }
};
void method(FlMethodChannel *, FlMethodCall *call, gpointer data) {
  auto *owner = static_cast<FlutterCandidates *>(data);
  const std::string method = fl_method_call_get_name(call);
  auto *args = fl_method_call_get_args(call);
  const auto id = text(get(args, "editor"));
  if (id.empty() || id.size() > 128) { fl_method_call_respond_error(call, "candidates", "Invalid editor", nullptr, nullptr); return; }
  if (method == "dispose") {
    auto found = owner->editors.find(id);
    if (found != owner->editors.end()) {
      auto lease = std::move(found->second.lease);
      owner->editors.erase(found);
      lease->release();
    }
  } else if (method == "state") {
    auto &editor = owner->editors[id];
    if (!editor.lease) editor.lease = CandidateLease::create([owner, id](const CandidateSnapshot &s) { owner->changed(id, s); });
    const auto epoch = integer(get(args, "epoch"));
    if (epoch >= editor.epoch) {
      if (epoch != editor.epoch) editor.lease->release();
      editor.epoch = epoch;
      editor.active = boolean(get(args, "active"));
      editor.capacity = boolean(get(args, "capacity"));
      editor.composing = boolean(get(args, "composing"));
      editor.alive = g_get_monotonic_time();
      owner->sync();
    }
  } else {
    auto found = owner->editors.find(id);
    if (found != owner->editors.end() && integer(get(args, "epoch")) == found->second.epoch) {
      const auto token = text(get(args, "token")), serial = text(get(args, "serial"));
      char *end = nullptr;
      errno = 0;
      const auto number = g_ascii_strtoull(serial.c_str(), &end, 10);
      if (!serial.empty() && end && !*end && serial[0] >= '0' && serial[0] <= '9' && errno != ERANGE) {
        auto &lease = found->second.lease;
        if (method == "rendered") lease->rendered(token, number);
        else if (method == "select") lease->select(token, number, integer(get(args, "index")));
        else if (method == "page") lease->page(token, number, boolean(get(args, "next")));
      }
    }
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}
}
void register_flutter_candidates(FlBinaryMessenger *messenger, GtkWidget *view, GtkWindow *window) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto *owner = new FlutterCandidates{fl_method_channel_new(messenger, "rapp/linux_candidates", FL_METHOD_CODEC(codec)), view, window, {}};
  fl_method_channel_set_method_call_handler(owner->channel, method, owner, nullptr);
  owner->timer = g_timeout_add(100, +[](gpointer p) -> gboolean { static_cast<FlutterCandidates *>(p)->sync(); return G_SOURCE_CONTINUE; }, owner);
  owner->activation = g_signal_connect(window, "notify::is-active", G_CALLBACK(+[](GObject *, GParamSpec *, gpointer p) { static_cast<FlutterCandidates *>(p)->sync(); }), owner);
  g_object_set_data_full(G_OBJECT(view), "rapp-candidates", owner, +[](gpointer p) { delete static_cast<FlutterCandidates *>(p); });
}
}
