/// Finds URLs that a sender typed as text rather than as links.
///
/// Both message body renderers need this and neither can share the other's
/// machinery: an HTML body is handed to a webview, a plain text body is Flutter
/// text spans. What they do share is the definition of "that is a URL" and,
/// more importantly, of where a URL *ends* — the hard part is not matching
/// `https://` but deciding that the full stop after `.../timesheets.` closed the
/// sentence and not the path.
library;

/// Characters a URL may contain. Everything excluded either cannot appear in a
/// URL unescaped (whitespace, quotes, angle brackets) or would swallow markup
/// in the HTML path. Non-breaking space is listed separately because `\s` does
/// not cover it, and mail is full of them.
const _urlChar = r'''[^\s<>"'`\u00a0]''';

/// A bare URL: an explicit `http`/`https` scheme, or a schemeless host that
/// starts with `www.` and has at least two labels — enough to be sure it is a
/// host and not prose. Anything without either marker is left alone; guessing
/// at `example.com/page` turns file names and version numbers into links.
///
/// The lookbehind keeps a match from starting inside something longer. `@`
/// stops the tail of an email address becoming a link of its own
/// (`someone@www.example.com`), and the rest stop a match beginning part-way
/// through a URL the pattern has already rejected.
final RegExp bareUrlPattern = RegExp(
  r'(?<![\w@./:-])'
  '(?:https?://$_urlChar+'
  r'|www\.[\w-]+(?:\.[\w-]+)+'
  '$_urlChar*)',
  caseSensitive: false,
);

/// Trailing text that punctuated the sentence rather than the URL. `&amp;` is
/// included because a URL ending in a query separator has had its last
/// parameter cut off by the prose around it.
final _urlTail = RegExp(
  r'''(?:[.,;:!?"'«»‘’“”]|&amp;)+$''',
  caseSensitive: false,
);

const _closers = {')': '(', ']': '[', '}': '{'};

/// Strips what followed the URL rather than belonging to it.
///
/// Closing brackets are only dropped when they are unmatched, because a URL may
/// legitimately contain a balanced pair — Wikipedia and SharePoint both do — but
/// a wrapping `(see https://x/y)` must not keep the paren that closed the aside.
String trimUrlTail(String url) {
  var trimmed = url;
  while (trimmed.isNotEmpty) {
    final tail = _urlTail.firstMatch(trimmed);
    if (tail != null && tail.start > 0) {
      trimmed = trimmed.substring(0, tail.start);
      continue;
    }
    final last = trimmed[trimmed.length - 1];
    final opener = _closers[last];
    if (opener != null && _count(trimmed, last) > _count(trimmed, opener)) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
      continue;
    }
    break;
  }
  return trimmed;
}

int _count(String s, String ch) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == ch) n++;
  }
  return n;
}

/// The URL to actually open for text matched by [bareUrlPattern]. A `www.` host
/// is displayed as the sender wrote it but needs a scheme to be navigable.
String hrefForBareUrl(String matched) =>
    matched.toLowerCase().startsWith('www.') ? 'https://$matched' : matched;

/// A cheaper first look than [bareUrlPattern] — no lookbehind, nothing to
/// backtrack. Worth having because most text nodes in a mail body are a few
/// words long and the whole document is checked as well, and worth being a
/// pattern rather than a `toLowerCase().contains(...)`, which would copy a
/// megabyte-scale body to answer a question about six characters.
final _urlHint = RegExp(r'https?://|www\.', caseSensitive: false);

bool _mayContainUrl(String text) =>
    text.length >= 8 && _urlHint.hasMatch(text);

// ---------------------------------------------------------------------------
// Plain text bodies
// ---------------------------------------------------------------------------

/// One run of a plain text body: either literal text, or a URL to link.
class LinkifiedRun {
  const LinkifiedRun.text(this.text)
      : url = null;
  const LinkifiedRun.link(this.text, this.url);

  /// What the reader sees, exactly as the sender wrote it.
  final String text;

  /// The URL to open, or null when this run is not a link.
  final String? url;

  bool get isLink => url != null;
}

/// Splits [text] into alternating text and link runs, in order. A body with no
/// URLs comes back as a single text run.
List<LinkifiedRun> linkifyPlainText(String text) {
  if (!_mayContainUrl(text)) return [LinkifiedRun.text(text)];

  final runs = <LinkifiedRun>[];
  var cursor = 0;
  for (final match in bareUrlPattern.allMatches(text)) {
    final url = trimUrlTail(match[0]!);
    if (match.start > cursor) {
      runs.add(LinkifiedRun.text(text.substring(cursor, match.start)));
    }
    runs.add(LinkifiedRun.link(url, hrefForBareUrl(url)));
    cursor = match.start + url.length;
  }
  if (cursor < text.length) {
    runs.add(LinkifiedRun.text(text.substring(cursor)));
  }
  return runs;
}

// ---------------------------------------------------------------------------
// HTML bodies
// ---------------------------------------------------------------------------

/// Elements whose contents must be left exactly as they are. `a` is the one
/// that matters — an anchor inside an anchor is invalid and the browser
/// unnests it, which loses the outer link — but a URL written in a stylesheet
/// or a `<title>` is not body text either.
const _opaqueElements = {'a', 'script', 'style', 'textarea', 'title', 'svg'};

final _tagName = RegExp(r'^<\s*(/?)\s*([a-zA-Z][^\s/>]*)');

/// Wraps bare URLs in [html]'s text with anchors, leaving markup untouched.
///
/// Deliberately a scanner over the source rather than a parse: the body is
/// about to be handed to a webview as text, so re-serialising a DOM would risk
/// changing far more than the links, and the parse would cost more than every
/// other step in preparing the document. All the scanner needs to know is
/// whether it is between tags and whether an enclosing element is opaque.
///
/// Getting a real `<a href>` in is the whole point of doing this here: link
/// hover reporting, click-to-open and copy-link are already wired to anchors
/// in the page, so a linkified URL picks all three up for free.
String linkifyHtml(String html) {
  if (!_mayContainUrl(html)) return html;

  final out = StringBuffer();
  final openOpaque = <String>[];
  var pos = 0;

  while (pos < html.length) {
    final lt = html.indexOf('<', pos);
    final textEnd = lt == -1 ? html.length : lt;
    if (textEnd > pos) {
      final text = html.substring(pos, textEnd);
      out.write(openOpaque.isEmpty ? _linkifyTextNode(text) : text);
    }
    if (lt == -1) break;

    // Comments and CDATA hide `>` characters, so they are skipped whole.
    final int tagEnd;
    if (html.startsWith('<!--', lt)) {
      final close = html.indexOf('-->', lt);
      tagEnd = close == -1 ? html.length : close + 3;
    } else {
      final close = html.indexOf('>', lt);
      tagEnd = close == -1 ? html.length : close + 1;
    }
    final tag = html.substring(lt, tagEnd);
    out.write(tag);
    _trackOpaque(tag, openOpaque);
    pos = tagEnd;
  }

  return out.toString();
}

/// Maintains the stack of open opaque elements as [tag] is passed through.
void _trackOpaque(String tag, List<String> openOpaque) {
  final match = _tagName.firstMatch(tag);
  if (match == null) return;
  final name = match[2]!.toLowerCase();
  if (!_opaqueElements.contains(name)) return;

  if (match[1] == '/') {
    // Close the matching element and anything left dangling inside it.
    final open = openOpaque.lastIndexOf(name);
    if (open != -1) openOpaque.removeRange(open, openOpaque.length);
  } else if (!tag.endsWith('/>')) {
    openOpaque.add(name);
  }
}

/// Entity references that end a URL wherever they appear. In a text node these
/// are how characters a URL cannot contain unescaped arrive — a space, a quote,
/// an angle bracket — so they read as URL-legal characters to the pattern and
/// run it straight on into the next word. `&amp;` is deliberately not one of
/// them: that is how a query string's own separators arrive.
final _boundaryEntity = RegExp(
  r'&(?:nbsp|lt|gt|quot|apos|#160|#39|#34|#x[aA]0);',
  caseSensitive: false,
);

/// The URL inside [match], where [match] came from an HTML text node.
String _urlFromTextNode(String match) {
  final boundary = _boundaryEntity.firstMatch(match);
  return trimUrlTail(
    boundary == null ? match : match.substring(0, boundary.start),
  );
}

String _linkifyTextNode(String text) {
  if (!_mayContainUrl(text)) return text;
  final out = StringBuffer();
  var cursor = 0;
  for (final match in bareUrlPattern.allMatches(text)) {
    // Already escaped for a text node, so it is also safe in an attribute:
    // the pattern excludes both quote characters and `<`.
    final url = _urlFromTextNode(match[0]!);
    out
      ..write(text.substring(cursor, match.start))
      ..write('<a href="${hrefForBareUrl(url)}">$url</a>');
    cursor = match.start + url.length;
  }
  out.write(text.substring(cursor));
  return out.toString();
}
