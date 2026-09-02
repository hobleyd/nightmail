import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';

import '../../domain/entities/email.dart';
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
    hasAttachments: msg.hasAttachments(),
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
