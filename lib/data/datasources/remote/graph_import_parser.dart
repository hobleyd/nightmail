import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';

import '../../../domain/entities/local_attachment.dart';
import 'imap_datasource_impl.dart' show ImapDatasourceImpl;

/// A message parsed from raw RFC 822 bytes, structured for Graph's
/// `POST /mailFolders/{id}/messages` endpoint — which, unlike IMAP APPEND or
/// Gmail `messages.insert`, is JSON-only and has no raw-MIME option. Used
/// only by [GraphApiDatasourceImpl.insertRawMessage] (account migration);
/// decoded via `compute()` there, same isolate-cost tradeoff as every other
/// body parse in this app.
class ParsedImportMessage {
  const ParsedImportMessage({
    required this.subject,
    required this.fromAddress,
    required this.fromName,
    required this.toAddresses,
    required this.ccAddresses,
    required this.contentType,
    required this.body,
    required this.attachments,
  });

  final String subject;
  final String fromAddress;
  final String fromName;
  final List<String> toAddresses;
  final List<String> ccAddresses;

  /// `'html'` or `'text'`, matching Graph's `body.contentType`.
  final String contentType;
  final String body;

  /// Both ordinary and inline attachments — [LocalAttachment.isInline] and
  /// [LocalAttachment.contentId] tell them apart, same as the compose path.
  final List<LocalAttachment> attachments;
}

/// [compute] entry point — see [ParsedImportMessage].
ParsedImportMessage parseRawMimeForGraphImport(Uint8List rawBytes) {
  final msg = MimeMessage.parseFromData(rawBytes);

  final from = msg.from?.firstOrNull;
  final subject = msg.decodeSubject() ?? '(No Subject)';

  String contentType = 'text';
  String body = '';
  final html = msg.decodeTextHtmlPart();
  if (html != null && html.isNotEmpty) {
    body = html;
    contentType = 'html';
  } else {
    body = msg.decodeTextPlainPart() ?? '';
  }

  final attachments = <LocalAttachment>[];

  // Ordinary attachments — reuses the same BODYSTRUCTURE/header-based
  // detection the IMAP datasource uses for its own attachment chips, rather
  // than re-deriving "what counts as an attachment" a second time. Pure over
  // the parsed [msg]; no IMAP connection state involved.
  for (final att in ImapDatasourceImpl.collectAttachments(msg)) {
    final bytes = msg.getPart(att.id)?.decodeContentBinary();
    if (bytes == null) continue;
    attachments.add(LocalAttachment(
      name: att.name,
      mimeType: att.contentType,
      bytes: Uint8List.fromList(bytes),
    ));
  }

  // Inline images the body HTML references by `cid:` — Graph resolves those
  // against an attachment's own `contentId`, so these travel as attachments
  // too (marked `isInline`), not embedded in the body.
  for (final info in msg.findContentInfo(disposition: ContentDisposition.inline)) {
    if (info.isText) continue;
    final cid = info.cid;
    if (cid == null || cid.isEmpty) continue;
    final bytes = msg.getPart(info.fetchId)?.decodeContentBinary();
    if (bytes == null) continue;
    attachments.add(LocalAttachment(
      name: info.fileName ?? cid,
      mimeType: info.contentType?.mediaType.text ?? 'application/octet-stream',
      bytes: Uint8List.fromList(bytes),
      isInline: true,
      contentId: cid,
    ));
  }

  List<String> addresses(List<MailAddress>? list) =>
      (list ?? []).map((a) => a.email).toList();

  return ParsedImportMessage(
    subject: subject,
    fromAddress: from?.email ?? '',
    fromName: from?.personalName ?? '',
    toAddresses: addresses(msg.to),
    ccAddresses: addresses(msg.cc),
    contentType: contentType,
    body: body,
    attachments: attachments,
  );
}
