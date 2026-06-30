// Web-specific HtmlViewWidget.
// Uses HtmlElementView to embed the iframe registered in HtmlViewController.
// Conditionally exported by lib/html_view.dart when dart.library.html is present.

import 'package:flutter/widgets.dart';

import 'html_view_controller_web.dart';

class HtmlViewWidget extends StatefulWidget {
  const HtmlViewWidget({
    required this.controller,
    this.scaleFactor,
    super.key,
  });

  final HtmlViewController controller;
  // Ignored on web — Flutter's layout engine handles sizing.
  final double? scaleFactor;

  @override
  State<HtmlViewWidget> createState() => _HtmlViewWidgetState();
}

class _HtmlViewWidgetState extends State<HtmlViewWidget> {
  @override
  Widget build(BuildContext context) {
    final id = widget.controller.viewId;
    if (id == null) return const SizedBox.shrink();
    return HtmlElementView(viewType: 'html_view_$id');
  }
}
