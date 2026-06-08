import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';

import '../../domain/entities/email.dart';
import '../models/email_address_model.dart';
import '../models/email_model.dart';

class EmlParser {
  Email parse(Uint8List bytes, {required String id}) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final msg = MimeMessage.parseFromText(text);
    return _toEmail(msg, id: id);
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
    );
  }
}
