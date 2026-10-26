#include "egl_shim.h"

#include <dlfcn.h>
#include <epoxy/egl.h>
#include <epoxy/glx.h>
#include <gtk/gtk.h>

#include <unordered_map>

// Every desktop_multi_window sub-window is its own FlEngine, and every
// FlEngine has its own FlOpenGLManager. Each of those asks EGL for the display
// of the one GDK connection, and EGL hands them all the same EGLDisplay -
// shared with GDK's own EGL on Wayland as well. Two things go wrong:
//
// - FlOpenGLManager's dispose calls eglTerminate on it. Closing a compose
//   window therefore terminated the display under the main window, whose next
//   frame failed eglMakeCurrent with EGL_NOT_INITIALIZED: a fatal GLX
//   BadAccess on X11, a segfault in gdk_window_end_draw_frame on Wayland.
//   eglInitialize/eglTerminate are counted per display here, so only the last
//   user's terminate reaches the driver - EGL_KHR_display_reference's
//   semantics, which the engine does not ask for.
//
// - On X11 GDK paints through GLX, and leaves its paint context current on
//   the main thread (the reading pane's WebKitWebView does that). libglvnd
//   refuses to make an EGL context current on a thread holding a GLX one, so
//   a sub-window engine's first eglMakeCurrent - its compositor shader setup -
//   failed with EGL_BAD_ACCESS and the window never drew. GDK makes its own
//   context current again before it next paints, so releasing it and retrying
//   is safe.
//
// - The same rule the other way round: a closing engine's compositor makes
//   its EGL context current on the main thread to delete its shaders and
//   never releases it, so GDK's next GLX paint of the main window failed with
//   a client-side BadAccess (GLX MakeContextCurrent), which GDK treats as
//   fatal. Every engine call site makes its context current before using it,
//   so whatever EGL context is current is released before GDK binds GLX.
//
// libflutter_linux_gtk.so, GTK and WebKitGTK all call EGL and GLX through
// libepoxy's exported dispatch pointers, so replacing those pointers covers
// every caller in the process. The real entry points come straight from the
// libraries: calling eglTerminate() etc. here would call the epoxy pointer,
// i.e. ourselves.

namespace {

using InitializeFn = EGLBoolean (*)(EGLDisplay, EGLint*, EGLint*);
using TerminateFn = EGLBoolean (*)(EGLDisplay);
using MakeCurrentFn = EGLBoolean (*)(EGLDisplay, EGLSurface, EGLSurface,
                                     EGLContext);
using GetErrorFn = EGLint (*)();
using GetCurrentContextFn = EGLContext (*)();
using GetCurrentDisplayFn = EGLDisplay (*)();
using GlxMakeCurrentFn = Bool (*)(Display*, GLXDrawable, GLXContext);
using GlxMakeContextCurrentFn = Bool (*)(Display*,
                                         GLXDrawable,
                                         GLXDrawable,
                                         GLXContext);

InitializeFn real_initialize = nullptr;
TerminateFn real_terminate = nullptr;
MakeCurrentFn real_make_current = nullptr;
GetErrorFn real_get_error = nullptr;
GetCurrentContextFn real_get_current_context = nullptr;
GetCurrentDisplayFn real_get_current_display = nullptr;
GlxMakeCurrentFn real_glx_make_current = nullptr;
GlxMakeContextCurrentFn real_glx_make_context_current = nullptr;

GMutex refs_mutex;
std::unordered_map<EGLDisplay, int>* display_refs = nullptr;

EGLBoolean shim_initialize(EGLDisplay display, EGLint* major, EGLint* minor) {
  EGLBoolean result = real_initialize(display, major, minor);
  if (result == EGL_TRUE) {
    g_mutex_lock(&refs_mutex);
    (*display_refs)[display]++;
    g_mutex_unlock(&refs_mutex);
  }
  return result;
}

EGLBoolean shim_terminate(EGLDisplay display) {
  g_mutex_lock(&refs_mutex);
  auto it = display_refs->find(display);
  bool last = it == display_refs->end() || --it->second <= 0;
  if (last && it != display_refs->end()) {
    display_refs->erase(it);
  }
  g_mutex_unlock(&refs_mutex);
  return last ? real_terminate(display) : EGL_TRUE;
}

EGLBoolean shim_make_current(EGLDisplay display,
                             EGLSurface draw,
                             EGLSurface read,
                             EGLContext context) {
  EGLBoolean result = real_make_current(display, draw, read, context);
  // GDK's current context is per thread, so this only ever fires on the
  // thread GDK paints from. Checked before eglGetError, which clears the
  // error the caller would otherwise read.
  if (result == EGL_FALSE && context != EGL_NO_CONTEXT &&
      gdk_gl_context_get_current() != nullptr &&
      real_get_error() == EGL_BAD_ACCESS) {
    gdk_gl_context_clear_current();
    result = real_make_current(display, draw, read, context);
  }
  return result;
}

void release_current_egl_context() {
  if (real_get_current_context() != EGL_NO_CONTEXT) {
    real_make_current(real_get_current_display(), EGL_NO_SURFACE,
                      EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
}

Bool shim_glx_make_current(Display* display,
                           GLXDrawable drawable,
                           GLXContext context) {
  if (context != nullptr) {
    release_current_egl_context();
  }
  return real_glx_make_current(display, drawable, context);
}

Bool shim_glx_make_context_current(Display* display,
                                   GLXDrawable draw,
                                   GLXDrawable read,
                                   GLXContext context) {
  if (context != nullptr) {
    release_current_egl_context();
  }
  return real_glx_make_context_current(display, draw, read, context);
}

}  // namespace

void egl_shim_install() {
  void* egl = dlopen("libEGL.so.1", RTLD_LAZY | RTLD_LOCAL);
  if (egl == nullptr) {
    g_warning("EGL shim not installed: %s", dlerror());
    return;
  }
  real_initialize =
      reinterpret_cast<InitializeFn>(dlsym(egl, "eglInitialize"));
  real_terminate = reinterpret_cast<TerminateFn>(dlsym(egl, "eglTerminate"));
  real_make_current =
      reinterpret_cast<MakeCurrentFn>(dlsym(egl, "eglMakeCurrent"));
  real_get_error = reinterpret_cast<GetErrorFn>(dlsym(egl, "eglGetError"));
  real_get_current_context = reinterpret_cast<GetCurrentContextFn>(
      dlsym(egl, "eglGetCurrentContext"));
  real_get_current_display = reinterpret_cast<GetCurrentDisplayFn>(
      dlsym(egl, "eglGetCurrentDisplay"));
  if (real_initialize == nullptr || real_terminate == nullptr ||
      real_make_current == nullptr || real_get_error == nullptr ||
      real_get_current_context == nullptr ||
      real_get_current_display == nullptr) {
    g_warning("EGL shim not installed: libEGL is missing an entry point");
    return;
  }

  display_refs = new std::unordered_map<EGLDisplay, int>();
  epoxy_eglInitialize = shim_initialize;
  epoxy_eglTerminate = shim_terminate;
  epoxy_eglMakeCurrent = shim_make_current;

  // GLX only exists, and only matters, under X11. The same library libepoxy
  // loads for it.
  void* glx = dlopen("libGL.so.1", RTLD_LAZY | RTLD_LOCAL);
  if (glx == nullptr) {
    g_warning("EGL shim: GLX wrappers not installed: %s", dlerror());
    return;
  }
  real_glx_make_current =
      reinterpret_cast<GlxMakeCurrentFn>(dlsym(glx, "glXMakeCurrent"));
  real_glx_make_context_current = reinterpret_cast<GlxMakeContextCurrentFn>(
      dlsym(glx, "glXMakeContextCurrent"));
  if (real_glx_make_current != nullptr) {
    epoxy_glXMakeCurrent = shim_glx_make_current;
  }
  if (real_glx_make_context_current != nullptr) {
    epoxy_glXMakeContextCurrent = shim_glx_make_context_current;
  }
}
