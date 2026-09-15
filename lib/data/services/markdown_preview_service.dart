import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';


/// Renders a markdown attachment into a self-contained HTML document for the
/// reading pane's webview preview surface — the same surface the PDF, image
/// and Office previews use.
///
/// **The rendering is Dart-side, unlike `OfficePreviewService`'s JS viewer.**
/// That is forced rather than merely cheaper: the generated document carries
/// `script-src 'none'` (see [markdownPreviewCsp]), so a vendored `marked.js`
/// would be inert in the page it was supposed to render. It also means this
/// page has no sibling files, which is what keeps macOS's directory-scoped
/// `loadFileURL` read access out of the picture.
class MarkdownPreviewService {
  MarkdownPreviewService();

  /// Renders [bytes] and returns the path of the HTML file to hand to
  /// `HtmlViewController.loadUrl`.
  ///
  /// [dark] is the app's own brightness rather than the OS's: the reading pane
  /// knows which theme it is drawing, and `prefers-color-scheme` would follow
  /// the system while the user had the in-app toggle the other way.
  Future<String> buildPreview(List<int> bytes, {required bool dark}) async {
    final html = buildHtml(decodeSource(bytes), dark: dark);

    final tmp = await getTemporaryDirectory();
    final dir = Directory(
      '${tmp.path}${Platform.pathSeparator}nightmail_mdviewer',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // A fresh name per call, for the same reason `buildJsViewer` mints one:
    // the preview is keyed `ValueKey(_previewPath)`, so a path that did not
    // change reuses the existing State and goes on showing the last document.
    final name = 'markdown_${DateTime.now().microsecondsSinceEpoch}.html';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(html);
    return file.path;
  }

  /// The attachment's bytes as text.
  ///
  /// Malformed sequences are replaced rather than thrown on — a markdown file
  /// written in some other encoding should render with a few odd glyphs, not
  /// fail to open — and a leading BOM is dropped, or it lands in the first
  /// heading as a stray character.
  @visibleForTesting
  String decodeSource(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  }

  /// The whole HTML document for [source]. Pure, so the tests never touch the
  /// filesystem.
  @visibleForTesting
  String buildHtml(String source, {required bool dark}) {
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      encodeHtml: true,
    );
    final nodes = document.parse(source);
    sanitizeNodes(nodes);
    final body = md.renderToHtml(nodes);

    return '''<!DOCTYPE html>
<html><head>
<meta http-equiv="Content-Security-Policy" content="$markdownPreviewCsp">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>${dark ? _darkCss : _lightCss}$_commonCss</style>
</head><body><article class="markdown-body">
$body
</article></body></html>''';
  }
}

/// The markdown preview's Content-Security-Policy.
///
/// Deliberately not `contentSecurityPolicy()` from `html_body_view.dart`, and
/// the difference is what the two documents are: that one governs a document
/// **the sender wrote**, where a stylesheet that will not load takes the
/// message's layout with it and inline images arrive as `file:` alongside it.
/// This one governs a document *this app* generated, with the sender's
/// markdown rendered into it and no sibling files at all — so it can name a
/// far shorter list, and `form-action` is worth adding because a raw `<form>`
/// in a markdown file has nowhere legitimate to post.
///
/// Remote images stay refused at every setting. There is no "Download once"
/// here — that belongs to the mail body's status bar, which this surface does
/// not draw — and a `.md` attachment can carry a tracking pixel exactly as a
/// message body can. A refused image falls back to its alt text, which is the
/// thing markdown makes authors write.
const String markdownPreviewCsp =
    "default-src 'none'; "
    "script-src 'none'; "
    "object-src 'none'; "
    "frame-src 'none'; "
    "child-src 'none'; "
    "connect-src 'none'; "
    "base-uri 'none'; "
    "form-action 'none'; "
    "style-src 'unsafe-inline'; "
    'img-src data:;';

/// Schemes a link in a markdown file may point at. Everything else — chiefly
/// `javascript:`, but a relative `./NOTES.md` too, which would resolve against
/// the scratch directory and find nothing — loses its `href` and renders as
/// the text it was written as.
///
/// `script-src 'none'` should already refuse a `javascript:` href, but that is
/// only demonstrable inside a real engine; dropping the attribute is three
/// lines and a unit test.
const _allowedLinkSchemes = <String>{'http', 'https', 'mailto'};

/// Raw HTML tags escaped back into visible text rather than passed through.
///
/// Markdown carries raw HTML by design, and most of it is worth keeping — a
/// `<br>`, a `<details>`, an `<img align>` are ordinary README furniture. What
/// is not is a tag that fetches or executes something, or re-points the rest
/// of the document. Every one of these is already refused by
/// [markdownPreviewCsp]; escaping them as well means a reader *sees* what the
/// file asked for instead of an empty box where a frame was.
///
/// **This is not GFM's tagfilter**, which the renderer offers via
/// `enableTagfilter` and which only fires when the tag name is immediately
/// followed by `>` — so `<script>` is caught and `<script src="…">` is not.
/// That is the spec's shape, and it is precisely the wrong half.
const _escapedRawTags = <String>{
  'script',
  'iframe',
  'object',
  'embed',
  'form',
  'base',
  'link',
  'meta',
  'style',
  'title',
  'textarea',
  'xmp',
  'noembed',
  'noframes',
  'plaintext',
};

final _rawTagStart = RegExp(
  '<(?=/?(?:${_escapedRawTags.join('|')})\\b)',
  caseSensitive: false,
);

/// Walks the parsed document, stripping the destination off any link or image
/// the policy would refuse or the document could not resolve, and escaping the
/// raw HTML tags in [_escapedRawTags].
///
/// A [md.Text] node here is either prose the parser has already HTML-escaped
/// or a run of raw HTML passed through verbatim, so the escaping only ever
/// reaches the second. The walk replaces nodes in their parent's list, which
/// is why it is a function over the child list rather than a [md.NodeVisitor]:
/// a visitor is handed each node but not the list holding it.
@visibleForTesting
void sanitizeNodes(List<md.Node> nodes) {
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    if (node is md.Text) {
      final escaped = node.textContent.replaceAll(_rawTagStart, '&lt;');
      if (escaped != node.textContent) nodes[i] = md.Text(escaped);
      continue;
    }
    if (node is! md.Element) continue;

    switch (node.tag) {
      case 'a':
        final href = node.attributes['href'];
        if (href != null && !_isAllowedUrl(href, allowFragment: true)) {
          node.attributes.remove('href');
        }
      case 'img':
        final src = node.attributes['src'];
        if (src != null && !_isAllowedUrl(src, allowFragment: false)) {
          node.attributes.remove('src');
        }
    }
    final children = node.children;
    if (children != null) sanitizeNodes(children);
  }
}

bool _isAllowedUrl(String url, {required bool allowFragment}) {
  final trimmed = url.trim();
  // A heading anchor — what a README's own table of contents is made of.
  if (allowFragment && trimmed.startsWith('#')) return true;
  // An inline image the author embedded. Held to `image/`, because `data:` is
  // otherwise a way to reach `text/html` from a crafted attachment.
  if (trimmed.toLowerCase().startsWith('data:image/')) return true;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) return false;
  return _allowedLinkSchemes.contains(uri.scheme.toLowerCase());
}

/// Tuned to the reading pane's own surfaces (`AppColors.surfaceReading` and
/// the text hierarchy beside it), so the document does not sit on the pane as
/// a differently-coloured rectangle.
const String _lightCss = '''
:root{--fg:#111827;--body:#374151;--muted:#6B7280;--bg:#FAFAFC;
  --border:#E5E7EB;--code-bg:#EFF1F5;--quote:#6B7280;--link:#4F55D9;
  --row:#F3F4F8;}
''';

const String _darkCss = '''
:root{--fg:#FFFFFF;--body:#D1D5DB;--muted:#9CA3AF;--bg:#0D0F17;
  --border:#2A2D3E;--code-bg:#161A24;--quote:#9CA3AF;--link:#7C83FD;
  --row:#12151F;}
''';

/// GitHub-ish, because that is what a `.md` file is written against.
const String _commonCss = '''
html,body{margin:0;padding:0;background:var(--bg);color:var(--body);}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,
  Helvetica,Arial,sans-serif;font-size:14px;line-height:1.6;}
.markdown-body{max-width:860px;margin:0 auto;padding:24px 28px 56px;
  word-wrap:break-word;}
.markdown-body>*:first-child{margin-top:0;}
h1,h2,h3,h4,h5,h6{margin:22px 0 14px;line-height:1.25;font-weight:600;
  color:var(--fg);}
h1{font-size:1.9em;padding-bottom:.3em;border-bottom:1px solid var(--border);}
h2{font-size:1.45em;padding-bottom:.3em;border-bottom:1px solid var(--border);}
h3{font-size:1.2em;} h4{font-size:1em;} h5{font-size:.9em;}
h6{font-size:.85em;color:var(--muted);}
p,ul,ol,blockquote,table,pre{margin:0 0 14px;}
ul,ol{padding-left:2em;} li{margin:.25em 0;} li>p{margin:.4em 0;}
a{color:var(--link);text-decoration:none;}
a:hover{text-decoration:underline;}
a:not([href]){color:inherit;}
blockquote{padding:0 1em;color:var(--quote);
  border-left:.25em solid var(--border);}
code{font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,
  monospace;font-size:.86em;background:var(--code-bg);padding:.2em .4em;
  border-radius:6px;}
pre{background:var(--code-bg);padding:14px 16px;border-radius:6px;
  overflow-x:auto;}
pre code{background:none;padding:0;font-size:.86em;line-height:1.45;}
table{border-collapse:collapse;display:block;width:max-content;
  max-width:100%;overflow:auto;}
th,td{border:1px solid var(--border);padding:6px 13px;}
th{font-weight:600;} tr:nth-child(2n){background:var(--row);}
hr{height:1px;border:0;background:var(--border);margin:22px 0;}
.markdown-alert{padding:.4em 1em;margin:0 0 14px;
  border-left:.25em solid var(--border);}
.markdown-alert-title{font-weight:600;margin:.4em 0;}
.markdown-alert>*:last-child{margin-bottom:.4em;}
img{max-width:100%;box-sizing:border-box;}
input[type=checkbox]{margin:0 .35em 0 -1.4em;vertical-align:middle;}
.markdown-body>ul.contains-task-list,li.task-list-item{list-style:none;}
''';
