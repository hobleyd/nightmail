#pragma once

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include <string>

struct WebkitView {
  gint64 id;
  WebKitWebView* web_view;
  GtkOverlay* overlay;

  FlMethodChannel* channel;
  FlEventChannel* event_channel;

  FlMethodCall* pending_eval;

  gint pos_x;
  gint pos_y;
  gint width;
  gint height;

  gboolean alive;

  // Dart asked for the overlay to be hidden (a Flutter modal or guarded
  // overlay is on top of it). UpdatePosition must not undo that: it runs on
  // every setPosition/setSize, and opening a dialog relayouts the reading
  // pane, so without this flag the native WebView pops straight back over
  // the dialog it was hidden for.
  gboolean hidden_by_request;

  WebkitView(gint64 id, GtkOverlay* overlay, FlBinaryMessenger* messenger);
  ~WebkitView();

  void HandleMethod(FlMethodCall* method_call);
  void EmitEvent(const char* type, const char* value);
  void UpdatePosition();

 private:
  void DoLoadAsset(const std::string& key, FlMethodCall* call);
  void DoEval(const std::string& js, FlMethodCall* call);

  static std::string GetExecutableDir();
  static std::string AssetPath(const std::string& key);
};
