import 'dart:convert';

import '../../domain/entities/email.dart';
import '../../domain/entities/email_address.dart';
import '../../domain/usecases/send_email.dart';

const _forwardSeparator = '---------- Forwarded message ---------';

class ComposeBodyBuilder {
  ComposeBodyBuilder._();

  static String buildInitialPlainBody({
    required Email? originalEmail,
    required Email? draftEmail,
    required ComposeMode mode,
  }) {
    if (draftEmail != null) {
      return draftEmail.bodyType == EmailBodyType.html
          ? stripHtml(draftEmail.body)
          : draftEmail.body;
    }
    final email = originalEmail;
    if (email == null) return '';

    final from = formatAddress(email.from);

    if (mode == ComposeMode.forward) {
      final bodyText = email.bodyType == EmailBodyType.html
          ? stripHtml(email.body)
          : email.body;
      final to = formatAddressList(email.toRecipients);
      final cc = formatAddressList(email.ccRecipients);
      return '\n\n$_forwardSeparator\n'
          'From: $from\n'
          '${to.isNotEmpty ? 'To: $to\n' : ''}'
          '${cc.isNotEmpty ? 'Cc: $cc\n' : ''}'
          'Date: ${formatDate(email.receivedDateTime)}\n'
          'Subject: ${email.subject}\n\n'
          '$bodyText';
    }

    if (mode != ComposeMode.reply && mode != ComposeMode.replyAll) {
      return '';
    }

    final to = formatAddressList(email.toRecipients);
    final cc = formatAddressList(email.ccRecipients);
    final header = 'On ${formatDate(email.receivedDateTime)}, $from wrote:\n'
        '${to.isNotEmpty ? 'To: $to\n' : ''}'
        '${cc.isNotEmpty ? 'Cc: $cc\n' : ''}';
    if (email.bodyType == EmailBodyType.html) {
      final bodyText = stripHtml(email.body);
      return '\n\n---\n\n$header\n$bodyText';
    } else {
      final quoted = email.body
          .split('\n')
          .map((line) => '> $line')
          .join('\n');
      return '\n\n$header$quoted';
    }
  }

  static String buildInitialHtmlBody({
    required Email? originalEmail,
    required Email? draftEmail,
    required ComposeMode mode,
  }) {
    if (draftEmail != null) {
      return draftEmail.bodyType == EmailBodyType.html
          ? draftEmail.body
          : plainToHtml(draftEmail.body);
    }
    final email = originalEmail;
    if (email == null) return '';

    final from = formatAddress(email.from);
    final dateStr = formatDate(email.receivedDateTime);
    final fromEsc = const HtmlEscape().convert(from);
    final dateEsc = const HtmlEscape().convert(dateStr);

    if (mode == ComposeMode.forward) {
      final htmlBody = email.bodyType == EmailBodyType.html
          ? email.body
          : plainToHtml(email.body);
      final subjectEsc = const HtmlEscape().convert(email.subject);
      final fromHeaderEsc = const HtmlEscape().convert(from);
      final toEsc = const HtmlEscape().convert(formatAddressList(email.toRecipients));
      final ccEsc = const HtmlEscape().convert(formatAddressList(email.ccRecipients));
      return '<div><br></div>'
          '<div>---------- Forwarded message ---------</div>'
          '<div>From: $fromHeaderEsc</div>'
          '${toEsc.isNotEmpty ? '<div>To: $toEsc</div>' : ''}'
          '${ccEsc.isNotEmpty ? '<div>Cc: $ccEsc</div>' : ''}'
          '<div>Date: $dateEsc</div>'
          '<div>Subject: $subjectEsc</div>'
          '<div><br></div>'
          '<div spellcheck="false" style="contain:layout style">$htmlBody</div>';
    }

    if (mode != ComposeMode.reply && mode != ComposeMode.replyAll) {
      return '';
    }

    final htmlBody = email.bodyType == EmailBodyType.html
        ? email.body
        : plainToHtml(email.body);

    final toEsc = const HtmlEscape().convert(formatAddressList(email.toRecipients));
    final ccEsc = const HtmlEscape().convert(formatAddressList(email.ccRecipients));
    return '<div><br></div>'
        '<div>---------- Original Message ----------</div>'
        '<div>From: $fromEsc</div>'
        '${toEsc.isNotEmpty ? '<div>To: $toEsc</div>' : ''}'
        '${ccEsc.isNotEmpty ? '<div>Cc: $ccEsc</div>' : ''}'
        '<div>Date: $dateEsc</div>'
        '<div><br></div>'
        '<blockquote spellcheck="false" '
        'style="margin:0 0 0 0;border-left:2px solid #ccc;padding-left:12px;color:#666;contain:layout style">'
        '$htmlBody'
        '</blockquote>';
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
