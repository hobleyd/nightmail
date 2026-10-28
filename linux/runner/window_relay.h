#ifndef RUNNER_WINDOW_RELAY_H_
#define RUNNER_WINDOW_RELAY_H_

#include <flutter_linux/flutter_linux.h>

// Registers the calendar_refresh and drafts_refresh relay channels on one
// engine; call for the main view and every sub-window. See window_relay.cc.
void window_relay_register(FlPluginRegistry* registry);

#endif  // RUNNER_WINDOW_RELAY_H_
