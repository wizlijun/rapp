#include "rapp_desktop.h"
#include "rapp_windows.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {
constexpr size_t kLimit = 256 * 1024 * 1024;
struct Desktop {
  FlMethodChannel *channel;
  GtkWindow *main;
  RappWindows *windows;
};
FlValue *at(FlValue *m, const char *k) {
  return m && fl_value_get_type(m) == FL_VALUE_TYPE_MAP
             ? fl_value_lookup_string(m, k)
             : nullptr;
}
const char *str(FlValue *v, const char *fallback = "") {
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(v)
             : fallback;
}
void put(FlValue *m, const char *k, FlValue *v) {
  fl_value_set_string_take(m, k, v);
}
void success(FlMethodCall *call, FlValue *v = nullptr) {
  fl_method_call_respond_success(call, v, nullptr);
}
void failure(FlMethodCall *call, const char *text) {
  fl_method_call_respond_error(call, "desktop", text, nullptr, nullptr);
}
std::string mime(const std::string &uti) {
  if (uti == "public.png")
    return "image/png";
  if (uti == "public.tiff")
    return "image/tiff";
  if (uti == "com.adobe.pdf")
    return "application/pdf";
  if (uti == "public.html")
    return "text/html";
  if (uti == "public.rtf")
    return "text/rtf";
  if (uti == "public.utf8-plain-text")
    return "text/plain;charset=utf-8";
  return uti;
}
std::string uti(const std::string &type) {
  if (type == "image/png")
    return "public.png";
  if (type == "image/tiff")
    return "public.tiff";
  if (type == "application/pdf")
    return "com.adobe.pdf";
  if (type == "text/html")
    return "public.html";
  if (type == "text/rtf" || type == "application/rtf")
    return "public.rtf";
  return type;
}
struct Clip {
  std::vector<guint8> bytes;
  std::string type;
};
void clip_get(GtkClipboard *, GtkSelectionData *selection, guint,
              gpointer data) {
  auto *c = static_cast<Clip *>(data);
  gtk_selection_data_set(selection, gtk_selection_data_get_target(selection), 8,
                         c->bytes.data(), c->bytes.size());
}
void clip_clear(GtkClipboard *, gpointer data) {
  delete static_cast<Clip *>(data);
}
void read_clip(FlMethodCall *call) {
  GtkClipboard *cb = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  g_autoptr(FlValue) result = fl_value_new_map();
  gchar **uris = gtk_clipboard_wait_for_uris(cb);
  if (uris) {
    FlValue *files = fl_value_new_list();
    for (int i = 0; uris[i]; i++) {
      gchar *path = g_filename_from_uri(uris[i], nullptr, nullptr);
      if (path) {
        fl_value_append_take(files, fl_value_new_string(path));
        g_free(path);
      }
    }
    g_strfreev(uris);
    put(result, "kind", fl_value_new_string("files"));
    put(result, "files", files);
    return success(call, result);
  }
  GdkPixbuf *img = gtk_clipboard_wait_for_image(cb);
  if (img) {
    gchar *bytes = nullptr;
    gsize n = 0;
    gboolean ok =
        gdk_pixbuf_save_to_buffer(img, &bytes, &n, "png", nullptr, nullptr);
    g_object_unref(img);
    if (!ok || n > kLimit) {
      g_free(bytes);
      return failure(call, "图片读取失败或超过 256 MB");
    }
    put(result, "kind", fl_value_new_string("image"));
    put(result, "uti", fl_value_new_string("public.png"));
    put(result, "bytes",
        fl_value_new_uint8_list(reinterpret_cast<guint8 *>(bytes), n));
    g_free(bytes);
    return success(call, result);
  }
  gchar *text = gtk_clipboard_wait_for_text(cb);
  if (text) {
    if (strlen(text) > kLimit) {
      g_free(text);
      return failure(call, "文字超过 256 MB");
    }
    put(result, "kind", fl_value_new_string("text"));
    put(result, "text", fl_value_new_string(text));
    g_free(text);
    return success(call, result);
  }
  GdkAtom *targets = nullptr;
  gint n = 0;
  if (gtk_clipboard_wait_for_targets(cb, &targets, &n)) {
    for (int i = 0; i < n; i++) {
      gchar *name = gdk_atom_name(targets[i]);
      std::string type = name ? name : "";
      g_free(name);
      if (type == "TARGETS" || type == "TIMESTAMP" || type == "MULTIPLE" ||
          type == "SAVE_TARGETS" || type.empty())
        continue;
      GtkSelectionData *data = gtk_clipboard_wait_for_contents(cb, targets[i]);
      if (!data)
        continue;
      gint size = gtk_selection_data_get_length(data);
      if (size >= 0 && static_cast<size_t>(size) <= kLimit) {
        put(result, "kind", fl_value_new_string("data"));
        put(result, "uti", fl_value_new_string(uti(type).c_str()));
        put(result, "bytes",
            fl_value_new_uint8_list(gtk_selection_data_get_data(data), size));
        gtk_selection_data_free(data);
        g_free(targets);
        return success(call, result);
      }
      gtk_selection_data_free(data);
    }
    g_free(targets);
  }
  success(call);
}
void write_clip(FlMethodCall *call, FlValue *args) {
  GtkClipboard *cb = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  std::string kind = str(at(args, "kind"));
  if (kind == "text") {
    gtk_clipboard_set_text(cb, str(at(args, "text")), -1);
  } else {
    auto *c = new Clip();
    if (kind == "files") {
      FlValue *files = at(args, "files");
      std::string urls;
      if (!files || fl_value_get_type(files) != FL_VALUE_TYPE_LIST) {
        delete c;
        return failure(call, "文件列表无效");
      }
      for (size_t i = 0; i < fl_value_get_length(files); i++) {
        gchar *uri = g_filename_to_uri(str(fl_value_get_list_value(files, i)),
                                       nullptr, nullptr);
        if (!uri) {
          delete c;
          return failure(call, "文件路径无效");
        }
        urls += uri;
        urls += "\r\n";
        g_free(uri);
      }
      c->type = "text/uri-list";
      c->bytes.assign(urls.begin(), urls.end());
    } else {
      FlValue *b = at(args, "bytes");
      if (!b || fl_value_get_type(b) != FL_VALUE_TYPE_UINT8_LIST ||
          fl_value_get_length(b) > kLimit) {
        delete c;
        return failure(call, "剪贴板数据无效");
      }
      c->type = kind == "image"
                    ? "image/png"
                    : mime(str(at(args, "uti"), "application/octet-stream"));
      const auto *bytes = fl_value_get_uint8_list(b);
      c->bytes.assign(bytes, bytes + fl_value_get_length(b));
    }
    GtkTargetEntry target{const_cast<gchar *>(c->type.c_str()), 0, 0};
    if (!gtk_clipboard_set_with_data(cb, &target, 1, clip_get, clip_clear, c)) {
      delete c;
      return failure(call, "剪贴板写入失败");
    }
    gtk_clipboard_set_can_store(cb, nullptr, 0);
  }
  g_autoptr(FlValue) yes = fl_value_new_bool(true);
  success(call, yes);
}
void choose(Desktop *d, FlMethodCall *call) {
  auto *parent =
      gtk_application_get_active_window(gtk_window_get_application(d->main));
  auto *chooser =
      gtk_file_chooser_native_new("添加附件", parent ? parent : d->main,
                                  GTK_FILE_CHOOSER_ACTION_OPEN, "添加", "取消");
  gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(chooser), TRUE);
  g_object_ref(call);
  g_signal_connect(
      chooser, "response",
      G_CALLBACK(+[](GtkNativeDialog *dialog, gint response, gpointer data) {
        auto *pending = FL_METHOD_CALL(data);
        g_autoptr(FlValue) paths = fl_value_new_list();
        if (response == GTK_RESPONSE_ACCEPT) {
          GSList *names =
              gtk_file_chooser_get_filenames(GTK_FILE_CHOOSER(dialog));
          for (GSList *n = names; n; n = n->next)
            fl_value_append_take(
                paths, fl_value_new_string(static_cast<char *>(n->data)));
          g_slist_free_full(names, g_free);
        }
        success(pending, paths);
        g_object_unref(pending);
        g_object_unref(dialog);
      }),
      call);
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(chooser));
}
void method(FlMethodChannel *, FlMethodCall *call, gpointer data) {
  auto *d = static_cast<Desktop *>(data);
  const std::string name = fl_method_call_get_name(call);
  FlValue *args = fl_method_call_get_args(call);
  if (name == "clipboard_read")
    return read_clip(call);
  if (name == "clipboard_write")
    return write_clip(call, args);
  if (name == "choose_files")
    return choose(d, call);
  if (name == "init") {
    g_autoptr(FlValue) value = fl_value_new_bool(true);
    return success(call, value);
  }
  if (rapp_windows_method(d->windows, call))
    return;
  fl_method_call_respond_not_implemented(call, nullptr);
}
} // namespace
void rapp_desktop_register(FlView *view, GtkWindow *window) {
  auto *d = new Desktop();
  d->main = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  d->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "rapp/linux",
      FL_METHOD_CODEC(codec));
  d->windows = rapp_windows_new(d->channel, window);
  fl_method_channel_set_method_call_handler(d->channel, method, d, nullptr);
  GtkTargetEntry targets[] = {{const_cast<char *>("text/uri-list"), 0, 0}};
  gtk_drag_dest_set(GTK_WIDGET(view), GTK_DEST_DEFAULT_ALL, targets, 1,
                    GDK_ACTION_COPY);
  g_signal_connect(
      view, "drag-data-received",
      reinterpret_cast<GCallback>(+[](GtkWidget *, GdkDragContext *context,
                                      gint, gint, GtkSelectionData *selection,
                                      guint, guint time, gpointer p) {
        auto *d = static_cast<Desktop *>(p);
        g_autoptr(FlValue) args = fl_value_new_map();
        auto *files = fl_value_new_list();
        gchar **uris = gtk_selection_data_get_uris(selection);
        if (uris) {
          for (int i = 0; uris[i]; i++) {
            gchar *path = g_filename_from_uri(uris[i], nullptr, nullptr);
            if (path) {
              fl_value_append_take(files, fl_value_new_string(path));
              g_free(path);
            }
          }
          g_strfreev(uris);
        }
        bool ok = fl_value_get_length(files) > 0;
        put(args, "files", files);
        fl_method_channel_invoke_method(d->channel, "drop_files", args, nullptr,
                                        nullptr, nullptr);
        gtk_drag_finish(context, ok, FALSE, time);
      }),
      d);
  g_object_set_data_full(
      G_OBJECT(view), "rapp-desktop", d, +[](gpointer p) {
        auto *d = static_cast<Desktop *>(p);
        rapp_windows_free(d->windows);
        g_object_unref(d->channel);
        delete d;
      });
}
