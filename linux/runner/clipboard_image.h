#ifndef RUNNER_CLIPBOARD_IMAGE_H_
#define RUNNER_CLIPBOARD_IMAGE_H_

#include <gtk/gtk.h>

// A picture a paste would give, for the chat composer.
typedef struct {
  GBytes* bytes;
  const char* mime_type;  // image/png, image/jpeg or image/gif (static)
  char* name;             // UTF-8
  int width;
  int height;
} ClipboardImage;

void clipboard_image_free(ClipboardImage* image);

// Called once with the picture (owned by the callee, free it with
// clipboard_image_free) or nullptr when a paste is text or nothing.
typedef void (*ClipboardImageCallback)(ClipboardImage* image,
                                       gpointer user_data);

// Reads the picture on [clipboard], asynchronously — the wait_for_* calls
// spin a nested main loop inside a platform-channel handler. Linux
// counterpart of MainFlutterWindow.clipboardImage():
//  - one image file copied in a file manager (text/uri-list) pastes its
//    contents; any other file is a text paste;
//  - anything carrying text (a word processor's copy of a paragraph also
//    holds a picture of it) is a text paste;
//  - otherwise the image as PNG, re-encoded as JPEG and halved until it
//    fits kClipboardImageLimit.
void clipboard_image_read(GtkClipboard* clipboard,
                          ClipboardImageCallback callback, gpointer user_data);

// Graph takes a whole request of 4 MB with the bytes as base64.
#define kClipboardImageLimit 2800000

#endif  // RUNNER_CLIPBOARD_IMAGE_H_
