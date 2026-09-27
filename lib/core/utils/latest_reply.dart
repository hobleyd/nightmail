import '../../domain/entities/email.dart';

/// The newest message in an email body as plain text, with the quoted
/// history below it cut off.
///
/// Every mail client marks where its quote begins in its own way — Gmail's
/// `gmail_quote` div, Outlook's `appendonsend`/`divRplyFwdMsg` and its
/// `From:/Sent:/To:/Subject:` header block, Apple Mail and Thunderbird's bare
/// `<blockquote>`, the plain-text `On <date>, <who> wrote:` — so the cut is
/// made twice: once on the HTML for the markers that only exist as markup,
/// and again on the text those markup-free clients leave behind.
///
/// Cutting is a heuristic, and a wrong cut that leaves nothing is worse than
/// no cut at all, so a body that ends up blank is returned whole. The
/// signature stays: it is part of what the sender wrote last.
String latestReplyText(String body, EmailBodyType bodyType) {
  final full = bodyType == EmailBodyType.html ? htmlToPlainText(body) : body;
  final trimmedHtml =
      bodyType == EmailBodyType.html ? _cutHtmlQuote(body) : body;
  final text = bodyType == EmailBodyType.html
      ? htmlToPlainText(trimmedHtml)
      : trimmedHtml;
  final latest = _cutTextQuote(text).trim();
  return latest.isNotEmpty ? latest : full.trim();
}

/// Where an HTML client starts its quote. The earliest match wins: a reply
/// to a reply nests them, and everything from the outermost one down is
/// history.
final List<RegExp> _htmlQuoteStarts = [
  RegExp(r'<blockquote[\s>]', caseSensitive: false),
  RegExp(r'<div[^>]*class="[^"]*\bgmail_quote', caseSensitive: false),
  RegExp(r'<div[^>]*id="appendonsend"', caseSensitive: false),
  RegExp(r'<div[^>]*id="divRplyFwdMsg"', caseSensitive: false),
  RegExp(r'<div[^>]*class="[^"]*\bOutlookMessageHeader', caseSensitive: false),
  RegExp(r'<div[^>]*class="[^"]*\bmoz-cite-prefix', caseSensitive: false),
  RegExp(r'<div[^>]*class="[^"]*\byahoo_quoted', caseSensitive: false),
  RegExp(r'<hr[^>]*id="stopSpelling"', caseSensitive: false),
];

String _cutHtmlQuote(String html) {
  var cut = html.length;
  for (final marker in _htmlQuoteStarts) {
    final m = marker.firstMatch(html);
    if (m != null && m.start < cut) cut = m.start;
  }
  return html.substring(0, cut);
}

/// A line that begins the quoted history in plain text.
final List<RegExp> _textQuoteLines = [
  // "On Mon, 28 Sep 2026 at 09:00, Jane <jane@example.com> wrote:"
  RegExp(r'^On .{0,400}wrote:\s*$', caseSensitive: false),
  RegExp(r'^-{2,}\s*Original Message\s*-{2,}\s*$', caseSensitive: false),
  RegExp(r'^-{2,}\s*Forwarded message\s*-{2,}\s*$', caseSensitive: false),
  RegExp(r'^Begin forwarded message:\s*$', caseSensitive: false),
  // Outlook's plain-text separator above its From:/Sent: block.
  RegExp(r'^_{5,}\s*$'),
];

/// Outlook quotes with a header block rather than a marker line: `From:` at
/// the start of a line, followed within a few lines by another header.
final RegExp _fromHeader = RegExp(r'^\s*\*?From:\*?\s', caseSensitive: false);
final RegExp _followingHeader =
    RegExp(r'^\s*\*?(Sent|Date|To|Cc|Subject):\*?\s', caseSensitive: false);

String _cutTextQuote(String text) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    if (_textQuoteLines.any((r) => r.hasMatch(line))) {
      return lines.sublist(0, i).join('\n');
    }
    // "On <date>, <who>" wrapped onto a second line ending in "wrote:".
    if (i + 1 < lines.length &&
        line.startsWith('On ') &&
        RegExp(r'wrote:\s*$').hasMatch(lines[i + 1]) &&
        !line.contains('wrote:')) {
      return lines.sublist(0, i).join('\n');
    }
    if (_fromHeader.hasMatch(line) && _headerBlockFollows(lines, i)) {
      return lines.sublist(0, i).join('\n');
    }
    // A run of `>`-prefixed lines with nothing but blanks after it is the
    // quote itself, with whatever introduced it already cut above.
    if (line.startsWith('>') && _restIsQuoted(lines, i)) {
      return lines.sublist(0, i).join('\n');
    }
  }
  return text;
}

bool _headerBlockFollows(List<String> lines, int from) {
  for (var j = from + 1; j < lines.length && j <= from + 4; j++) {
    if (_followingHeader.hasMatch(lines[j])) return true;
  }
  return false;
}

bool _restIsQuoted(List<String> lines, int from) {
  for (var j = from; j < lines.length; j++) {
    final l = lines[j].trim();
    if (l.isNotEmpty && !l.startsWith('>')) return false;
  }
  return true;
}

/// A readable plain-text rendering of an HTML body: block boundaries become
/// line breaks, tags go, the common entities are decoded, and runs of blank
/// lines are collapsed.
String htmlToPlainText(String html) {
  return html
      .replaceAll(
          RegExp(r'<(style|script|head)[^>]*>.*?</\1>',
              caseSensitive: false, dotAll: true),
          '')
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<div[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</div>', caseSensitive: false), '')
      .replaceAll(RegExp(r'</(tr|li|h[1-6])>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#160;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// "Re: Re: FW: Budget" → "Budget". A meeting called "Re: Budget" reads as a
/// reply, not a meeting. A subject that is nothing but prefixes is kept as it
/// was rather than emptied.
String meetingTitleForSubject(String subject) {
  final stripped = subject
      .replaceFirst(
          RegExp(r'^(\s*(re|fwd?|aw|wg|tr)\s*(\[\d+\])?\s*:\s*)+',
              caseSensitive: false),
          '')
      .trim();
  return stripped.isNotEmpty ? stripped : subject.trim();
}
