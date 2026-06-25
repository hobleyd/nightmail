import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/settings/app_settings.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/inline_attachment.dart';
import '../../injection_container.dart';

class HtmlBodyView extends StatefulWidget {
  const HtmlBodyView({
    super.key,
    required this.html,
    required this.inlineAttachments,
    required this.senderDomain,
  });
  final String html;
  final List<InlineAttachment> inlineAttachments;
  final String senderDomain;

  @override
  State<HtmlBodyView> createState() => _HtmlBodyViewState();
}

class _HtmlBodyViewState extends State<HtmlBodyView> {
  iaw.InAppWebViewController? _inAppController;
  String _inAppInitialHtml = '';
  // Tracks the latest HTML to load; applied in onWebViewCreated if it changed
  // before the controller was ready, or during rapid email switches.
  String _pendingHtml = '';
  bool _webViewReady = false;
  File? _tempHtmlFile;

  WebViewController? _flutterController;

  bool _allowExternalImages = false;
  bool _hasBlockedImages = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS || Platform.isWindows) {
      final (html, blocked) = _buildHtml(allowExternal: false);
      _pendingHtml = html;
      _hasBlockedImages = blocked;
      if (Platform.isWindows) {
        _writeTempFile(html);
      } else {
        _inAppInitialHtml = html;
      }
      // Defer webview creation so the Win32 HWND is fully ready for WebView2
      // composition. One post-frame callback is not enough on all machines;
      // a short real-time delay lets the message pump finish initialising.
      Future.delayed(const Duration(milliseconds: 50), () {
        if (mounted) setState(() => _webViewReady = true);
      });
    } else {
      _initFlutter();
    }
    _loadAlwaysAllowSetting();
  }

  void _writeTempFile(String html) {
    _tempHtmlFile ??= File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}nightmail_email_${identityHashCode(this)}.html',
    );
    _tempHtmlFile!.writeAsStringSync(html);
  }

  void _initFlutter() {
    final (html, blocked) = _buildHtml(allowExternal: false);
    _hasBlockedImages = blocked;
    _flutterController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          final scheme = uri?.scheme ?? '';
          if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') {
            launchUrl(uri!, mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadHtmlString(html);
  }

  bool _hasExternalImages(String html) =>
      RegExp(r'''src\s*=\s*["']?https?://''', caseSensitive: false).hasMatch(html);

  Future<void> _loadAlwaysAllowSetting() async {
    final domains = await sl<AppSettings>().loadExternalImageDomains();
    if (!mounted || !domains.contains(widget.senderDomain)) return;
    _reloadWith(allowExternal: true);
  }

  @override
  void didUpdateWidget(HtmlBodyView old) {
    super.didUpdateWidget(old);
    final emailChanged = old.html != widget.html ||
        old.inlineAttachments != widget.inlineAttachments;
    final senderChanged = old.senderDomain != widget.senderDomain;
    if (emailChanged || senderChanged) {
      _reloadWith(allowExternal: false);
      _loadAlwaysAllowSetting();
    }
  }

  @override
  void dispose() {
    _inAppController = null;
    try { _tempHtmlFile?.deleteSync(); } catch (_) {}
    super.dispose();
  }

  void _reloadWith({required bool allowExternal}) {
    final (html, blocked) = _buildHtml(allowExternal: allowExternal);
    setState(() {
      _allowExternalImages = allowExternal;
      _hasBlockedImages = blocked;
      _pendingHtml = html;
    });
    if (Platform.isWindows) {
      _writeTempFile(html);
      _inAppController?.loadUrl(
        urlRequest: iaw.URLRequest(
          url: iaw.WebUri(Uri.file(_tempHtmlFile!.path).toString()),
        ),
      );
    } else if (Platform.isMacOS) {
      // If the controller isn't ready yet, _pendingHtml is picked up in
      // onWebViewCreated once initialisation completes.
      _inAppController?.loadData(data: html);
    } else {
      _flutterController?.loadHtmlString(html);
    }
  }

  void _downloadOnce() => _reloadWith(allowExternal: true);

  Future<void> _alwaysDownload() async {
    await sl<AppSettings>().saveExternalImageDomain(widget.senderDomain);
    if (mounted) _reloadWith(allowExternal: true);
  }

  (String, bool) _buildHtml({required bool allowExternal}) {
    var resolved = widget.html;
    for (final attachment in widget.inlineAttachments) {
      final cid = attachment.contentId;
      final bare = cid.startsWith('<') && cid.endsWith('>')
          ? cid.substring(1, cid.length - 1)
          : cid;
      final dataUrl =
          'data:${attachment.contentType};base64,${base64Encode(attachment.contentBytes)}';
      resolved = resolved.replaceAll('cid:$bare', dataUrl);
    }

    bool hasBlockedImages = false;
    if (!allowExternal) {
      resolved = resolved.replaceAllMapped(
        RegExp(r'<img\b([^>]*)>', caseSensitive: false),
        (imgMatch) {
          final attrs = imgMatch.group(1)!;
          final newAttrs = attrs.replaceFirstMapped(
            RegExp(
              r'''src=(["'])(https?://[^"']+)\1|src=(https?://[^\s>'"]+)''',
              caseSensitive: false,
            ),
            (sm) {
              hasBlockedImages = true;
              if (sm.group(1) != null) {
                return 'data-blocked-src=${sm.group(1)}${sm.group(2)}${sm.group(1)}';
              } else {
                return 'data-blocked-src=${sm.group(3)}';
              }
            },
          );
          return '<img$newAttrs>';
        },
      );
    }

    const injected = '''
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0">
<style>
* { box-sizing: border-box !important; }
body { margin: 0; padding: 20px 28px 40px; }
img { max-width: 100% !important; height: auto !important; }
img[data-blocked-src] { display: none !important; }
a[href]:hover::after {
  content: attr(href);
  display: block;
  position: fixed;
  bottom: 0; left: 0; right: 0;
  height: 20px; line-height: 20px;
  background: rgba(245,245,245,0.97);
  border-top: 1px solid #ddd;
  padding: 0 12px;
  font-size: 11px;
  font-family: -apple-system, ui-sans-serif, system-ui, sans-serif;
  color: #555;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  z-index: 99999;
  pointer-events: none;
}
@media (prefers-color-scheme: dark) {
  a[href]:hover::after {
    background: rgba(38,38,38,0.97);
    border-top-color: #444;
    color: #aaa;
  }
}
</style>
''';
    final headEnd = resolved.indexOf('</head>');
    if (headEnd != -1) {
      resolved = resolved.substring(0, headEnd) +
          injected +
          resolved.substring(headEnd);
    } else {
      resolved = '<html><head>$injected</head><body>$resolved</body></html>';
    }

    return (resolved, hasBlockedImages);
  }

  @override
  Widget build(BuildContext context) {
    final Widget webviewWidget;
    if (Platform.isMacOS || Platform.isWindows) {
      if (!_webViewReady) {
        webviewWidget = const SizedBox.shrink();
      } else if (Platform.isWindows && _tempHtmlFile != null) {
        webviewWidget = iaw.InAppWebView(
          initialUrlRequest: iaw.URLRequest(
            url: iaw.WebUri(Uri.file(_tempHtmlFile!.path).toString()),
          ),
          initialSettings: iaw.InAppWebViewSettings(
            javaScriptEnabled: false,
            useShouldOverrideUrlLoading: true,
          ),
          onWebViewCreated: (controller) {
            _inAppController = controller;
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final uri = navigationAction.request.url;
            if (uri != null) {
              final scheme = uri.scheme;
              if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') {
                unawaited(launchUrl(Uri.parse(uri.toString()),
                    mode: LaunchMode.externalApplication));
                return iaw.NavigationActionPolicy.CANCEL;
              }
            }
            return iaw.NavigationActionPolicy.ALLOW;
          },
        );
      } else {
        webviewWidget = iaw.InAppWebView(
          initialData: iaw.InAppWebViewInitialData(data: _inAppInitialHtml),
          initialSettings: iaw.InAppWebViewSettings(
            javaScriptEnabled: false,
            useShouldOverrideUrlLoading: true,
          ),
          onWebViewCreated: (controller) {
            _inAppController = controller;
            // Apply any content that arrived before the controller was ready.
            if (_pendingHtml != _inAppInitialHtml) {
              controller.loadData(data: _pendingHtml);
            }
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final uri = navigationAction.request.url;
            if (uri != null) {
              final scheme = uri.scheme;
              if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') {
                unawaited(launchUrl(Uri.parse(uri.toString()),
                    mode: LaunchMode.externalApplication));
                return iaw.NavigationActionPolicy.CANCEL;
              }
            }
            return iaw.NavigationActionPolicy.ALLOW;
          },
        );
      }
    } else {
      final ctrl = _flutterController;
      webviewWidget = ctrl != null
          ? WebViewWidget(controller: ctrl)
          : const SizedBox.shrink();
    }

    return Column(
      children: [
        Expanded(child: webviewWidget),
        if (_hasBlockedImages && !_allowExternalImages)
          _ImageBlockedBar(
            onDownloadOnce: _downloadOnce,
            onAlwaysDownload: _alwaysDownload,
          ),
      ],
    );
  }
}

class _ImageBlockedBar extends StatelessWidget {
  const _ImageBlockedBar({
    required this.onDownloadOnce,
    required this.onAlwaysDownload,
  });

  final VoidCallback onDownloadOnce;
  final VoidCallback onAlwaysDownload;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 29,
      decoration: BoxDecoration(
        color: c.surfacePanel,
        border: Border(top: BorderSide(color: c.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(Icons.hide_image_outlined, size: 13, color: c.textMuted),
          const SizedBox(width: 6),
          Text(
            'External images blocked',
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
          const Spacer(),
          _StatusBarButton(
            label: 'Download once',
            onPressed: onDownloadOnce,
          ),
          const SizedBox(width: 4),
          _StatusBarButton(
            label: 'Always download',
            onPressed: onAlwaysDownload,
          ),
        ],
      ),
    );
  }
}

class _StatusBarButton extends StatefulWidget {
  const _StatusBarButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  State<_StatusBarButton> createState() => _StatusBarButtonState();
}

class _StatusBarButtonState extends State<_StatusBarButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: widget.onPressed,
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 70),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _isPressed
                ? AppColors.accent.withAlpha(70)
                : AppColors.accent.withAlpha(30),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: AppColors.accent.withAlpha(80), width: 0.5),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: c.textTertiary,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}
