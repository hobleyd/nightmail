import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';

import '../../domain/entities/email.dart';
import '../../domain/entities/email_attachment.dart';
import '../../domain/entities/inline_attachment.dart';
import '../models/email_address_model.dart';
import '../models/email_model.dart';

/// Inputs for [parseEmlBytes]. `compute()` takes one argument, so the id
/// travels beside the bytes rather than being applied afterwards.
class EmlParseParams {
  const EmlParseParams({required this.bytes, required this.id});

  final Uint8List bytes;
  final String id;
}

/// Inputs for [extractEmlAttachmentBytes].
class EmlAttachmentRequest {
  const EmlAttachmentRequest({required this.bytes, required this.partId});

  final Uint8List bytes;

  /// The positional path [emlPartIdOf] recovers from an attachment's id.
  final String partId;
}

/// The MIME path inside a previewed `.eml` that [attachmentId] refers to.
///
/// Attachment ids are namespaced `<emlId>#<partId>` so that a part of one
/// previewed message cannot collide with a part of another, nor with a real
/// provider id. Only the tail addresses the MIME tree.
String emlPartIdOf(String attachmentId) {
  final hash = attachmentId.lastIndexOf('#');
  return hash == -1 ? attachmentId : attachmentId.substring(hash + 1);
}

/// Parses raw `message/rfc822` bytes into an [Email]. `compute()` entry point.
///
/// Top-level because it runs in the isolate — see [EmlParser.parse] for why it
/// goes there at all.
Email parseEmlBytes(EmlParseParams params) {
  final text = utf8.decode(params.bytes, allowMalformed: true);
  final msg = MimeMessage.parseFromText(text);
  return _toEmail(msg, id: params.id);
}

class EmlParser {
  /// Parses an `.eml` — an attached or forwarded message — off the UI isolate.
  ///
  /// Same rule, and the same reason, as every other message parser in the app:
  /// the MIME being parsed carries the body *and* every inline image as base64,
  /// so the decode is the expensive half and it must not run here. This is the
  /// shape `ImapDatasourceImpl.parseFullImapMessage` already uses — bytes in,
  /// model out, nothing that needs the network.
  Future<Email> parse(Uint8List bytes, {required String id}) =>
      compute(parseEmlBytes, EmlParseParams(bytes: bytes, id: id));

  /// The bytes of one attachment inside a previewed `.eml`.
  ///
  /// [attachmentId] is the namespaced id [Email.attachments] carries; only its
  /// tail addresses the MIME tree. Off the isolate for the same reason [parse]
  /// is — it re-parses the whole message to reach one part.
  Future<Uint8List?> attachmentBytes(
    Uint8List emlBytes, {
    required String attachmentId,
  }) =>
      compute(
        extractEmlAttachmentBytes,
        EmlAttachmentRequest(
          bytes: emlBytes,
          partId: emlPartIdOf(attachmentId),
        ),
      );
}

Email _toEmail(MimeMessage msg, {required String id}) {
  final date = msg.decodeDate() ?? DateTime.now().toUtc();

  final html = msg.decodeTextHtmlPart();
  final String body;
  final EmailBodyType bodyType;
  if (html != null && html.isNotEmpty) {
    body = html;
    bodyType = EmailBodyType.html;
  } else {
    body = msg.decodeTextPlainPart() ?? '';
    bodyType = EmailBodyType.text;
  }

  final from = msg.from?.firstOrNull;
  final fromModel = from != null
      ? EmailAddressModel(address: from.email, name: from.personalName ?? '')
      : const EmailAddressModel(address: '', name: '');

  List<EmailAddressModel> mapAddresses(List<MailAddress>? list) => (list ?? [])
      .map((a) => EmailAddressModel(address: a.email, name: a.personalName ?? ''))
      .toList();

  final preview = msg.decodeTextPlainPart() ?? '';
  final attachments = _collectAttachments(msg, emlId: id);

  return EmailModel(
    id: id,
    subject: msg.decodeSubject() ?? '(No Subject)',
    from: fromModel,
    toRecipients: mapAddresses(msg.to),
    ccRecipients: mapAddresses(msg.cc),
    bodyPreview: preview.length > 200 ? preview.substring(0, 200) : preview,
    body: body,
    bodyType: bodyType,
    isRead: true,
    receivedDateTime: date,
    importance: EmailImportance.normal,
    // Derived from the list actually collected rather than from
    // `msg.hasAttachments()`, which matches on `Content-Disposition` and so
    // disagrees with the walk below for a part named only by a
    // `Content-Type; name=` — a chip on screen while the flag said none.
    hasAttachments: attachments.isNotEmpty,
    attachments: attachments,
    inlineAttachments: bodyType == EmailBodyType.html
        ? _collectInlineAttachments(msg)
        : const [],
  );
}

/// The `cid:`-referenced images of a message, with their bytes.
///
/// Without these every inline image in a previewed `.eml` drew as a broken
/// glyph: `HtmlBodyView` resolves `cid:` tokens from this list alone, and the
/// reading pane's CSP is `img-src data: file:`, so an unresolved token is a
/// reference the policy refuses as well as one nothing satisfies.
///
/// The tree is walked directly rather than through `findContentInfo`, which
/// matches `Content-Disposition` *exactly* and so answers neither query for the
/// very common part that carries a `Content-Id` and no disposition header at
/// all. Disposition is the wrong signal here twice over: Gmail tags pasted
/// inline images `Content-Disposition: attachment` while still referencing them
/// by `cid:` in the HTML — the same quirk `gmail_message_parser` documents, and
/// a forwarded Gmail message is the common case for an `.eml`. A Content-Id on
/// a non-text part is the reliable signal.
List<InlineAttachment> _collectInlineAttachments(MimeMessage msg) {
  final result = <InlineAttachment>[];
  final seen = <String>{};
  _walkForInline(msg, result, seen);
  return result;
}

void _walkForInline(
  MimePart part,
  List<InlineAttachment> out,
  Set<String> seen,
) {
  final mediaType = part.getHeaderContentType()?.mediaType;

  final cid = part.getHeaderValue('content-id')?.trim();
  if (cid != null && cid.isNotEmpty && mediaType != null && !mediaType.isText) {
    if (seen.add(cid)) {
      Uint8List? bytes;
      try {
        bytes = part.decodeContentBinary();
      } catch (_) {
        // A part this build of enough_mail cannot decode costs one image, not
        // the whole preview.
        bytes = null;
      }
      if (bytes != null) {
        out.add(InlineAttachment(
          contentId: cid,
          contentType: mediaType.text,
          contentBytes: bytes,
        ));
      }
    }
  }

  // Not descended into: an encapsulated message is a *forward inside the
  // forward*, and enough_mail hangs its parts directly off the rfc822 part
  // with no node in between. Its images are referenced by its own body, which
  // is not the body being rendered, so decoding them would be megabytes of
  // base64 spent on cid tokens nothing asks for.
  if (mediaType?.sub == MediaSubtype.messageRfc822) return;

  for (final child in part.parts ?? const <MimePart>[]) {
    _walkForInline(child, out, seen);
  }
}

// ---------------------------------------------------------------------------
// Parts
// ---------------------------------------------------------------------------

/// Visits every part of [part], numbering each with its own positional path
/// (`2`, `3.1`).
///
/// The numbering is generated here rather than read off enough_mail's
/// `fetchId`, which collapses: `collectContentInfo` hands a child of a
/// `message/rfc822` part the *parent's* id instead of appending an index, so
/// every attachment inside a forwarded message ends up sharing one id. That is
/// `EmailLocalDatasourceImpl.attachmentParseVersion` 2 — the chips look right
/// and every one of them fetches the same wrong bytes.
///
/// [_collectAttachments] and [extractEmlAttachmentBytes] both run this, so the
/// path a chip carries and the path the bytes are fetched by cannot drift.
void _visitParts(
  MimePart part,
  String path,
  void Function(MimePart part, String path) visit,
) {
  visit(part, path);

  // An encapsulated message is offered whole, as its own `.eml`. Descending
  // would flatten its attachments into its parent's list, which is the very
  // shape the numbering above exists to avoid.
  final isEncapsulated =
      part.getHeaderContentType()?.mediaType.sub == MediaSubtype.messageRfc822;
  if (path.isNotEmpty && isEncapsulated) return;

  final parts = part.parts;
  if (parts == null) return;
  for (var i = 0; i < parts.length; i++) {
    _visitParts(parts[i], path.isEmpty ? '${i + 1}' : '$path.${i + 1}', visit);
  }
}

/// The downloadable attachments of a parsed `.eml`.
///
/// Ids are namespaced with [emlId] so two previewed messages cannot produce the
/// same id for their respective part 2 — which would collide in the reading
/// pane's scratch directory and in the active-chip check.
List<EmailAttachment> _collectAttachments(
  MimeMessage msg, {
  required String emlId,
}) {
  final result = <EmailAttachment>[];
  _visitParts(msg, '', (part, path) {
    if (path.isEmpty) return;
    final mediaType = part.getHeaderContentType()?.mediaType;
    if (mediaType == null || mediaType.isMultipart) return;

    // Collected as an inline image instead; the two lists stay disjoint.
    final cid = part.getHeaderValue('content-id')?.trim();
    if (cid != null && cid.isNotEmpty && !mediaType.isText) return;

    final name = _attachmentName(part, mediaType);
    if (name == null) return;

    result.add(EmailAttachment(
      id: '$emlId#$path',
      name: name,
      contentType: mediaType.text,
      // The sender's declared size when there is one, and 0 otherwise: nothing
      // displays this figure, and decoding every part to measure it is exactly
      // the cost this walk exists to avoid.
      size: part.getHeaderContentDisposition()?.size ?? 0,
    ));
  });
  return result;
}

/// What to call a part, or null for one that is not an attachment at all.
///
/// A body part is precisely the one with no name: `text/plain` and `text/html`
/// carry no filename, so they fall out here rather than needing to be listed.
String? _attachmentName(MimePart part, MediaType mediaType) {
  final fromDisposition = part.getHeaderContentDisposition()?.filename;
  if (fromDisposition != null && fromDisposition.isNotEmpty) {
    return fromDisposition;
  }

  final fromContentType = part.getHeaderContentType()?.parameters['name'];
  if (fromContentType != null && fromContentType.isNotEmpty) {
    return MailCodec.decodeHeader(fromContentType) ?? fromContentType;
  }

  // A forwarded or bounced message carries no filename of its own — the same
  // gap `ImapDatasourceImpl._forwardedMessageName` fills, and for the same
  // reason: without it every one of them reads 'Attachment'.
  if (mediaType.sub == MediaSubtype.messageRfc822) {
    final subject = _encapsulatedSubject(part);
    if (subject == null) return 'Attached message.eml';
    final capped = subject.length > 120 ? subject.substring(0, 120) : subject;
    return '$capped.eml';
  }

  return null;
}

/// The `Subject` of the message an rfc822 [part] encapsulates.
///
/// The part's own headers describe the *attachment*; the encapsulated message's
/// headers are the start of its content. Only the header block is scanned.
String? _encapsulatedSubject(MimePart part) {
  final String? text;
  try {
    text = part.decodeContentText();
  } catch (_) {
    return null;
  }
  if (text == null || text.isEmpty) return null;

  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) break; // end of the header block
    if (line.toLowerCase().startsWith('subject:')) {
      final raw = line.substring('subject:'.length).trim();
      if (raw.isEmpty) return null;
      return MailCodec.decodeHeader(raw) ?? raw;
    }
  }
  return null;
}

/// The bytes of one part inside a `.eml`. `compute()` entry point.
///
/// Re-reads and re-parses rather than holding every attachment's bytes from the
/// original parse: a previewed message is opened far more often than its
/// attachments are, and keeping them all resident would make the preview cost
/// the size of the whole message.
Uint8List? extractEmlAttachmentBytes(EmlAttachmentRequest request) {
  final text = utf8.decode(request.bytes, allowMalformed: true);
  final msg = MimeMessage.parseFromText(text);

  Uint8List? found;
  _visitParts(msg, '', (part, path) {
    if (found != null || path != request.partId) return;
    try {
      found = part.decodeContentBinary();
    } catch (_) {
      found = null;
    }
  });
  return found;
}
