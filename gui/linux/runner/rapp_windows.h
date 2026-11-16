#pragma once
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
struct RappWindows;
RappWindows *rapp_windows_new(FlMethodChannel *, GtkWindow *);
bool rapp_windows_method(RappWindows *, FlMethodCall *);
void rapp_windows_free(RappWindows *);
