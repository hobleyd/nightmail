import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;
import 'package:webview_flutter/webview_flutter.dart';

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
  iaw.InAppWebViewController? _inAppController;
  WebViewController? _flutterController;
  bool _ready = false;
  String _pendingHtml = '';

  @override
  void initState() {
    super.initState();
    _pendingHtml = widget.initialHtml;
    if (Platform.isLinux) {
      _initFlutterController();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  void _initFlutterController() {
    _flutterController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'onContentChanged',
        onMessageReceived: (msg) => widget.onContentChanged(msg.message),
      )
      ..addJavaScriptChannel(
        'onLinkRequest',
        onMessageReceived: (_) => widget.onLinkRequested(),
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) async {
          if (_pendingHtml.isNotEmpty) {
            await _flutterController
                ?.runJavaScript('setContent(${jsonEncode(_pendingHtml)})');
          }
        },
      ))
      ..loadFlutterAsset('assets/editor/editor.html');
  }

  @override
  void dispose() {
    _inAppController = null;
    super.dispose();
  }

  @override
  void didUpdateWidget(HtmlEmailEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialHtml != widget.initialHtml) {
      _pendingHtml = widget.initialHtml;
      if (Platform.isLinux) {
        _flutterController
            ?.runJavaScript('setContent(${jsonEncode(widget.initialHtml)})');
      } else {
        _inAppController?.evaluateJavascript(
          source: 'setContent(${jsonEncode(widget.initialHtml)})',
        );
      }
    }
  }

  Future<void> setContent(String html) async {
    _pendingHtml = html;
    if (Platform.isLinux) {
      await _flutterController?.runJavaScript('setContent(${jsonEncode(html)})');
    } else {
      await _inAppController?.evaluateJavascript(
        source: 'setContent(${jsonEncode(html)})',
      );
    }
  }

  Future<String> getContent() async {
    if (Platform.isLinux) {
      final result = await _flutterController
          ?.runJavaScriptReturningResult('getContent()');
      if (result == null) return _pendingHtml;
      // runJavaScriptReturningResult returns JSON-encoded strings (with quotes)
      try {
        return jsonDecode(result.toString()) as String;
      } catch (_) {
        return result.toString();
      }
    } else {
      final result =
          await _inAppController?.evaluateJavascript(source: 'getContent()');
      return result?.toString() ?? _pendingHtml;
    }
  }

  Future<void> insertImage(String dataUri, String contentId) async {
    final js =
        'insertImage(${jsonEncode(dataUri)}, ${jsonEncode(contentId)})';
    if (Platform.isLinux) {
      await _flutterController?.runJavaScript(js);
    } else {
      await _inAppController?.evaluateJavascript(source: js);
    }
  }

  Future<void> insertLink(String url) async {
    final js = 'insertLink(${jsonEncode(url)})';
    if (Platform.isLinux) {
      await _flutterController?.runJavaScript(js);
    } else {
      await _inAppController?.evaluateJavascript(source: js);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();

    if (Platform.isLinux) {
      final ctrl = _flutterController;
      return ctrl != null
          ? WebViewWidget(controller: ctrl)
          : const SizedBox.shrink();
    }

    return iaw.InAppWebView(
      initialFile: 'assets/editor/editor.html',
      initialSettings: _settings(),
      onWebViewCreated: _onCreated,
      onLoadStop: _onLoadStop,
    );
  }

  iaw.InAppWebViewSettings _settings() => iaw.InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        useShouldOverrideUrlLoading: false,
        disableContextMenu: false,
      );

  void _onCreated(iaw.InAppWebViewController controller) {
    _inAppController = controller;
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
