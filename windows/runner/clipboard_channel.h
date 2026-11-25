#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter/binary_messenger.h>

// The au.com.sharpblue.nightmail/clipboard channel on one engine: readImage
// answers ReadClipboardImage() as {bytes, mimeType, name, width, height}, or
// null. Call for the main window and every sub-window — the chat pane and
// the chat window both paste.
void RegisterClipboardChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
