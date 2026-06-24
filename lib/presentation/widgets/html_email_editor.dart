import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;

class HtmlEmailEditor extends StatefulWidget {
  const HtmlEmailEditor({
    super.key,
    required this.initialHtml,
    required this.onContentChanged,
    required this.onLinkRequested,
  });

  final String initialHtml;
  final ValueChanged<String> onContentChanged;
  // Called when the user taps the link button. The caller should prompt for a
  // URL and call [HtmlEmailEditorState.insertLink] with the result.
  final VoidCallback onLinkRequested;

  @override
  State<HtmlEmailEditor> createState() => HtmlEmailEditorState();
}

class HtmlEmailEditorState extends State<HtmlEmailEditor> {
  iaw.InAppWebViewController? _controller;
  bool _ready = false;
  String _pendingHtml = '';

  @override
  void initState() {
    super.initState();
    _pendingHtml = widget.initialHtml;
    // Defer webview creation by one frame so the HWND / layer tree is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void didUpdateWidget(HtmlEmailEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialHtml != widget.initialHtml) {
      _pendingHtml = widget.initialHtml;
      _controller?.evaluateJavascript(
        source: 'setContent(${jsonEncode(widget.initialHtml)})',
      );
    }
  }

  Future<void> setContent(String html) async {
    _pendingHtml = html;
    await _controller?.evaluateJavascript(
      source: 'setContent(${jsonEncode(html)})',
    );
  }

  Future<String> getContent() async {
    final result = await _controller?.evaluateJavascript(source: 'getContent()');
    return result?.toString() ?? _pendingHtml;
  }

  Future<void> insertImage(String dataUri, String contentId) async {
    await _controller?.evaluateJavascript(
      source: 'insertImage(${jsonEncode(dataUri)}, ${jsonEncode(contentId)})',
    );
  }

  Future<void> insertLink(String url) async {
    await _controller?.evaluateJavascript(
      source: 'insertLink(${jsonEncode(url)})',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();

    // On Windows, InAppWebView requires a file URL rather than initialData.
    // On macOS/Linux, initialData works fine.
    final Widget webView;
    if (Platform.isWindows) {
      webView = iaw.InAppWebView(
        initialFile: 'assets/editor/editor.html',
        initialSettings: _settings(),
        onWebViewCreated: _onCreated,
        onLoadStop: _onLoadStop,
      );
    } else {
      webView = iaw.InAppWebView(
        initialFile: 'assets/editor/editor.html',
        initialSettings: _settings(),
        onWebViewCreated: _onCreated,
        onLoadStop: _onLoadStop,
      );
    }

    return webView;
  }

  iaw.InAppWebViewSettings _settings() => iaw.InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        useShouldOverrideUrlLoading: false,
        disableContextMenu: false,
      );

  void _onCreated(iaw.InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: 'onContentChanged',
      callback: (args) {
        final html = args.isNotEmpty ? args[0].toString() : '';
        widget.onContentChanged(html);
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onLinkRequest',
      callback: (_) {
        widget.onLinkRequested();
        return null;
      },
    );
  }

  Future<void> _onLoadStop(
      iaw.InAppWebViewController controller, iaw.WebUri? url) async {
    if (_pendingHtml.isNotEmpty) {
      await controller.evaluateJavascript(
        source: 'setContent(${jsonEncode(_pendingHtml)})',
      );
    }
  }
}
