import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/mime_attachment_builder.dart';
import 'package:nightmail/domain/entities/local_attachment.dart';

void main() {
  const original = 'From: Ada <ada@example.com>\r\n'
      'To: bob@example.com\r\n'
      'Subject: Quarterly numbers\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      '\r\n'
      'See attached.\r\n';

  MimeMessage roundTrip(LocalAttachment attachment) {
    final builder = MessageBuilder()
      ..from = [MailAddress('Me', 'me@example.com')]
      ..to = [MailAddress(null, 'carol@example.com')]
      ..subject = 'Fwd: Quarterly numbers'
      ..addTextPlain('FYI');
    addLocalAttachment(builder, attachment);
    return MimeMessage.parseFromText(
        builder.buildMimeMessage().renderMessage());
  }

  test('an attached message goes out as its own source, not base64', () {
    final sent = roundTrip(LocalAttachment(
      name: 'Quarterly numbers.eml',
      mimeType: 'message/rfc822',
      bytes: Uint8List.fromList(utf8.encode(original)),
    ));

    final part = sent.parts!
        .singleWhere((p) => p.mediaType.sub == MediaSubtype.messageRfc822);
    expect(part.getHeaderContentDisposition()?.filename,
        'Quarterly numbers.eml');
    final inner = MimeMessage.parseFromText(part.mimeData!.decodeText(
        part.getHeaderContentType(), part.getHeaderValue('content-transfer-encoding')));
    expect(inner.decodeSubject(), 'Quarterly numbers');
    expect(inner.decodeTextPlainPart()?.trim(), 'See attached.');
  });

  test('any other file is still a base64 attachment', () {
    final sent = roundTrip(LocalAttachment(
      name: 'notes.txt',
      mimeType: 'text/plain',
      bytes: Uint8List.fromList(utf8.encode('hello')),
    ));

    final part = sent.parts!.singleWhere(
        (p) => p.getHeaderContentDisposition()?.filename == 'notes.txt');
    expect(part.getHeaderValue('content-transfer-encoding'), 'base64');
    expect(utf8.decode(part.decodeContentBinary()!), 'hello');
  });
}
