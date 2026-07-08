#include <windows.h>  // <-- This must be the first Windows header

#include "window_relay.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <vector>

namespace {

using Channel = flutter::MethodChannel<flutter::EncodableValue>;
using ChannelPtr = std::unique_ptr<Channel>;

// Every engine's channel instance must be kept alive for the lifetime of the
// app — a MethodChannel unregisters its handler when destroyed, and a local
// variable going out of scope would silently drop the relay.
std::vector<ChannelPtr> g_calendar_channels;
std::vector<ChannelPtr> g_drafts_channels;

// desktop_multi_window destroys a secondary window's FlutterEngine (and the
// BinaryMessenger our channel was constructed with) as soon as that window
// closes, but the plugin exposes no "window closed" callback to deregister
// the channel at that point — only WindowCreatedCallback. InvokeMethod on a
// channel whose messenger has since been freed dereferences dangling memory
// and crashes the whole process (observed via WER: access violation inside
// flutter::MethodChannel<...>::InvokeMethod). __try/__except turns that crash
// into a catchable signal so the dead entry can be pruned instead.
//
// DoInvoke is split out because InvokeMethod(method, nullptr) materializes a
// temporary std::unique_ptr argument — MSVC forbids __try in a function that
// also requires C++ object unwinding (C2712), so the frame containing __try
// must have zero such objects, including implicit temporaries.
void DoInvoke(Channel* channel, const char* method) {
  channel->InvokeMethod(method, nullptr);
}

bool InvokeMethodSafely(Channel* channel, const char* method) {
  __try {
    DoInvoke(channel, method);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

void BroadcastAndPruneDead(std::vector<ChannelPtr>& channels,
                            const char* method) {
  for (auto it = channels.begin(); it != channels.end();) {
    if (InvokeMethodSafely(it->get(), method)) {
      ++it;
    } else {
      it = channels.erase(it);
    }
  }
}

}  // namespace

void RegisterCalendarRefreshChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<Channel>(
      messenger, "au.com.sharpblue.nightmail/calendar_refresh",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "notifyEventSaved") {
          BroadcastAndPruneDead(g_calendar_channels, "eventSaved");
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  g_calendar_channels.push_back(std::move(channel));
}

void RegisterDraftsRefreshChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<Channel>(
      messenger, "au.com.sharpblue.nightmail/drafts_refresh",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "notifyDraftChanged") {
          BroadcastAndPruneDead(g_drafts_channels, "draftChanged");
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  g_drafts_channels.push_back(std::move(channel));
}
