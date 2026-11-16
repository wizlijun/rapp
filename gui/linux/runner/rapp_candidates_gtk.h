#pragma once
#include <gtk/gtk.h>

namespace rapp {
// Wrap an already populated scroller; each TextView owns its own candidate lease.
GtkWidget *wrap_gtk_candidates(GtkTextView *editor, GtkWidget *scroll);
}
