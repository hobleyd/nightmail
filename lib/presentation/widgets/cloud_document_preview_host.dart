import 'package:flutter/widgets.dart';

import '../../domain/entities/cloud_document.dart';

/// How a body link to a cloud document reaches the surface that can preview it.
///
/// The two body renderers share nothing but `openBodyLink`, and neither knows
/// anything about the pane it is drawn in — so the pane that *has* a preview
/// surface publishes a handler here instead of every widget between them
/// growing a callback parameter for it.
///
/// A surface with no host in scope is the ordinary case, not an oversight: the
/// standalone email window draws a body and has nowhere to put a preview, so
/// `openBodyLink` finds nothing, and the link opens in the browser exactly as
/// it did before any of this existed.
typedef CloudDocumentPreviewCallback = Future<bool> Function(
    CloudDocumentLink link);

class CloudDocumentPreviewHost extends InheritedWidget {
  const CloudDocumentPreviewHost({
    super.key,
    required this.onPreview,
    required super.child,
  });

  /// Fetches and shows [link], answering whether it did. **False means "open it
  /// in the browser after all"** — no account can reach the file, the reader
  /// declined the permission, the document is not something we can draw. The
  /// handler is responsible for saying why if there is anything worth saying;
  /// the caller only needs to know whether to fall back.
  final CloudDocumentPreviewCallback onPreview;

  /// Read without subscribing: this is consulted from a link-click handler, not
  /// during a build, so there is no dependency to register and
  /// `dependOnInheritedWidgetOfExactType` would mark the reading widget dirty
  /// for a value it never draws.
  static CloudDocumentPreviewCallback? maybeOf(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<CloudDocumentPreviewHost>()
        ?.onPreview;
  }

  @override
  bool updateShouldNotify(CloudDocumentPreviewHost oldWidget) =>
      oldWidget.onPreview != onPreview;
}
