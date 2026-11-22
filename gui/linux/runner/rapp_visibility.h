#pragma once
#include <gtk/gtk.h>
#include <functional>
#include <utility>

namespace rapp {
// GTK knows mapping and (when the compositor exposes it) minimization.
// Focus and occlusion are deliberately not used: an unfocused window can be visible.
class Visibility {
 public:
  Visibility(GtkWidget *widget, std::function<void()> changed)
      : widget_(widget), changed_(std::move(changed)), mapped_(gtk_widget_get_mapped(widget)) {
    auto *window = gtk_widget_get_window(widget);
    iconified_ = window && (gdk_window_get_state(window) & GDK_WINDOW_STATE_ICONIFIED);
    g_signal_connect(widget_, "map", G_CALLBACK(+[](GtkWidget *, gpointer p) {
      auto *self = static_cast<Visibility *>(p);
      self->mapped_ = true;
      self->changed_();
    }), this);
    g_signal_connect(widget_, "unmap", G_CALLBACK(+[](GtkWidget *, gpointer p) {
      auto *self = static_cast<Visibility *>(p);
      self->mapped_ = false;
      self->changed_();
    }), this);
    g_signal_connect(widget_, "window-state-event", G_CALLBACK(+[](GtkWidget *, GdkEventWindowState *e, gpointer p) -> gboolean {
      auto *self = static_cast<Visibility *>(p);
      self->iconified_ = e->new_window_state & GDK_WINDOW_STATE_ICONIFIED;
      self->changed_();
      return FALSE;
    }), this);
  }
  ~Visibility() { g_signal_handlers_disconnect_by_data(widget_, this); }
  Visibility(const Visibility &) = delete;
  Visibility &operator=(const Visibility &) = delete;
  bool visible() const { return mapped_ && !iconified_; }

 private:
  GtkWidget *widget_;
  std::function<void()> changed_;
  bool mapped_, iconified_ = false;
};
} // namespace rapp
