#include "window_relay.h"

#include <algorithm>
#include <vector>

namespace {

// One relay channel per engine and name. Linux counterpart of
// windows/runner/window_relay.cpp and MainFlutterWindow.swift's relays: a
// call from any window is broadcast to every window, the caller included
// (macos/CLAUDE.md, "A relay channel needs its handler on the main window
// too").
struct Relay {
  const char* name;
  const char* notify_method;  // what Dart invokes
  const char* broadcast_method;  // what every engine then receives
  struct Entry {
    FlBinaryMessenger* messenger;  // identity only, never dereferenced
    FlMethodChannel* channel;
  };
  std::vector<Entry> channels;
};

Relay g_calendar = {"au.com.sharpblue.nightmail/calendar_refresh",
                    "notifyEventSaved", "eventSaved", {}};
Relay g_drafts = {"au.com.sharpblue.nightmail/drafts_refresh",
                  "notifyDraftChanged", "draftChanged", {}};

void method_call_cb(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  Relay* relay = static_cast<Relay*>(user_data);
  if (g_strcmp0(fl_method_call_get_name(call), relay->notify_method) != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  // A channel whose window has closed is harmless here: its messenger has
  // lost its engine and drops the send. view_finalized_cb prunes it anyway,
  // so channels don't pile up over a day of compose windows.
  for (const Relay::Entry& entry : relay->channels) {
    fl_method_channel_invoke_method(entry.channel, relay->broadcast_method,
                                    nullptr, nullptr, nullptr, nullptr);
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}

void add_channel(Relay* relay, FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, relay->name, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, relay,
                                            nullptr);
  relay->channels.push_back({messenger, channel});
}

void remove_channels(Relay* relay, FlBinaryMessenger* messenger) {
  auto& channels = relay->channels;
  channels.erase(std::remove_if(channels.begin(), channels.end(),
                                [messenger](const Relay::Entry& entry) {
                                  if (entry.messenger != messenger) return false;
                                  g_object_unref(entry.channel);
                                  return true;
                                }),
                 channels.end());
}

void view_finalized_cb(gpointer messenger, GObject*) {
  remove_channels(&g_calendar, static_cast<FlBinaryMessenger*>(messenger));
  remove_channels(&g_drafts, static_cast<FlBinaryMessenger*>(messenger));
}

}  // namespace

void window_relay_register(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "WindowRelay");
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  add_channel(&g_calendar, messenger);
  add_channel(&g_drafts, messenger);

  FlView* view = fl_plugin_registrar_get_view(registrar);
  if (view != nullptr) {
    g_object_weak_ref(G_OBJECT(view), view_finalized_cb, messenger);
  }
}
