import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html_view/html_view.dart';

class HtmlEmailEditor extends StatefulWidget {
  const HtmlEmailEditor({
    super.key,
    required this.initialHtml,
    required this.onContentChanged,
    required this.onLinkRequested,
    this.autofocus = false,
  });

  final String initialHtml;
  final ValueChanged<String> onContentChanged;
  /// Called when the user taps the link button in the editor toolbar.
  /// The caller should prompt for a URL and call [insertLink].
  final VoidCallback onLinkRequested;
  /// Focuses the editor as soon as its content finishes loading. The webview
  /// loads asynchronously, so this can't be done with a synchronous
  /// `requestFocus()` call from the parent the way the plain-text body works.
  final bool autofocus;

  @override
  State<HtmlEmailEditor> createState() => HtmlEmailEditorState();
}

class HtmlEmailEditorState extends State<HtmlEmailEditor> {
  late final HtmlViewController _controller;
  StreamSubscription<String>? _contentSub;
  StreamSubscription<void>?   _linkSub;
  StreamSubscription<void>?   _loadedSub;

  String _pendingHtml = '';
  bool   _disposed    = false;

  @override
  void initState() {
    super.initState();
    _pendingHtml = widget.initialHtml;

    _controller = HtmlViewController();
    _controller.initialize().then((_) {
      if (_disposed) return;
      _contentSub = _controller.onContentChanged.listen((html) {
        if (mounted) widget.onContentChanged(html);
      });
      _linkSub = _controller.onLinkRequest.listen((_) {
        if (mounted) widget.onLinkRequested();
      });
      _loadedSub = _controller.onPageLoaded.listen((_) async {
        if (_disposed) return;
        if (_pendingHtml.isNotEmpty) {
          await _controller.eval('setContent(${jsonEncode(_pendingHtml)})');
        }
        if (widget.autofocus && !_disposed) {
          await _controller.eval('focusEditor()');
        }
      });
      _controller.loadAsset('assets/editor/editor.html');
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _contentSub?.cancel();
    _linkSub?.cancel();
    _loadedSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Public API (called by compose_dialog.dart)
  // -------------------------------------------------------------------------

  Future<void> setContent(String html) async {
    _pendingHtml = html;
    await _controller.eval('setContent(${jsonEncode(html)})');
  }

  Future<String> getContent() async {
    // Returns JSON-encoded string from JS; strip outer quotes.
    final raw = await _controller.eval('getContent()');
    if (raw == null || raw == 'null') return _pendingHtml;
    // JS result is JSON: "\"<html>\"" — decode it.
    try {
      return jsonDecode(raw) as String;
    } catch (_) {
      return raw;
    }
  }

  Future<void> insertImage(String dataUri, String contentId) async {
    await _controller.eval(
        'insertImage(${jsonEncode(dataUri)}, ${jsonEncode(contentId)})');
  }

  Future<void> insertLink(String url) async {
    await _controller.eval('insertLink(${jsonEncode(url)})');
  }

  Future<void> saveSelection() async {
    await _controller.eval('saveSelection()');
  }

  Future<void> insertAtCursor(String text) async {
    await _controller.eval('insertAtSaved(${jsonEncode(text)})');
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return HtmlViewWidget(controller: _controller);
  }
}
