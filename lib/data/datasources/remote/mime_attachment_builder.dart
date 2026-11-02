import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';

import '../../../domain/entities/local_attachment.dart';

/// Adds [attachment] to a message being built for Gmail or IMAP.
///
/// An inline image carries its Content-Id. An attached message
/// (`message/rfc822`, the `.eml` a list selection forwards) is added as its own
/// source text, **not** through `addBinary`: that always base64-encodes, and
/// enough_mail writes no Content-Transfer-Encoding header on a `message/*`
/// part — so the recipient got a base64 blob with nothing saying it was
/// base64, and the attachment could not be opened. RFC 2046 allows only
/// 7bit/8bit/binary there in any case. Everything else is a base64 file.
void addLocalAttachment(MessageBuilder builder, LocalAttachment attachment) {
  if (attachment.isInline && attachment.contentId != null) {
    final part = builder.addBinary(
      attachment.bytes,
      MediaType.fromText(attachment.mimeType),
      filename: attachment.name,
      disposition: ContentDispositionHeader.from(ContentDisposition.inline),
    );
    part.setHeader('Content-Id', '<${attachment.contentId}>');
    return;
  }
  if (attachment.mimeType.toLowerCase() == 'message/rfc822') {
    // The message's own transfer encodings keep it 7-bit nearly always; an
    // 8-bit body is UTF-8 in practice, which survives the decode and the
    // UTF-8 encode the whole message gets on the way out.
    builder.addPart(
      mimePart: MimePart()
        ..mimeData = TextMimeData(
          utf8.decode(attachment.bytes, allowMalformed: true),
          containsHeader: false,
        ),
      mediaSubtype: MediaSubtype.messageRfc822,
      disposition: ContentDispositionHeader.from(
        ContentDisposition.attachment,
        filename: attachment.name,
        size: attachment.bytes.length,
      ),
    );
    return;
  }
  builder.addBinary(
    attachment.bytes,
    MediaType.fromText(attachment.mimeType),
    filename: attachment.name,
  );
}
