#include "my_application.h"
#include "rapp_desktop.h"

#include <flutter_linux/flutter_linux.h>
#include <initializer_list>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  GtkWindow* main_window;
  GtkWindow* cm_window;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  GtkWidget* window = gtk_widget_get_toplevel(GTK_WIDGET(view));
  // Flutter's pages paint an opaque background on the GPU. Once a frame is
  // available, skip the redundant GTK and FlView Cairo backgrounds: filling
  // and uploading those full-window CPU surfaces is costly on HiDPI displays.
  // GtkHeaderBar still paints itself. Keep the normal background during startup
  // in case window_manager shows the window before Flutter's first frame.
  gtk_widget_set_app_paintable(window, TRUE);
  const GdkRGBA transparent = {0, 0, 0, 0};
  fl_view_set_background_color(view, &transparent);
  gtk_widget_show(window);
}

// Both roles live in one process, with at most one window/engine per role.
static void show_window(GApplication* application, gboolean connection_manager,
                        char** arguments) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow** slot = connection_manager ? &self->cm_window : &self->main_window;
  if (*slot != nullptr) {
    gtk_window_deiconify(*slot);
    gtk_window_present(*slot);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  *slot = window;
  g_object_add_weak_pointer(G_OBJECT(window), reinterpret_cast<gpointer*>(slot));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "rapp");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "rapp");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Retain a solid startup background until Flutter supplies its first frame.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  rapp_desktop_register(view, window);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Desktop activation always targets the main window, even if --cm started first.
static void my_application_activate(GApplication* application) {
  show_window(application, FALSE, nullptr);
}

// GApplication forwards subsequent launches (including --cm) over the session
// bus before they can create a Flutter engine or start another rapp-hub.
static int my_application_command_line(GApplication* application,
                                      GApplicationCommandLine* command_line) {
  g_auto(GStrv) arguments =
      g_application_command_line_get_arguments(command_line, nullptr);
  gboolean cm = FALSE;
  for (int i = 1; arguments[i] != nullptr; ++i) {
    if (g_str_equal(arguments[i], "--cm")) cm = TRUE;
  }
  show_window(application, cm, arguments + 1);
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  for (GtkWindow** slot : {&self->main_window, &self->cm_window}) {
    if (*slot != nullptr) {
      g_object_remove_weak_pointer(G_OBJECT(*slot), reinterpret_cast<gpointer*>(slot));
      *slot = nullptr;
    }
  }
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE, nullptr));
}
