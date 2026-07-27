import 'dart:convert';

import '../../domain/entities/email.dart';
import '../../domain/entities/email_address.dart';
import '../../domain/entities/inline_attachment.dart';
import '../../domain/usecases/send_email.dart';

const _forwardSeparator = '---------- Forwarded message ---------';

class ComposeBodyBuilder {
  ComposeBodyBuilder._();

  static String buildInitialPlainBody({
    required Email? originalEmail,
    required Email? draftEmail,
    required ComposeMode mode,
    String signature = '',
  }) {
    if (draftEmail != null) {
      return draftEmail.bodyType == EmailBodyType.html
          ? stripHtml(draftEmail.body)
          : draftEmail.body;
    }
    // A leading blank line above the signature gives the cursor somewhere to
    // land (offset 0) that isn't inside the signature text itself.
    final sigBlock = signature.isEmpty ? '' : '\n\n$signature';
    final email = originalEmail;
    if (email == null) return sigBlock;

    final from = formatAddress(email.from);

    if (mode == ComposeMode.forward) {
      final bodyText = email.bodyType == EmailBodyType.html
          ? stripHtml(email.body)
          : email.body;
      final to = formatAddressList(email.toRecipients);
      final cc = formatAddressList(email.ccRecipients);
      return '$sigBlock\n\n$_forwardSeparator\n'
          'From: $from\n'
          '${to.isNotEmpty ? 'To: $to\n' : ''}'
          '${cc.isNotEmpty ? 'Cc: $cc\n' : ''}'
          'Date: ${formatDate(email.receivedDateTime)}\n'
          'Subject: ${email.subject}\n\n'
          '$bodyText';
    }

    if (mode != ComposeMode.reply && mode != ComposeMode.replyAll) {
      return sigBlock;
    }

    final to = formatAddressList(email.toRecipients);
    final cc = formatAddressList(email.ccRecipients);
    final header = 'On ${formatDate(email.receivedDateTime)}, $from wrote:\n'
        '${to.isNotEmpty ? 'To: $to\n' : ''}'
        '${cc.isNotEmpty ? 'Cc: $cc\n' : ''}';
    if (email.bodyType == EmailBodyType.html) {
      final bodyText = stripHtml(email.body);
      return '$sigBlock\n\n---\n\n$header\n$bodyText';
    } else {
      final quoted = email.body
          .split('\n')
          .map((line) => '> $line')
          .join('\n');
      return '$sigBlock\n\n$header$quoted';
    }
  }

  static String buildInitialHtmlBody({
    required Email? originalEmail,
    required Email? draftEmail,
    required ComposeMode mode,
    String signature = '',
  }) {
    if (draftEmail != null) {
      final draftBody = draftEmail.bodyType == EmailBodyType.html
          ? draftEmail.body
          : plainToHtml(draftEmail.body);
      return resolveCidImages(draftBody, draftEmail.inlineAttachments);
    }
    // A leading blank div above the signature gives the cursor somewhere to
    // land (setContent always places the caret at the very start) that isn't
    // inside the signature itself.
    final sigBlock = signature.isEmpty ? '' : '<div><br></div>$signature';
    final email = originalEmail;
    if (email == null) return sigBlock;

    final from = formatAddress(email.from);
    final dateStr = formatDate(email.receivedDateTime);
    final fromEsc = const HtmlEscape().convert(from);
    final dateEsc = const HtmlEscape().convert(dateStr);

    if (mode == ComposeMode.forward) {
      final htmlBody = resolveCidImages(
        email.bodyType == EmailBodyType.html
            ? extractHtmlBodyContent(email.body)
            : plainToHtml(email.body),
        email.inlineAttachments,
      );
      final subjectEsc = const HtmlEscape().convert(email.subject);
      final fromHeaderEsc = const HtmlEscape().convert(from);
      final toEsc = const HtmlEscape().convert(formatAddressList(email.toRecipients));
      final ccEsc = const HtmlEscape().convert(formatAddressList(email.ccRecipients));
      return '$sigBlock'
          '<div><br></div>'
          '<div>---------- Forwarded message ---------</div>'
          '<div>From: $fromHeaderEsc</div>'
          '${toEsc.isNotEmpty ? '<div>To: $toEsc</div>' : ''}'
          '${ccEsc.isNotEmpty ? '<div>Cc: $ccEsc</div>' : ''}'
          '<div>Date: $dateEsc</div>'
          '<div>Subject: $subjectEsc</div>'
          '<div><br></div>'
          '<div spellcheck="false" '
          'style="content-visibility:auto;contain-intrinsic-size:500px">$htmlBody</div>';
    }

    if (mode != ComposeMode.reply && mode != ComposeMode.replyAll) {
      return sigBlock;
    }

    final htmlBody = resolveCidImages(
      email.bodyType == EmailBodyType.html
          ? extractHtmlBodyContent(email.body)
          : plainToHtml(email.body),
      email.inlineAttachments,
    );

    final toEsc = const HtmlEscape().convert(formatAddressList(email.toRecipients));
    final ccEsc = const HtmlEscape().convert(formatAddressList(email.ccRecipients));
    return '$sigBlock'
        '<div><br></div>'
        '<div>---------- Original Message ----------</div>'
        '<div>From: $fromEsc</div>'
        '${toEsc.isNotEmpty ? '<div>To: $toEsc</div>' : ''}'
        '${ccEsc.isNotEmpty ? '<div>Cc: $ccEsc</div>' : ''}'
        '<div>Date: $dateEsc</div>'
        '<div><br></div>'
        '<blockquote spellcheck="false" '
        'style="margin:0 0 0 0;border-left:2px solid #ccc;padding-left:12px;color:#666;'
        'content-visibility:auto;contain-intrinsic-size:500px">'
        '$htmlBody'
        '</blockquote>';
  }

  /// Strips the angle brackets a `Content-ID` header carries but a `cid:`
  /// reference does not.
  static String bareContentId(String contentId) {
    final trimmed = contentId.trim();
    return trimmed.startsWith('<') && trimmed.endsWith('>')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
  }

  /// Rewrites `<img src="cid:…">` in [html] to `data:` URLs backed by
  /// [attachments], recording the content id in `data-cid`.
  ///
  /// Quoting a reply or forward carries the original's `cid:` references into
  /// the compose body, but the editor is an asset-loaded WebView with no way to
  /// resolve them — the reading pane's route (images written to disk by
  /// `InlineAttachmentCache`, document loaded from the same directory) isn't
  /// open to a document that lives in the app bundle. So the bytes travel
  /// inline instead, and `data-cid` is what `_substituteInlineImageSrcs` turns
  /// back into `cid:` at send time, matched against the re-attached part.
  ///
  /// References with no matching attachment are left alone: they were already
  /// dangling in the original (an Outlook thread quotes cids from messages
  /// several replies back without re-attaching the parts) and rewriting them
  /// would only hide that.
  static String resolveCidImages(
    String html,
    List<InlineAttachment> attachments,
  ) {
    if (html.isEmpty || attachments.isEmpty) return html;

    final byToken = <String, ({String url, String cid})>{};
    for (final attachment in attachments) {
      final cid = bareContentId(attachment.contentId);
      if (cid.isEmpty) continue;
      final resolved = (
        url: 'data:${attachment.contentType};base64,'
            '${base64Encode(attachment.contentBytes)}',
        cid: cid,
      );
      byToken[cid] = resolved;
      // Gmail may set `Content-ID: <ii_x@mail.gmail.com>` while the body
      // references only `cid:ii_x`; accept the local part too, but never let
      // it shadow an exact match.
      final at = cid.indexOf('@');
      if (at > 0) byToken.putIfAbsent(cid.substring(0, at), () => resolved);
    }
    if (byToken.isEmpty) return html;

    final srcPattern =
        RegExp(r'''\bsrc\s*=\s*(["'])\s*cid:([^"']+?)\s*\1''', caseSensitive: false);
    return html.replaceAllMapped(
      RegExp(r'<img\b[^>]*>', caseSensitive: false),
      (match) {
        final tag = match.group(0)!;
        final src = srcPattern.firstMatch(tag);
        if (src == null) return tag;
        final resolved = byToken[src.group(2)!];
        if (resolved == null) return tag;
        final withData =
            tag.replaceRange(src.start, src.end, 'src="${resolved.url}"');
        if (withData.contains('data-cid=')) return withData;
        // Prepended rather than appended so the tag's closing `>` — which may
        // be `/>` — doesn't need special handling.
        return withData.replaceFirst(
          RegExp(r'<img\b', caseSensitive: false),
          '<img data-cid="${const HtmlEscape().convert(resolved.cid)}"',
        );
      },
    );
  }

  static String formatAddress(EmailAddress addr) {
    return (addr.name != null && addr.name!.isNotEmpty)
        ? '${addr.name} <${addr.address}>'
        : addr.address;
  }

  static String formatAddressList(List<EmailAddress> addresses) {
    return addresses.map(formatAddress).join(', ');
  }

  static String stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<div[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</div>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static String plainToHtml(String text) {
    if (text.isEmpty) return '';
    final escape = const HtmlEscape();
    return text.split('\n').map((line) {
      final escaped = escape.convert(line);
      return escaped.isEmpty ? '<div><br></div>' : '<div>$escaped</div>';
    }).join('');
  }

  /// Extracts the `<body>` content from a full HTML document.
  /// Graph API returns full HTML documents; embedding them verbatim inside a
  /// contenteditable div confuses WebKit's fragment parser.
  static String extractHtmlBodyContent(String html) {
    final open = RegExp(r'<body[^>]*>', caseSensitive: false).firstMatch(html);
    if (open == null) return html;
    final close = RegExp(r'</body>', caseSensitive: false).firstMatch(html);
    if (close == null) return html.substring(open.end);
    return html.substring(open.end, close.start);
  }

  static String formatDate(DateTime dt) {
    final local = dt.toLocal();
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final h = local.hour;
    final min = local.minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '${days[local.weekday]}, ${months[local.month]} ${local.day}, '
        '${local.year} at $h12:$min $amPm';
  }
}
