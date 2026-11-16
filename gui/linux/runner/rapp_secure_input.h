#pragma once
#include <gtk/gtk.h>
#include <flutter_linux/flutter_linux.h>

namespace rapp {
// Flutter's visiblePassword input type configures GTK_INPUT_PURPOSE_PASSWORD on
// its own IM context. This bridge only keeps custom candidates out of that field;
// it never changes Fcitx's global state or another editor's input method.
void register_secure_input(FlBinaryMessenger *messenger, GtkWidget *view);
}
