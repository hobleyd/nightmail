// On web (dart.library.html available), use iframe-based implementations.
// On all native platforms, use method-channel + native-view implementations.
export 'src/html_view_controller.dart'
    if (dart.library.html) 'src/html_view_controller_web.dart';
export 'src/html_view_widget.dart'
    if (dart.library.html) 'src/html_view_widget_web.dart';
