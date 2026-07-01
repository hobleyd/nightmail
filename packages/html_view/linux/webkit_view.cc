#include "webkit_view.h"

#include <climits>
#include <cstring>
#include <unistd.h>

// ---------------------------------------------------------------------------
// JS bridge injected before any page scripts.
// editor.html's _flutterNotify() falls back to window[name].postMessage(),
// which our injected objects forward via the webkit message handler.
//
// NOTE: We use \x01 (SOH) as separator instead of \x00 because
// jsc_value_to_string() returns a C string that truncates at null bytes.
// ---------------------------------------------------------------------------
static const char* kJsBridge = R"JS(
(function() {
  var SEP = '\x01';
  function makeChannel(name) {
    return {
      postMessage: function(v) {
        window.webkit.messageHandlers.HtmlView.postMessage(
          name + SEP + (v !== undefined ? String(v) : '')
        );
      }
    };
  }
  window['onContentChanged'] = makeChannel('onContentChanged');
  window['onLinkRequest']    = makeChannel('onLinkRequest');
  document.addEventListener('DOMContentLoaded', function() {
    window.webkit.messageHandlers.HtmlView.postMessage('pageLoaded' + SEP);
  });
})();
)JS";

// ---------------------------------------------------------------------------
// Navigation policy — intercept http/https/mailto link clicks
// ---------------------------------------------------------------------------

static void on_decide_policy(WebKitWebView*,
                             WebKitPolicyDecision* decision,
                             WebKitPolicyDecisionType type,
                             gpointer user_data) {
  if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
    auto* nav = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction* action =
        webkit_navigation_policy_decision_get_navigation_action(nav);
    WebKitURIRequest* req = webkit_navigation_action_get_request(action);
    const char* uri = webkit_uri_request_get_uri(req);
    if (uri && (strncmp(uri, "http:", 5) == 0  ||
                strncmp(uri, "https:", 6) == 0 ||
                strncmp(uri, "mailto:", 7) == 0)) {
      static_cast<WebkitView*>(user_data)->EmitEvent("onLinkOpened", uri);
      webkit_policy_decision_ignore(decision);
      return;
    }
  }
  webkit_policy_decision_use(decision);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void on_js_message(WebKitUserContentManager*,
                          WebKitJavascriptResult* result,
                          gpointer user_data) {
  WebkitView* view = static_cast<WebkitView*>(user_data);
  if (!view->alive) return;

  JSCValue* value = webkit_javascript_result_get_js_value(result);
  char* str = jsc_value_to_string(value);
  if (!str) return;

  const char* sep = strchr(str, '\x01');
  if (!sep) {
    g_free(str);
    return;
  }

  std::string type(str, sep - str);
  const char* payload = sep + 1;
  view->EmitEvent(type.c_str(), payload);
  g_free(str);
}

// Called by GtkOverlay to position each overlay child.
gboolean html_view_get_child_position(GtkOverlay* /* overlay */,
                                      GtkWidget* widget,
                                      GdkRectangle* alloc,
                                      gpointer /* data */) {
  WebkitView* view =
      static_cast<WebkitView*>(g_object_get_data(G_OBJECT(widget), "html_view_ptr"));
  if (!view) return FALSE;
  alloc->x = view->pos_x;
  alloc->y = view->pos_y;
  alloc->width  = MAX(1, view->width);
  alloc->height = MAX(1, view->height);
  return TRUE;
}

// Eval completion callback.
struct EvalClosure {
  WebkitView* view;
  FlMethodCall* call;
};

static void on_eval_done(GObject* source,
                         GAsyncResult* result,
                         gpointer user_data) {
  auto* closure = static_cast<EvalClosure*>(user_data);
  WebkitView* view = closure->view;
  FlMethodCall* call = closure->call;
  delete closure;

  if (!view->alive) {
    g_object_unref(call);
    return;
  }

  GError* error = nullptr;
  WebKitJavascriptResult* js_result =
      webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(source),
                                                 result, &error);
  if (error) {
    fl_method_call_respond_error(call, "eval_failed", error->message,
                                 nullptr, nullptr);
    g_error_free(error);
  } else {
    JSCValue* jv = webkit_javascript_result_get_js_value(js_result);
    char* str = jsc_value_to_string(jv);
    g_autoptr(FlValue) resp = fl_value_new_string(str ? str : "null");
    fl_method_call_respond_success(call, resp, nullptr);
    g_free(str);
    webkit_javascript_result_unref(js_result);
  }
  g_object_unref(call);
}

// ---------------------------------------------------------------------------
// Constructor / destructor
// ---------------------------------------------------------------------------

WebkitView::WebkitView(gint64 id_, GtkOverlay* overlay_,
                       FlBinaryMessenger* messenger)
    : id(id_),
      overlay(overlay_),
      event_sink(nullptr),
      pending_eval(nullptr),
      pos_x(0), pos_y(0), width(0), height(0),
      alive(TRUE) {
  // Create user content manager with the HtmlView message handler.
  WebKitUserContentManager* ucm = webkit_user_content_manager_new();
  webkit_user_content_manager_register_script_message_handler(ucm, "HtmlView");
  g_signal_connect(ucm, "script-message-received::HtmlView",
                   G_CALLBACK(on_js_message), this);

  // Inject bridge script at document creation (before any page script).
  WebKitUserScript* script = webkit_user_script_new(
      kJsBridge,
      WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
      WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
      nullptr, nullptr);
  webkit_user_content_manager_add_script(ucm, script);
  webkit_user_script_unref(script);

  // Create WebKitWebView.
  web_view = WEBKIT_WEB_VIEW(
      webkit_web_view_new_with_user_content_manager(ucm));
  g_object_unref(ucm);

  WebKitSettings* settings = webkit_web_view_get_settings(web_view);
  webkit_settings_set_enable_javascript(settings, TRUE);
  webkit_settings_set_enable_developer_extras(settings, FALSE);

  // Intercept http/https/mailto link navigations.
  g_signal_connect(web_view, "decide-policy",
                   G_CALLBACK(on_decide_policy), this);

  // Tag the GtkWidget so get-child-position can look us up.
  g_object_set_data(G_OBJECT(web_view), "html_view_ptr", this);

  gtk_overlay_add_overlay(overlay, GTK_WIDGET(web_view));
  // Disable input pass-through (overlay child captures events).
  gtk_overlay_set_overlay_pass_through(overlay, GTK_WIDGET(web_view), FALSE);
  gtk_widget_show(GTK_WIDGET(web_view));

  // Method channel: html_view/<id>
  std::string ch_name = "html_view/" + std::to_string(id);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(messenger, ch_name.c_str(),
                                  FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
        static_cast<WebkitView*>(data)->HandleMethod(call);
      },
      this, nullptr);

  // Event channel: html_view/<id>_events
  std::string ev_name = "html_view/" + std::to_string(id) + "_events";
  event_channel = fl_event_channel_new(messenger, ev_name.c_str(),
                                       FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handler(
      event_channel,
      [](FlEventChannel*, FlValue*, FlEventSink* sink, gpointer data) -> FlValue* {
        static_cast<WebkitView*>(data)->event_sink = sink;
        return nullptr;
      },
      [](FlEventChannel*, FlValue*, gpointer data) -> FlValue* {
        static_cast<WebkitView*>(data)->event_sink = nullptr;
        return nullptr;
      },
      this, nullptr);
}

WebkitView::~WebkitView() {
  alive = FALSE;
  if (channel) {
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
    g_object_unref(channel);
    channel = nullptr;
  }
  if (event_channel) {
    g_object_unref(event_channel);
    event_channel = nullptr;
  }
  event_sink = nullptr;
  if (web_view) {
    // Remove from overlay.
    gtk_container_remove(GTK_CONTAINER(overlay), GTK_WIDGET(web_view));
    web_view = nullptr;
  }
}

// ---------------------------------------------------------------------------
// Method dispatch
// ---------------------------------------------------------------------------

void WebkitView::HandleMethod(FlMethodCall* method_call) {
  const char* name = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(name, "loadHtml") == 0) {
    if (fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
      fl_method_call_respond_error(method_call, "bad_args", nullptr, nullptr, nullptr);
      return;
    }
    webkit_web_view_load_html(web_view, fl_value_get_string(args), nullptr);
    fl_method_call_respond_success(method_call, nullptr, nullptr);

  } else if (strcmp(name, "loadUrl") == 0) {
    if (fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
      fl_method_call_respond_error(method_call, "bad_args", nullptr, nullptr, nullptr);
      return;
    }
    webkit_web_view_load_uri(web_view, fl_value_get_string(args));
    fl_method_call_respond_success(method_call, nullptr, nullptr);

  } else if (strcmp(name, "loadAsset") == 0) {
    if (fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
      fl_method_call_respond_error(method_call, "bad_args",
                                   "expected string", nullptr, nullptr);
      return;
    }
    DoLoadAsset(fl_value_get_string(args), method_call);

  } else if (strcmp(name, "eval") == 0) {
    if (fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
      fl_method_call_respond_error(method_call, "bad_args",
                                   "expected string", nullptr, nullptr);
      return;
    }
    DoEval(fl_value_get_string(args), method_call);

  } else if (strcmp(name, "setPosition") == 0 &&
             fl_value_get_type(args) == FL_VALUE_TYPE_LIST &&
             fl_value_get_length(args) == 3) {
    // Args: [x_logical, y_logical, dpr] — GTK uses logical pixels.
    double x = fl_value_get_float(fl_value_get_list_value(args, 0));
    double y = fl_value_get_float(fl_value_get_list_value(args, 1));
    pos_x = static_cast<gint>(x);
    pos_y = static_cast<gint>(y);
    UpdatePosition();
    fl_method_call_respond_success(method_call, nullptr, nullptr);

  } else if (strcmp(name, "setSize") == 0 &&
             fl_value_get_type(args) == FL_VALUE_TYPE_LIST &&
             fl_value_get_length(args) == 3) {
    double w = fl_value_get_float(fl_value_get_list_value(args, 0));
    double h = fl_value_get_float(fl_value_get_list_value(args, 1));
    width  = static_cast<gint>(w);
    height = static_cast<gint>(h);
    UpdatePosition();
    fl_method_call_respond_success(method_call, nullptr, nullptr);

  } else if (strcmp(name, "setVisible") == 0 &&
             fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
    gboolean visible = fl_value_get_bool(args);
    if (visible) {
      gtk_widget_show(GTK_WIDGET(web_view));
    } else {
      gtk_widget_hide(GTK_WIDGET(web_view));
    }
    fl_method_call_respond_success(method_call, nullptr, nullptr);

  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

void WebkitView::DoLoadAsset(const std::string& key, FlMethodCall* call) {
  std::string path = AssetPath(key);
  std::string uri  = "file://" + path;
  webkit_web_view_load_uri(web_view, uri.c_str());
  fl_method_call_respond_success(call, nullptr, nullptr);
}

void WebkitView::DoEval(const std::string& js, FlMethodCall* call) {
  g_object_ref(call);  // keep alive across async
  auto* closure = new EvalClosure{this, call};
  webkit_web_view_evaluate_javascript(web_view, js.c_str(), -1,
                                      nullptr, nullptr, nullptr,
                                      on_eval_done, closure);
}

void WebkitView::UpdatePosition() {
  if (!overlay) return;
  gtk_widget_queue_resize(GTK_WIDGET(overlay));
}

void WebkitView::EmitEvent(const char* type, const char* value) {
  if (!event_sink) return;
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "type",  fl_value_new_string(type));
  fl_value_set_string_take(map, "value", fl_value_new_string(value));
  fl_event_sink_success(event_sink, map, nullptr);
}

// ---------------------------------------------------------------------------
// Asset path helpers
// ---------------------------------------------------------------------------

std::string WebkitView::GetExecutableDir() {
  char buf[PATH_MAX] = {};
  ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (len <= 0) return ".";
  std::string path(buf, len);
  auto pos = path.rfind('/');
  return pos != std::string::npos ? path.substr(0, pos) : ".";
}

std::string WebkitView::AssetPath(const std::string& key) {
  return GetExecutableDir() + "/data/flutter_assets/" + key;
}
