#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// The au.com.sharpblue.nightmail/clipboard channel on one engine: readImage
// answers clipboard_image_read() as {bytes, mimeType, name, width, height},
// or null. Call for the main view and every sub-window — the chat pane and
// the chat window both paste.
void clipboard_channel_register(FlPluginRegistry* registry);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
