#include "egl_shim.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <epoxy/glx.h>
#include <gtk/gtk.h>

#include <vector>

// Every desktop_multi_window sub-window is its own FlEngine, and every
// FlEngine has its own FlOpenGLManager. Each of those asks EGL for the display
// of the one GDK connection, and EGL hands them all the same EGLDisplay -
// shared with GDK's own EGL on Wayland as well. Several things go wrong:
//
// - FlOpenGLManager's dispose calls eglTerminate on it. Closing a compose
//   window therefore terminated the display under the main window, whose next
//   frame failed eglMakeCurrent with EGL_NOT_INITIALIZED: a fatal GLX
//   BadAccess on X11, a segfault in gdk_window_end_draw_frame on Wayland.
//   eglTerminate never reaches the driver (see the last point for why not
//   even the last user's).
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
// - Deleting a closed engine's contexts segfaults NVIDIA 580 in
//   libnvidia-eglcore (always offset 0xa5f05f, a read near address 0x1230),
//   and killed the app on closing a compose window (2026-10-28). The route
//   in varied - the deferred delete of the context the compositor left
//   current, run inside the release above at the main window's next GLX
//   paint; or FlOpenGLManager's own eglDestroyContext - but the deletion
//   itself is what faults. Ruled out under gdb, each still crashing:
//   releasing a context current on this thread before destroying it, and
//   releasing the contexts the engine's raster and IO threads still held
//   as those threads exit (they did hold them). So eglDestroyContext never
//   reaches the driver. Left at that, every closed sub-window held ~35 MiB of
//   GPU memory and as much RAM until quit, so a closed engine's contexts are
//   pooled instead and handed to the next engine that starts:
//   FlOpenGLManager always creates the same three, a render context and then
//   a resource and a platform context sharing with it, from one config.
//   Pooling alone still grew ~30 MiB of GPU per window: the engine's late
//   glDelete* calls for its framebuffer run with no context current, so
//   that texture and renderbuffer stay in the set. scrub_set deletes every
//   object a pooled set holds before reissuing it (~45 ms; 2 framebuffers,
//   4 textures, 2 renderbuffers, 72 programs per compose window). Measured
//   over five compose windows, GPU stayed at 200-235 MiB and only one set
//   was ever pooled, so the cost is the most sub-windows ever open at once.
//   The thread-exit release is kept so no context is ever left current on a
//   dead thread.
//
// libflutter_linux_gtk.so, GTK and WebKitGTK all call EGL and GLX through
// libepoxy's exported dispatch pointers, so replacing those pointers covers
// every caller in the process. The real entry points come straight from the
// libraries: calling eglTerminate() etc. here would call the epoxy pointer,
// i.e. ourselves.

namespace {

using MakeCurrentFn = EGLBoolean (*)(EGLDisplay, EGLSurface, EGLSurface,
                                     EGLContext);
using CreateContextFn = EGLContext (*)(EGLDisplay, EGLConfig, EGLContext,
                                       const EGLint*);
using GetErrorFn = EGLint (*)();
using GetCurrentContextFn = EGLContext (*)();
using GetCurrentDisplayFn = EGLDisplay (*)();
using GlxMakeCurrentFn = Bool (*)(Display*, GLXDrawable, GLXContext);
using GlxMakeContextCurrentFn = Bool (*)(Display*,
                                         GLXDrawable,
                                         GLXDrawable,
                                         GLXContext);

MakeCurrentFn real_make_current = nullptr;
CreateContextFn real_create_context = nullptr;
GetErrorFn real_get_error = nullptr;
GetCurrentContextFn real_get_current_context = nullptr;
GetCurrentDisplayFn real_get_current_display = nullptr;
GlxMakeCurrentFn real_glx_make_current = nullptr;
GlxMakeContextCurrentFn real_glx_make_context_current = nullptr;

// The display outlives every context left alive on it, so even the last
// user's terminate stops here: a real one would tear all of them down at once,
// which is the crash moved to quit. Process exit reclaims it.
EGLBoolean shim_terminate(EGLDisplay) { return EGL_TRUE; }

// Releases whatever EGL context is still current when its thread exits. C++
// thread_local destructors run before the pthread-key destructors libglvnd and
// the driver free their per-thread state with, so the release still works.
struct ReleaseAtThreadExit {
  bool armed = false;
  ~ReleaseAtThreadExit() {
    if (!armed) return;
    EGLContext context = real_get_current_context();
    if (context == EGL_NO_CONTEXT) return;
    g_message("EGL shim: thread exiting with context %p current; releasing",
              context);
    real_make_current(real_get_current_display(), EGL_NO_SURFACE,
                      EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
};
thread_local ReleaseAtThreadExit release_at_thread_exit;

EGLBoolean shim_make_current(EGLDisplay display,
                             EGLSurface draw,
                             EGLSurface read,
                             EGLContext context) {
  if (context != EGL_NO_CONTEXT) release_at_thread_exit.armed = true;
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

// NVIDIA's EGL frees every context still alive from an exit handler, and that
// is the same faulting delete. Exit handlers run newest first and the driver
// registered its own when it loaded, so this one - registered once a context
// has been left alive - ends the process before it runs. Also covers Dart's
// exit(0) from the in-app updater.
void exit_before_driver_teardown(int status, void*) {
  fflush(nullptr);
  _exit(status);
}

// One FlOpenGLManager's contexts: [0] the render context, created sharing with
// nothing, then [1] and [2] created sharing with it.
struct ContextSet {
  EGLDisplay display;
  EGLConfig config;
  EGLContext contexts[3];
  int created;    // filled so far, by creation or by reissue
  int destroyed;  // destroy calls since it was last handed out
};

GMutex sets_mutex;
std::vector<ContextSet*>* all_sets = nullptr;
std::vector<ContextSet*>* free_sets = nullptr;
// The set whose render context was the last one handed out, until its other
// two have been asked for.
ContextSet* filling = nullptr;
bool filling_reissued = false;
int contexts_created = 0;

// Highest object name scrub_set looks at. Logged against what it finds, so a
// set that comes near it shows up in the journal.
constexpr GLuint kScrubNameLimit = 65536;

// Deletes every GL object a closed engine left in its contexts before they are
// handed to the next one. The engine's own late deletes cannot be relied on:
// framebuffers and vertex arrays live only in the context that made them (the
// window's framebuffer is the render context's, made on the raster thread),
// and the compositor frees its framebuffer from the main thread after its
// context is gone. Left there, each reuse kept the last window's
// framebuffer - a window-sized colour texture and depth/stencil buffer.
// Everything in a pooled set belonged to an engine that no longer exists, so
// all of it can go.
void scrub_set(ContextSet* set) {
  gint64 started = g_get_monotonic_time();
  // libglvnd will not make an EGL context current over GDK's GLX one; GDK
  // makes its own current again before it next paints.
  gdk_gl_context_clear_current();
  int framebuffers = 0, vertex_arrays = 0, textures = 0, buffers = 0,
      renderbuffers = 0, programs = 0, shaders = 0;
  GLuint highest = 0;
  for (int i = 2; i >= 0; i--) {
    if (!real_make_current(set->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                           set->contexts[i])) {
      g_warning("EGL shim: could not scrub context %p", set->contexts[i]);
      continue;
    }
    bool es3 = epoxy_gl_version() >= 30;
    // The render context, made current last, also clears the shared objects.
    bool shared = i == 0;
    for (GLuint name = 1; name < kScrubNameLimit; name++) {
      bool found = false;
      if (glIsFramebuffer(name)) {
        glDeleteFramebuffers(1, &name);
        framebuffers++;
        found = true;
      }
      if (es3 && glIsVertexArray(name)) {
        glDeleteVertexArrays(1, &name);
        vertex_arrays++;
        found = true;
      }
      if (shared) {
        if (glIsTexture(name)) {
          glDeleteTextures(1, &name);
          textures++;
          found = true;
        }
        if (glIsBuffer(name)) {
          glDeleteBuffers(1, &name);
          buffers++;
          found = true;
        }
        if (glIsRenderbuffer(name)) {
          glDeleteRenderbuffers(1, &name);
          renderbuffers++;
          found = true;
        }
        if (glIsProgram(name)) {
          glDeleteProgram(name);
          programs++;
          found = true;
        } else if (glIsShader(name)) {
          glDeleteShader(name);
          shaders++;
          found = true;
        }
      }
      if (found) highest = name;
    }
    glFinish();
  }
  real_make_current(set->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                    EGL_NO_CONTEXT);
  g_message(
      "EGL shim: scrubbed set %p in %" G_GINT64_FORMAT
      " ms: %d framebuffers, %d vertex arrays, %d textures, %d buffers, "
      "%d renderbuffers, %d programs, %d shaders (highest name %u of %u)",
      set->contexts[0], (g_get_monotonic_time() - started) / 1000,
      framebuffers, vertex_arrays, textures, buffers, renderbuffers, programs,
      shaders, highest, kScrubNameLimit);
}

ContextSet* set_of(EGLContext context) {
  for (ContextSet* set : *all_sets) {
    for (EGLContext member : set->contexts) {
      if (member == context) return set;
    }
  }
  return nullptr;
}

EGLContext shim_create_context(EGLDisplay display,
                               EGLConfig config,
                               EGLContext share,
                               const EGLint* attributes) {
  g_mutex_lock(&sets_mutex);
  EGLContext context = EGL_NO_CONTEXT;
  if (share == EGL_NO_CONTEXT) {
    filling = nullptr;
    for (auto it = free_sets->begin(); it != free_sets->end(); ++it) {
      ContextSet* set = *it;
      if (set->display == display && set->config == config) {
        free_sets->erase(it);
        scrub_set(set);
        set->created = 1;
        set->destroyed = 0;
        filling = set;
        filling_reissued = true;
        context = set->contexts[0];
        g_message("EGL shim: reusing context set %p", context);
        break;
      }
    }
    if (filling == nullptr) {
      context = real_create_context(display, config, share, attributes);
      if (context != EGL_NO_CONTEXT) {
        filling = new ContextSet{display, config, {context}, 1, 0};
        filling_reissued = false;
        all_sets->push_back(filling);
        contexts_created++;
      }
    }
  } else if (filling != nullptr && share == filling->contexts[0] &&
             filling->created < 3) {
    if (filling_reissued) {
      context = filling->contexts[filling->created++];
    } else {
      context = real_create_context(display, config, share, attributes);
      if (context != EGL_NO_CONTEXT) {
        filling->contexts[filling->created++] = context;
        contexts_created++;
      }
    }
    if (filling->created == 3) filling = nullptr;
  } else {
    context = real_create_context(display, config, share, attributes);
  }
  g_mutex_unlock(&sets_mutex);
  return context;
}

// Deliberately never reaches the driver; see the comment at the top.
EGLBoolean shim_destroy_context(EGLDisplay, EGLContext context) {
  if (context == EGL_NO_CONTEXT) return EGL_TRUE;
  if (real_get_current_context() == context) {
    real_make_current(real_get_current_display(), EGL_NO_SURFACE,
                      EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
  static bool exit_guarded = false;
  if (!exit_guarded) {
    exit_guarded = true;
    on_exit(exit_before_driver_teardown, nullptr);
  }
  g_mutex_lock(&sets_mutex);
  ContextSet* set = set_of(context);
  if (filling == set) filling = nullptr;
  // Only a whole set can be handed out again; anything else stays as it is.
  if (set != nullptr && set->created == 3 && ++set->destroyed == 3) {
    free_sets->push_back(set);
    g_message("EGL shim: context set %p pooled (%d contexts ever created)",
              set->contexts[0], contexts_created);
  } else if (set == nullptr || set->created < 3) {
    g_message("EGL shim: context %p left alive", context);
  }
  g_mutex_unlock(&sets_mutex);
  return EGL_TRUE;
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
  real_make_current =
      reinterpret_cast<MakeCurrentFn>(dlsym(egl, "eglMakeCurrent"));
  real_create_context =
      reinterpret_cast<CreateContextFn>(dlsym(egl, "eglCreateContext"));
  real_get_error = reinterpret_cast<GetErrorFn>(dlsym(egl, "eglGetError"));
  real_get_current_context = reinterpret_cast<GetCurrentContextFn>(
      dlsym(egl, "eglGetCurrentContext"));
  real_get_current_display = reinterpret_cast<GetCurrentDisplayFn>(
      dlsym(egl, "eglGetCurrentDisplay"));
  if (real_make_current == nullptr || real_create_context == nullptr ||
      real_get_error == nullptr ||
      real_get_current_context == nullptr ||
      real_get_current_display == nullptr) {
    g_warning("EGL shim not installed: libEGL is missing an entry point");
    return;
  }

  all_sets = new std::vector<ContextSet*>();
  free_sets = new std::vector<ContextSet*>();
  epoxy_eglTerminate = shim_terminate;
  epoxy_eglMakeCurrent = shim_make_current;
  epoxy_eglCreateContext = shim_create_context;
  epoxy_eglDestroyContext = shim_destroy_context;

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
