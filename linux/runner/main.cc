#include <glib.h>

#include "egl_shim.h"
#include "my_application.h"

int main(int argc, char** argv) {
  // Force the X11/XWayland GDK backend so that gtk_window_move() is honoured.
  // On pure Wayland the backend ignores position requests entirely, making
  // window-position save/restore impossible via the GTK3 API.
  // The "0" flag means we don't override an explicit GDK_BACKEND already set
  // by the user or the snap launcher.
  g_setenv("GDK_BACKEND", "x11", 0);

  // Before GTK starts, so GDK's own EGL setup goes through it too.
  egl_shim_install();

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
