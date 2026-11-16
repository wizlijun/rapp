#include "rapp_secure_input.h"
#include "rapp_candidates.h"
#include <algorithm>
#include <limits>
#include <string>

namespace rapp {
namespace {
struct SecureInput {
  FlMethodChannel *channel;
  GtkWidget *view;
  unsigned depth = 0;
  ~SecureInput() {
    // The view is being destroyed: its candidate owner releases every lease.
    // Do not touch other view-owned data from a GObject data destructor.
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
    g_object_unref(channel);
  }
};
void handle(FlMethodChannel *, FlMethodCall *call, gpointer data) {
  auto *self = static_cast<SecureInput *>(data);
  const std::string method = fl_method_call_get_name(call);
  if (method == "begin") {
    if (self->depth < std::numeric_limits<unsigned>::max()) ++self->depth;
  } else if (method == "end") {
    if (self->depth) --self->depth;
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  set_flutter_candidates_secure(self->view, self->depth != 0);
  fl_method_call_respond_success(call, nullptr, nullptr);
}
}
void register_secure_input(FlBinaryMessenger *messenger, GtkWidget *view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto *self = new SecureInput{
    fl_method_channel_new(messenger, "rapp/secure-input", FL_METHOD_CODEC(codec)), view};
  fl_method_channel_set_method_call_handler(self->channel, handle, self, nullptr);
  g_object_set_data_full(G_OBJECT(view), "rapp-secure-input", self,
    +[](gpointer p) { delete static_cast<SecureInput *>(p); });
}
}
