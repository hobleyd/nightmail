#ifndef RUNNER_WINDOW_RELAY_H_
#define RUNNER_WINDOW_RELAY_H_

#include <flutter/binary_messenger.h>

// Each desktop_multi_window secondary window gets its own FlutterEngine with
// its own BinaryMessenger, so a MethodChannel registered on one engine is
// invisible to the others — calling it from a different engine throws
// MissingPluginException. These relays register the same named channel on
// every engine (main window + each secondary window) and forward a "notify*"
// call received on any of them out to all of them, mirroring the
// calendarNotifyChannels/draftsRefreshChannels broadcast relay implemented
// natively for macOS in MainFlutterWindow.swift.
void RegisterCalendarRefreshChannel(flutter::BinaryMessenger* messenger);
void RegisterDraftsRefreshChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_WINDOW_RELAY_H_
