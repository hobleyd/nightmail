#ifndef RUNNER_CLIPBOARD_IMAGE_H_
#define RUNNER_CLIPBOARD_IMAGE_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// A picture a paste would give, for the chat composer.
struct ClipboardImage {
  std::vector<uint8_t> bytes;
  std::string mime_type;  // image/png, image/jpeg or image/gif
  std::string name;       // UTF-8
  int width = 0;
  int height = 0;
};

// The picture on the clipboard, or nullopt when a paste there is text (or
// nothing). Windows counterpart of MainFlutterWindow.clipboardImage():
//  - one image file copied in Explorer (CF_HDROP) pastes its contents, never
//    its icon; any other file is a text paste;
//  - anything carrying text (Word's copy of a paragraph also holds a
//    picture of it) is a text paste;
//  - otherwise the registered "PNG" format (Chrome, Office, Snipping Tool)
//    or CF_DIB (PrtScn) as PNG, re-encoded as JPEG and halved until it fits
//    kClipboardImageLimit.
std::optional<ClipboardImage> ReadClipboardImage();

// Graph takes a whole request of 4 MB with the bytes as base64.
constexpr size_t kClipboardImageLimit = 2800000;

#endif  // RUNNER_CLIPBOARD_IMAGE_H_
