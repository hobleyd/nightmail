#include <windows.h>  // <-- This must be the first Windows header

#include "clipboard_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <vector>

#include "clipboard_image.h"

namespace {

using Channel = flutter::MethodChannel<flutter::EncodableValue>;

// Kept for the app's lifetime: a MethodChannel unregisters its handler when
// destroyed. A closed window's entry is never called again — Dart is what
// calls it — so it is left in place rather than pruned.
std::vector<std::unique_ptr<Channel>> g_channels;

}  // namespace

void RegisterClipboardChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<Channel>(
      messenger, "au.com.sharpblue.nightmail/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "readImage") {
          result->NotImplemented();
          return;
        }
        auto image = ReadClipboardImage();
        if (!image) {
          result->Success();
          return;
        }
        result->Success(flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("bytes"),
             flutter::EncodableValue(std::move(image->bytes))},
            {flutter::EncodableValue("mimeType"),
             flutter::EncodableValue(image->mime_type)},
            {flutter::EncodableValue("name"),
             flutter::EncodableValue(image->name)},
            {flutter::EncodableValue("width"),
             flutter::EncodableValue(image->width)},
            {flutter::EncodableValue("height"),
             flutter::EncodableValue(image->height)},
        }));
      });
  g_channels.push_back(std::move(channel));
}
