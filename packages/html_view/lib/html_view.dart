// On web (dart.library.js_interop available), use iframe-based implementations.
// On all native platforms, use method-channel + native-view implementations.
export 'src/html_view_controller.dart'
    if (dart.library.js_interop) 'src/html_view_controller_web.dart';
export 'src/html_view_widget.dart'
    if (dart.library.js_interop) 'src/html_view_widget_web.dart';
export 'src/html_view_overlay_guard.dart';
