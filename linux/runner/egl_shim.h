#ifndef RUNNER_EGL_SHIM_H_
#define RUNNER_EGL_SHIM_H_

// Routes the process's libepoxy EGL and GLX calls through wrappers that let
// several Flutter engines share one EGLDisplay, and GDK's GLX share the main
// thread with them. Must run before GTK or any engine touches GL. See egl_shim.cc and lib/core/platform/CLAUDE.md.
void egl_shim_install();

#endif  // RUNNER_EGL_SHIM_H_
